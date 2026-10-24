import AppKit
import SnapCore
@testable import SnapUI
import Testing

/// Records what the controller asks of one display's panel.
@MainActor
final class FakeOverlaySurface: OverlaySurface {
    let display: DisplayInfo
    var shown: [(state: SelectionOverlayState, makeKey: Bool)] = []
    var updates: [SelectionOverlayState] = []
    var hideCount = 0
    var isVisible = false

    init(display: DisplayInfo) {
        self.display = display
    }

    var windowID: WindowID? { WindowID(7000 + display.id) }
    var lastState: SelectionOverlayState? { updates.last ?? shown.last?.state }

    func show(_ state: SelectionOverlayState, makeKey: Bool) {
        shown.append((state, makeKey))
        isVisible = true
    }

    func update(_ state: SelectionOverlayState) { updates.append(state) }

    func hide() {
        hideCount += 1
        isVisible = false
    }
}

@MainActor
final class FakeCursor: OverlayCursor {
    var hidden = 0
    var unhidden = 0
    func hide() { hidden += 1 }
    func unhide() { unhidden += 1 }
    var isBalanced: Bool { hidden == unhidden }
}

/// Luminance statistics of a rendered image (design 16: pixel statistics, not golden files).
enum ImageStats {
    struct Result {
        var mean: Double
        var standardDeviation: Double
    }

    static func luminance(_ image: CGImage, region: CGRect? = nil) -> Result? {
        let area = region ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = image.cropping(to: area), let bytes = SyntheticImages.rgbaBytes(of: crop) else { return nil }
        var sum = 0.0
        var squares = 0.0
        let count = bytes.count / 4
        guard count > 0 else { return nil }
        for index in stride(from: 0, to: bytes.count, by: 4) {
            // Composite on black so transparent pixels count as dark.
            let alpha = Double(bytes[index + 3]) / 255
            let value = (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1])
                + 0.0722 * Double(bytes[index + 2])) * alpha
            sum += value
            squares += value * value
        }
        let mean = sum / Double(count)
        return Result(mean: mean, standardDeviation: max(squares / Double(count) - mean * mean, 0).squareRoot())
    }
}

@MainActor
@Suite struct OverlayControllerTests {
    let displays = DisplayInfo.fakeSideBySide
    let cursor = FakeCursor()

    final class SurfaceBox {
        var surfaces: [DisplayID: FakeOverlaySurface] = [:]
        var made = 0
    }

    func makeController(
        options: OverlayController.Options = OverlayController.Options(),
        pointer: CGPoint? = CGPoint(x: 100, y: 100),
        box: SurfaceBox = SurfaceBox()
    ) -> OverlayController {
        OverlayController(
            options: options,
            ownPID: FakeWindowSource.snapPID,
            cursor: cursor,
            pointerLocation: { pointer },
            makeSurface: { display, _, _ in
                box.made += 1
                let surface = FakeOverlaySurface(display: display)
                box.surfaces[display.id] = surface
                return surface
            }
        )
    }

    func drag(_ controller: OverlayController, from start: CGPoint, to end: CGPoint, modifiers: OverlayModifiers = []) {
        controller.handle(.mouseDown(start, clickCount: 1, modifiers: modifiers))
        controller.handle(.mouseDragged(end, modifiers: modifiers))
        controller.handle(.mouseUp(end, modifiers: modifiers))
    }

    @Test func presentShowsEverySurfaceAndHidesTheCursor() {
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 3000, y: 500), box: box)
        controller.present(mode: .area, displays: displays)
        #expect(box.made == 2)
        #expect(cursor.hidden == 1)
        #expect(controller.isPresented)
        #expect(box.surfaces[1]?.shown.count == 1)
        #expect(box.surfaces[2]?.shown.count == 1)
        // Keys go to the panel under the pointer, on the ultrawide.
        #expect(box.surfaces[2]?.shown.first?.makeKey == true)
        #expect(box.surfaces[1]?.shown.first?.makeKey == false)
        #expect(box.surfaces[2]?.lastState?.pointer == CGPoint(x: 3000, y: 500))
        #expect(box.surfaces[1]?.lastState?.pointer == nil)
        #expect(controller.surfaceWindowIDs == [7001, 7002])
    }

    @Test func panelsAreBuiltOnceAndReusedAcrossCaptures() {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.prepare(displays: displays)
        #expect(box.made == 2)
        controller.present(mode: .area, displays: displays)
        controller.handle(.keyDown(.escape, modifiers: [], isRepeat: false))
        controller.present(mode: .area, displays: displays)
        #expect(box.made == 2)
    }

    @Test func noFactoryMeansNoPanels() async {
        let controller = OverlayController(cursor: cursor, pointerLocation: { CGPoint(x: 10, y: 10) })
        controller.present(mode: .area, displays: displays)
        #expect(controller.surfaceWindowIDs.isEmpty)
        drag(controller, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        let result = await controller.selection()
        #expect(result == .area(displayID: 1, rect: CGRect(x: 10, y: 10, width: 100, height: 50)))
    }

    @Test func dragConfirmsTheAreaOnMouseUpAndRestoresTheCursor() async {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.present(mode: .area, displays: displays)
        drag(controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))
        #expect(!controller.isPresented)
        #expect(cursor.isBalanced)
        #expect(box.surfaces.values.allSatisfy { !$0.isVisible })
        let result = await controller.selection()
        #expect(result == .area(displayID: 1, rect: CGRect(x: 100, y: 100, width: 400, height: 300)))
    }

    @Test func aWaitingSelectionResumesWhenTheUserFinishes() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        let waiting = Task { await controller.selection() }
        await Task.yield()
        drag(controller, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 220, y: 130))
        let result = await waiting.value
        #expect(result == .area(displayID: 1, rect: CGRect(x: 20, y: 30, width: 200, height: 100)))
    }

    @Test func aSelectionMadeBeforeTheFrozenImageIsKept() async throws {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.present(mode: .area, displays: displays)
        controller.handle(.mouseDown(CGPoint(x: 50, y: 50), clickCount: 1, modifiers: []))
        controller.handle(.mouseDragged(CGPoint(x: 250, y: 150), modifiers: []))
        let image = try #require(SyntheticImages.solid(width: 64, height: 36, color: .white))
        controller.showFrozen(CapturedImage(cgImage: image, scale: 2, displayID: 1), displayID: 1)
        #expect(box.surfaces[1]?.lastState?.frozenImage === image)
        #expect(box.surfaces[1]?.lastState?.selection == CGRect(x: 50, y: 50, width: 200, height: 100))
        controller.handle(.mouseUp(CGPoint(x: 250, y: 150), modifiers: []))
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 50, y: 50, width: 200, height: 100)))
    }

    @Test func aDragIsClampedToTheDisplayWhereItStarted() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        drag(controller, from: CGPoint(x: 2400, y: 100), to: CGPoint(x: 3000, y: 300))
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 2400, y: 100, width: 160, height: 200)))
    }

    @Test func shiftMakesASquareAndOptionGrowsFromTheCentre() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        drag(controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 160), modifiers: .shift)
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 100, y: 100, width: 200, height: 200)))

        controller.present(mode: .area, displays: displays)
        drag(controller, from: CGPoint(x: 500, y: 500), to: CGPoint(x: 600, y: 550), modifiers: .option)
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 400, y: 450, width: 200, height: 100)))
    }

    @Test func modifierChangesDuringADragReshapeIt() {
        let box = SurfaceBox()
        let controller = makeController(options: .init(instantCapture: false), box: box)
        controller.present(mode: .area, displays: displays)
        controller.handle(.mouseDown(CGPoint(x: 100, y: 100), clickCount: 1, modifiers: []))
        controller.handle(.mouseDragged(CGPoint(x: 300, y: 160), modifiers: []))
        #expect(controller.selection == CGRect(x: 100, y: 100, width: 200, height: 60))
        controller.handle(.modifiersChanged(.shift))
        #expect(controller.selection == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func spaceMovesTheSelectionWhileDragging() {
        let controller = makeController(options: .init(instantCapture: false))
        controller.present(mode: .area, displays: displays)
        controller.handle(.mouseDown(CGPoint(x: 100, y: 100), clickCount: 1, modifiers: []))
        controller.handle(.mouseDragged(CGPoint(x: 200, y: 200), modifiers: []))
        controller.handle(.keyDown(.space, modifiers: [], isRepeat: false))
        controller.handle(.mouseDragged(CGPoint(x: 250, y: 220), modifiers: []))
        #expect(controller.selection == CGRect(x: 150, y: 120, width: 100, height: 100))
        controller.handle(.keyUp(.space))
        controller.handle(.mouseDragged(CGPoint(x: 300, y: 260), modifiers: []))
        #expect(controller.selection == CGRect(x: 150, y: 120, width: 150, height: 140))
    }

    @Test func slowMovesAddUpForSpaceAndInsideDrags() {
        let controller = makeController(options: .init(instantCapture: false))
        controller.present(mode: .area, displays: displays)
        controller.handle(.mouseDown(CGPoint(x: 100, y: 100), clickCount: 1, modifiers: []))
        controller.handle(.mouseDragged(CGPoint(x: 200, y: 200), modifiers: []))
        controller.handle(.keyDown(.space, modifiers: [], isRepeat: false))
        var pointer = CGPoint(x: 200, y: 200)
        for _ in 0..<20 {
            pointer.y += 0.3
            controller.handle(.mouseDragged(pointer, modifiers: []))
        }
        controller.handle(.keyUp(.space))
        controller.handle(.mouseUp(pointer, modifiers: []))
        let afterSpace = controller.selection ?? .zero
        #expect(abs(afterSpace.minY - 106) <= 0.5)

        // A drag inside the adjustable selection, at 0.3 pt per event.
        pointer = CGPoint(x: 150, y: 150)
        controller.handle(.mouseDown(pointer, clickCount: 1, modifiers: []))
        for _ in 0..<20 {
            pointer.x += 0.3
            controller.handle(.mouseDragged(pointer, modifiers: []))
        }
        controller.handle(.mouseUp(pointer, modifiers: []))
        let afterInside = controller.selection ?? .zero
        #expect(abs(afterInside.minX - afterSpace.minX - 6) <= 0.5)
        #expect(afterInside.size == afterSpace.size)
    }

    @Test func aClickCapturesTheWindowUnderThePointer() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        controller.updateWindows(FakeWindowSource.sample)
        controller.handle(.mouseDown(CGPoint(x: 500, y: 300), clickCount: 1, modifiers: []))
        controller.handle(.mouseUp(CGPoint(x: 501, y: 301), modifiers: []))
        let notes = FakeWindowSource.sample.first { $0.ownerName == "Notes" }
        #expect(await controller.selection() == .window(notes!, includeShadow: true))
        #expect(cursor.isBalanced)
    }

    @Test func aClickOverNoWindowCancels() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        controller.updateWindows(FakeWindowSource.sample)
        controller.handle(.mouseDown(CGPoint(x: 2300, y: 1000), clickCount: 1, modifiers: []))
        controller.handle(.mouseUp(CGPoint(x: 2300, y: 1000), modifiers: []))
        #expect(await controller.selection() == .cancelled)
    }

    @Test func escapeAndRightClickCancelAndRestoreTheCursor() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        controller.handle(.keyDown(.escape, modifiers: [], isRepeat: false))
        #expect(await controller.selection() == .cancelled)
        #expect(cursor.isBalanced)

        controller.present(mode: .window, displays: displays)
        controller.handle(.rightMouseDown)
        #expect(await controller.selection() == .cancelled)
        #expect(cursor.hidden == 2)
        #expect(cursor.isBalanced)
    }

    @Test func dismissResumesAWaitingSelectionAsCancelled() async {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        let waiting = Task { await controller.selection() }
        await Task.yield()
        controller.dismiss()
        #expect(await waiting.value == .cancelled)
        #expect(cursor.isBalanced)
        controller.dismiss()
        #expect(cursor.isBalanced)
    }

    @Test func aScreenChangeCancelsAndRebuildsThePanels() async {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.present(mode: .area, displays: displays)
        controller.screenParametersChanged(displays: [.fake5K])
        #expect(await controller.selection() == .cancelled)
        #expect(cursor.isBalanced)
        #expect(box.made == 3)
        #expect(controller.displays == [.fake5K])
    }

    @Test func tabSwitchesToWindowModeAndAClickTakesTheHoveredWindow() async {
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 300, y: 150), box: box)
        controller.present(mode: .area, displays: displays)
        controller.updateWindows(FakeWindowSource.sample)
        controller.handle(.keyDown(.tab, modifiers: [], isRepeat: false))
        #expect(controller.mode == .window)
        #expect(controller.hoveredWindow?.ownerName == "Safari")
        controller.handle(.mouseMoved(CGPoint(x: 500, y: 300)))
        #expect(controller.hoveredWindow?.ownerName == "Notes")
        #expect(box.surfaces[1]?.lastState?.hoveredWindow?.ownerName == "Notes")
        #expect(box.surfaces[1]?.lastState?.mode == .window)
        // Option-click flips the shadow setting for this capture.
        controller.handle(.mouseDown(CGPoint(x: 500, y: 300), clickCount: 1, modifiers: .option))
        controller.handle(.mouseUp(CGPoint(x: 500, y: 300), modifiers: .option))
        let result = await controller.selection()
        guard case .window(let window, let shadow) = result else {
            Issue.record("expected a window, got \(result)")
            return
        }
        #expect(window.ownerName == "Notes")
        #expect(!shadow)
    }

    @Test func windowModeSkipsSnapsOwnWindowsAndTabReturnsToArea() {
        let controller = makeController(pointer: CGPoint(x: 2300, y: 1000))
        controller.present(mode: .window, displays: displays)
        controller.updateWindows(FakeWindowSource.sample)
        #expect(controller.hoveredWindow == nil)
        controller.handle(.mouseMoved(CGPoint(x: 1000, y: 10)))
        #expect(controller.hoveredWindow?.layer == WindowLayer.mainMenu)
        controller.handle(.keyDown(.tab, modifiers: [], isRepeat: false))
        #expect(controller.mode == .area)
        #expect(controller.hoveredWindow == nil)
    }

    @Test func instantCaptureOffKeepsTheSelectionForKeysAndReturn() async {
        let box = SurfaceBox()
        let controller = makeController(options: .init(instantCapture: false), box: box)
        controller.present(mode: .area, displays: displays)
        drag(controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        #expect(controller.isPresented)
        #expect(controller.phase == .adjusting)
        #expect(box.surfaces[1]?.lastState?.phase == .adjusting)
        controller.handle(.keyDown(.arrow(.right), modifiers: [], isRepeat: false))
        #expect(controller.selection == CGRect(x: 101, y: 100, width: 200, height: 100))
        controller.handle(.keyDown(.arrow(.down), modifiers: .shift, isRepeat: false))
        #expect(controller.selection == CGRect(x: 101, y: 110, width: 200, height: 100))
        controller.handle(.keyDown(.arrow(.right), modifiers: .command, isRepeat: false))
        #expect(controller.selection == CGRect(x: 101, y: 110, width: 201, height: 100))
        controller.handle(.keyDown(.returnKey, modifiers: [], isRepeat: false))
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 101, y: 110, width: 201, height: 100)))
        #expect(cursor.isBalanced)
    }

    @Test func handlesResizeAndAnInsideDragMovesTheSelection() async {
        let controller = makeController(options: .init(instantCapture: false))
        controller.present(mode: .area, displays: displays)
        drag(controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        drag(controller, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 340, y: 260))
        #expect(controller.selection == CGRect(x: 100, y: 100, width: 240, height: 160))
        drag(controller, from: CGPoint(x: 220, y: 100), to: CGPoint(x: 220, y: 80))
        #expect(controller.selection == CGRect(x: 100, y: 80, width: 240, height: 180))
        drag(controller, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 230, y: 160))
        #expect(controller.selection == CGRect(x: 130, y: 90, width: 240, height: 180))
        #expect(controller.phase == .adjusting)
        controller.handle(.mouseDown(CGPoint(x: 200, y: 150), clickCount: 2, modifiers: []))
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 130, y: 90, width: 240, height: 180)))
    }

    @Test func fullscreenSelectsTheDisplayUnderThePointerWithoutPanels() async {
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 3000, y: 200), box: box)
        controller.present(mode: .fullscreen, displays: displays)
        #expect(!controller.isPresented)
        #expect(cursor.hidden == 0)
        #expect(box.surfaces.values.allSatisfy { $0.shown.isEmpty })
        #expect(await controller.selection() == .area(displayID: 2, rect: displays[1].frameTopLeft))
    }

    @Test func eventsAfterTheOverlayClosedAreIgnored() {
        let controller = makeController()
        controller.present(mode: .area, displays: displays)
        controller.handle(.keyDown(.escape, modifiers: [], isRepeat: false))
        controller.handle(.mouseDown(CGPoint(x: 10, y: 10), clickCount: 1, modifiers: []))
        #expect(controller.selection == nil)
        #expect(cursor.hidden == 1)
        #expect(cursor.isBalanced)
    }

    @Test func pointerMovesUpdateOnlyTheDisplayUnderIt() {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.present(mode: .area, displays: displays)
        controller.handle(.mouseMoved(CGPoint(x: 2700, y: 400)))
        #expect(box.surfaces[1]?.lastState?.pointer == nil)
        #expect(box.surfaces[2]?.lastState?.pointer == CGPoint(x: 2700, y: 400))
    }

    @Test func keyCodesMapToOverlayKeys() {
        #expect(OverlayKey(keyCode: 53) == .escape)
        #expect(OverlayKey(keyCode: 48) == .tab)
        #expect(OverlayKey(keyCode: 49) == .space)
        #expect(OverlayKey(keyCode: 36) == .returnKey)
        #expect(OverlayKey(keyCode: 123) == .arrow(.left))
        #expect(OverlayKey(keyCode: 126) == .arrow(.up))
        #expect(OverlayKey(keyCode: 0) == .other(0))
        #expect(OverlayModifiers([.shift, .option]) == [.shift, .option])
    }
}

@MainActor
@Suite struct SelectionOverlayRenderTests {
    @Test func magnifierSitsDownRightBeforeTheDragAndFlipsAtEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let glass = MagnifierLayer.glassFrame(pointer: CGPoint(x: 400, y: 300), selection: nil, bounds: bounds)
        #expect(glass == CGRect(x: 424, y: 324, width: 120, height: 120))
        let corner = MagnifierLayer.glassFrame(pointer: CGPoint(x: 1250, y: 780), selection: nil, bounds: bounds)
        #expect(corner.maxX <= 1250 - 24)
        #expect(corner.minY + MagnifierLayer.unitHeight <= 780 - 24 + 0.001)
        // A unit that would end 4 pt from the bottom flips above: it keeps an 8 pt margin.
        let pointerY = 800 - 24 - MagnifierLayer.unitHeight - 4
        let nearEdge = MagnifierLayer.glassFrame(pointer: CGPoint(x: 400, y: pointerY), selection: nil, bounds: bounds)
        #expect(nearEdge.minY + MagnifierLayer.unitHeight <= pointerY - 24 + 0.001)
    }

    @Test func magnifierStaysOnTheSideAwayFromTheSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let selection = CGRect(x: 400, y: 300, width: 200, height: 200)
        let atTopLeft = MagnifierLayer.glassFrame(pointer: CGPoint(x: 400, y: 300), selection: selection, bounds: bounds)
        #expect(atTopLeft.maxX < 400)
        #expect(atTopLeft.minY + MagnifierLayer.unitHeight < 300)
        let atBottomRight = MagnifierLayer.glassFrame(pointer: CGPoint(x: 600, y: 500), selection: selection, bounds: bounds)
        #expect(atBottomRight.minX > 600)
        #expect(atBottomRight.minY > 500)
    }

    @Test func magnifierReadsPhysicalPixelsAtTwoX() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let pixel = MagnifierLayer.sourcePixel(for: CGPoint(x: 100.5, y: 40), imageSize: CGSize(width: 2560, height: 1600), bounds: bounds)
        #expect(pixel.x == 201)
        #expect(pixel.y == 80)
        #expect(MagnifierLayer.sourceRect(around: pixel) == CGRect(x: 194, y: 73, width: 15, height: 15))
        #expect(Theme.Overlay.magnifierDiameter == Double(MagnifierLayer.pixelsAcross) * MagnifierLayer.pixelSize)
    }

    @Test func handlesHitTestAtTheirCentres() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(SelectionHandle.hit(CGPoint(x: 302, y: 199), rect: rect) == .bottomRight)
        #expect(SelectionHandle.hit(CGPoint(x: 200, y: 101), rect: rect) == .top)
        #expect(SelectionHandle.hit(CGPoint(x: 200, y: 150), rect: rect) == nil)
        let geometry = SelectionGeometry(display: .fake5K)
        #expect(OverlayController.resize(rect, handle: .left, to: CGPoint(x: 350, y: 0), geometry: geometry)
            == CGRect(x: 300, y: 100, width: 50, height: 100))
    }

    @Test func areaRenderIsNonBlankAtTwoXAndShowsTheBrightSelection() throws {
        let state = OverlayDemo.areaState(dark: false)
        let image = try #require(OverlayDemo.render(state, dark: false))
        #expect(image.width == 2560)
        #expect(image.height == 1600)
        let stats = try #require(ImageStats.luminance(image))
        #expect(stats.standardDeviation >= 4)

        // Inside the cut-out the frozen image is undimmed; outside it is dimmed by 0.38.
        let frozen = try #require(state.frozenImage)
        let inside = try #require(SyntheticImages.pixel(of: image, x: 760, y: 500))
        let original = try #require(SyntheticImages.pixel(of: frozen, x: 760, y: 500))
        #expect(abs(inside.luminance - original.luminance) < 3)
        let outside = try #require(SyntheticImages.pixel(of: image, x: 100, y: 1500))
        let outsideOriginal = try #require(SyntheticImages.pixel(of: frozen, x: 100, y: 1500))
        #expect(abs(outside.luminance - outsideOriginal.luminance * 0.62) < 4)
    }

    @Test func lightAndDarkRendersDiffer() throws {
        let light = try #require(OverlayDemo.render(OverlayDemo.areaState(dark: false), dark: false))
        let dark = try #require(OverlayDemo.render(OverlayDemo.areaState(dark: true), dark: true))
        let lightMean = try #require(ImageStats.luminance(light)).mean
        let darkMean = try #require(ImageStats.luminance(dark)).mean
        #expect(lightMean - darkMean >= 40)
    }

    @Test func beforeAndWindowStatesRender() throws {
        let before = try #require(OverlayDemo.render(OverlayDemo.beforeState(), dark: false))
        #expect(try #require(ImageStats.luminance(before)).standardDeviation >= 4)
        // The crosshair is a bright line through the pointer's column, away from the magnifier.
        let line = try #require(SyntheticImages.pixel(of: before, x: 642 * 2, y: 120))
        let beside = try #require(SyntheticImages.pixel(of: before, x: 642 * 2 + 12, y: 120))
        #expect(line.luminance > beside.luminance + 20)

        let window = try #require(OverlayDemo.render(OverlayDemo.windowState(), dark: false))
        // The 2 pt accent border on the Notes window's left edge, halfway down.
        let frame = OverlayDemo.notesWindow.frame
        let border = try #require(SyntheticImages.pixel(of: window, x: Int(frame.minX * 2) + 1, y: Int(frame.midY * 2)))
        #expect(border.blue > border.red + 80)
    }

    @Test func pointerMovesInvalidateRegionsAndPhaseChangesRedrawEverything() throws {
        let state = OverlayDemo.beforeState()
        let view = SelectionOverlayView(state: state)
        var moved = state
        moved.pointer = CGPoint(x: 700, y: 400)
        let regions = try #require(view.changedRegions(from: state, to: moved))
        #expect(!regions.isEmpty)
        var dragging = state
        dragging.phase = .dragging
        #expect(view.changedRegions(from: state, to: dragging) == nil)
    }

    @Test func windowLabelNamesTheOwnerAndSize() {
        #expect(SelectionOverlayView.windowLabel(OverlayDemo.notesWindow) == "Notes  |  842 \u{00D7} 516")
        var unnamed = OverlayDemo.notesWindow
        unnamed.ownerName = nil
        #expect(SelectionOverlayView.windowLabel(unnamed) == "842 \u{00D7} 516")
    }
}
