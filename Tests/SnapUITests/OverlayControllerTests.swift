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

    var poppedMenus: [(menu: NSMenu, point: CGPoint)] = []
    func popUpMenu(_ menu: NSMenu, at point: CGPoint) { poppedMenus.append((menu, point)) }
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

    @Test func theOverlayGrabsItsKeysWhileItIsUp() async throws {
        // macOS sends no keys to a non-activating panel of an inactive app, so Esc comes in as a
        // grabbed global hotkey for as long as the overlay is up.
        let controller = makeController()
        var grabs: [Bool] = []
        controller.onKeyGrabChanged = { grabs.append($0) }
        controller.present(mode: .area, displays: displays)
        #expect(grabs == [true])
        let escape = try #require(OverlayController.grabbedKeys.firstIndex { $0.keyCode == 53 && $0.modifiers == 0 })
        controller.grabbedKey(at: escape, pressed: true)
        #expect(!controller.isPresented)
        #expect(grabs == [true, false])
        #expect(cursor.isBalanced)
        #expect(await controller.selection() == .cancelled)
    }

    @Test func grabbedKeysCoverTheOverlayAndTheHUD() throws {
        let keys = OverlayController.grabbedKeys
        let shift = KeyShortcut.Modifier.shift
        for code: UInt32 in [53, 36, 76, 48, 49, 18, 19, 20, 15] {
            #expect(keys.contains(KeyShortcut(keyCode: code, modifiers: 0)), "key \(code)")
        }
        for arrow: UInt32 in [123, 124, 125, 126] {
            #expect(keys.contains(KeyShortcut(keyCode: arrow, modifiers: 0)))
            #expect(keys.contains(KeyShortcut(keyCode: arrow, modifiers: shift)))
        }
        #expect(Set(keys).count == keys.count)
    }

    @Test func aGrabbedSpaceReleaseEndsTheMoveAndOtherKeysWaitForTheOverlay() {
        let controller = makeController()
        var grabs: [Bool] = []
        controller.onKeyGrabChanged = { grabs.append($0) }
        let space = OverlayController.grabbedKeys.firstIndex { $0.keyCode == 49 } ?? 0
        controller.grabbedKey(at: space, pressed: true)
        #expect(grabs.isEmpty, "no overlay, no grab and nothing handled")
        controller.present(mode: .area, displays: displays)
        controller.grabbedKey(at: space, pressed: true)
        controller.grabbedKey(at: space, pressed: false)
        #expect(controller.isPresented)
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

    @Test func spaceOutsideADragHighlightsTheWindowUnderThePointer() {
        // Design 6.5: Space or Tab enters window mode, like the macOS screenshot overlay.
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 300, y: 150), box: box)
        controller.present(mode: .area, displays: displays)
        controller.updateWindows(FakeWindowSource.sample)
        controller.handle(.keyDown(.space, modifiers: [], isRepeat: false))
        #expect(controller.mode == .window)
        #expect(controller.hoveredWindow?.ownerName == "Safari")
        #expect(box.surfaces[1]?.lastState?.hoveredWindow?.ownerName == "Safari")
        // Holding Space repeats the key; that must not flip the mode back and forth.
        controller.handle(.keyDown(.space, modifiers: [], isRepeat: true))
        controller.handle(.keyUp(.space))
        #expect(controller.mode == .window)
        controller.handle(.keyDown(.space, modifiers: [], isRepeat: false))
        #expect(controller.mode == .area)
        #expect(controller.hoveredWindow == nil)
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

// MARK: All-in-one HUD (design 20.5, 20.6)

extension OverlayControllerTests {
    static let hudArea = CGRect(x: 400, y: 200, width: 842, height: 516)

    func presentHUD(
        _ controller: OverlayController, mode: HUDMode = .screenshot, area: CGRect? = OverlayControllerTests.hudArea,
        modeChanges: ((HUDMode) -> Void)? = nil
    ) {
        let last = area.map { LastArea(displayID: 1, displayFrame: DisplayInfo.fake5K.frameTopLeft, rect: $0) }
        let state = AllInOneState(mode: mode, target: .area, lastArea: last, displays: displays)
        controller.presentHUD(state, displays: displays) { modeChanges?($0) }
    }

    func key(_ code: UInt16, _ modifiers: OverlayModifiers = []) -> OverlayInputEvent {
        .keyDown(OverlayKey(keyCode: code), modifiers: modifiers, isRepeat: false)
    }

    func click(_ controller: OverlayController, _ point: CGPoint) {
        controller.handle(.mouseDown(point, clickCount: 1, modifiers: []))
        controller.handle(.mouseUp(point, modifiers: []))
    }

    func toolbarPoint(_ controller: OverlayController, _ item: AllInOneToolbarItem) throws -> CGPoint {
        let frame = try #require(controller.toolbarFrame)
        let hud = try #require(controller.hud)
        let slot = try #require(AllInOneToolbarLayout.layout(for: hud.mode).frame(of: item))
        return CGPoint(x: frame.minX + slot.midX, y: frame.minY + slot.midY)
    }

    @Test func hudRestoresTheLastAreaEditableWithTheToolbarAndKeepsTheCursor() throws {
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300), box: box)
        presentHUD(controller)
        #expect(controller.isPresented)
        #expect(controller.selection == Self.hudArea)
        #expect(controller.phase == .adjusting)
        #expect(controller.hud?.restoredArea == true)
        // The toolbar and handles are clicked, so the cursor stays.
        #expect(cursor.hidden == 0)
        let state = try #require(box.surfaces[1]?.lastState)
        #expect(state.hud?.mode == .screenshot)
        #expect(state.hud?.toolbarOrigin != nil)
        #expect(box.surfaces[2]?.lastState?.hud?.toolbarOrigin == nil)
        #expect(box.surfaces[1]?.shown.first?.makeKey == true)
        // Centered, 28 pt above the bottom of the visible frame.
        let frame = try #require(controller.toolbarFrame)
        #expect(Double(frame.height) == Theme.HUD.barHeight)
        #expect(abs(frame.midX - 1280) <= 0.5)
        #expect(Double(frame.maxY) == 1440 - Theme.HUD.edgeInset)
        #expect(controller.toolbarEdge == .bottom)
    }

    @Test func hudWithoutAUsableLastAreaShowsTheCrosshair() throws {
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 600, y: 600), box: box)
        // Stored on a display layout that is gone: no restore (D58).
        let stale = LastArea(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), rect: Self.hudArea)
        controller.presentHUD(AllInOneState(lastArea: stale, displays: displays), displays: displays) { _ in }
        #expect(controller.selection == nil)
        #expect(controller.phase == .idle)
        let state = try #require(box.surfaces[1]?.lastState)
        #expect(state.drawsCrosshair)
        #expect(!state.drawsHints)
    }

    @Test func hudReturnConfirmsTheAreaAndDoubleClickInsideToo() async {
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300))
        presentHUD(controller)
        // Instant capture does not apply: dragging a new area leaves it editable.
        drag(controller, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 260))
        #expect(controller.isPresented)
        #expect(controller.selection == CGRect(x: 100, y: 100, width: 200, height: 160))
        #expect(controller.hud?.area == CGRect(x: 100, y: 100, width: 200, height: 160))
        controller.handle(key(36))
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 100, y: 100, width: 200, height: 160)))
        #expect(!controller.isPresented)

        presentHUD(controller)
        controller.handle(.mouseDown(CGPoint(x: 800, y: 400), clickCount: 2, modifiers: []))
        #expect(await controller.selection() == .area(displayID: 1, rect: Self.hudArea))
    }

    @Test func hudClickOutsideKeepsTheAreaAndArrowsNudgeIt() {
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300))
        presentHUD(controller)
        click(controller, CGPoint(x: 50, y: 50))
        #expect(controller.selection == Self.hudArea)
        controller.handle(key(124))
        #expect(controller.selection == Self.hudArea.offsetBy(dx: 1, dy: 0))
        controller.handle(key(125, .shift))
        #expect(controller.selection == Self.hudArea.offsetBy(dx: 1, dy: 10))
        #expect(controller.hud?.area == Self.hudArea.offsetBy(dx: 1, dy: 10))
        // Inside drags move it, handles resize it.
        controller.handle(.mouseDown(CGPoint(x: 600, y: 400), clickCount: 1, modifiers: []))
        controller.handle(.mouseDragged(CGPoint(x: 610, y: 400), modifiers: []))
        controller.handle(.mouseUp(CGPoint(x: 610, y: 400), modifiers: []))
        #expect(controller.selection?.minX == 411)
        #expect(controller.isPresented)
    }

    @Test func hudKeysPickTheTargetAndToggleTheMode() {
        let box = SurfaceBox()
        var modes: [HUDMode] = []
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300), box: box)
        presentHUD(controller) { modes.append($0) }
        controller.handle(key(19))
        #expect(controller.hud?.target == .window)
        #expect(box.surfaces[1]?.lastState?.mode == .window)
        controller.handle(key(20))
        #expect(controller.hud?.target == .fullscreen)
        controller.handle(key(48))
        #expect(controller.hud?.target == .window)
        controller.handle(key(48))
        #expect(controller.hud?.target == .area)
        // Switching back keeps the area.
        #expect(controller.selection == Self.hudArea)
        #expect(controller.phase == .adjusting)
        controller.handle(key(15))
        #expect(controller.hud?.mode == .record)
        #expect(modes == [.record])
        #expect(box.surfaces[1]?.lastState?.showsFrozenImage == false)
        #expect(box.surfaces[1]?.lastState?.hud?.mode == .record)
        // Cmd+R is not R.
        controller.handle(key(15, .command))
        #expect(controller.hud?.mode == .record)
        controller.handle(key(53))
        #expect(!controller.isPresented)
    }

    @Test func hudRecordModeHoldsThePanelsForTheCountdown() async {
        let box = SurfaceBox()
        var keys: [CountdownKey] = []
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300), box: box)
        controller.onCountdownKey = { keys.append($0) }
        presentHUD(controller, mode: .record)
        controller.handle(key(36))
        #expect(await controller.selection() == .record(.area(Self.hudArea)))
        #expect(controller.isHoldingForRecording)
        #expect(box.surfaces[1]?.hideCount == 0)
        let held = box.surfaces[1]?.lastState
        #expect(held?.hud?.recordTarget == Self.hudArea)
        #expect(held?.localToolbar == nil)
        #expect(held?.localSelection == nil)

        controller.showCountdown(3)
        #expect(box.surfaces[1]?.lastState?.hud?.countdown == 3)
        #expect(box.surfaces[2]?.lastState?.hud?.countdown == nil)
        controller.showCountdown(2)
        #expect(box.surfaces[1]?.lastState?.hud?.countdown == 2)
        // Only Return and Esc do anything now.
        controller.handle(key(19))
        controller.handle(.mouseDown(CGPoint(x: 10, y: 10), clickCount: 1, modifiers: []))
        controller.handle(key(36))
        controller.handle(key(53))
        #expect(keys == [.startNow, .cancel])
        #expect(controller.isPresented)
        controller.dismiss()
        #expect(!controller.isPresented)
        #expect(box.surfaces[1]?.hideCount == 1)
        #expect(cursor.isBalanced)
    }

    @Test func hudRefusesAnAreaTooSmallToRecord() async {
        let box = SurfaceBox()
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300), box: box)
        // 30 x 30 pt is 60 x 60 px at 2x, under the 64 px minimum.
        presentHUD(controller, mode: .record, area: CGRect(x: 100, y: 100, width: 30, height: 30))
        controller.handle(key(36))
        #expect(controller.hudNotice == "Too small to record")
        #expect(box.surfaces[1]?.lastState?.hud?.notice == "Too small to record")
        #expect(!controller.isHoldingForRecording)
        // Screenshot mode takes the same area.
        controller.handle(key(15))
        #expect(controller.hudNotice == nil)
        controller.handle(key(36))
        #expect(await controller.selection() == .area(displayID: 1, rect: CGRect(x: 100, y: 100, width: 30, height: 30)))
    }

    @Test func hudWindowAndFullscreenTargetsConfirmOnClick() async {
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300))
        presentHUD(controller)
        controller.updateWindows(FakeWindowSource.sample)
        controller.handle(key(19))
        // The Notes window of the sample is frontmost at this point.
        let inside = CGPoint(x: 600, y: 300)
        controller.handle(.mouseMoved(inside))
        #expect(controller.hoveredWindow?.id == 202)
        click(controller, inside)
        let picked = await controller.selection()
        if case .window(let chosen, _) = picked {
            #expect(chosen.id == 202)
        } else {
            Issue.record("expected a window, got \(picked)")
        }

        presentHUD(controller, mode: .record)
        controller.handle(key(20))
        controller.handle(.mouseMoved(CGPoint(x: 3000, y: 700)))
        click(controller, CGPoint(x: 3000, y: 700))
        #expect(await controller.selection() == .record(.fullscreen(displayID: 2)))
        #expect(controller.recordTarget == displays[1].frameTopLeft)
        controller.dismiss()

        presentHUD(controller)
        controller.handle(key(20))
        controller.handle(.mouseMoved(CGPoint(x: 500, y: 500)))
        controller.handle(key(36))
        #expect(await controller.selection() == .fullscreen(displayID: 1))
    }

    @Test func hudToolbarClicksRunTheirControls() async throws {
        var modes: [HUDMode] = []
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300))
        presentHUD(controller) { modes.append($0) }
        #expect(controller.toolbarItem(at: CGPoint(x: 10, y: 10)) == nil)
        click(controller, try toolbarPoint(controller, .target(.window)))
        #expect(controller.hud?.target == .window)
        click(controller, try toolbarPoint(controller, .target(.area)))
        click(controller, try toolbarPoint(controller, .mode(.record)))
        #expect(controller.hud?.mode == .record)
        click(controller, try toolbarPoint(controller, .mode(.screenshot)))
        #expect(modes == [.record, .screenshot])
        // A press on the toolbar never starts a drag, even when it moves.
        let primary = try toolbarPoint(controller, .primary)
        controller.handle(.mouseDown(primary, clickCount: 1, modifiers: []))
        #expect(await controller.selection() == .area(displayID: 1, rect: Self.hudArea))

        presentHUD(controller)
        click(controller, try toolbarPoint(controller, .close))
        #expect(await controller.selection() == .cancelled)
    }

    @Test func hudOptionsMenuShowsTheModesSettingsAndReportsAChoice() throws {
        let box = SurfaceBox()
        var chosen: [AllInOneOption] = []
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300), box: box)
        var settings = SnapCore.Settings()
        settings.recording.countdownSeconds = 5
        let microphones = [MicrophoneDevice(id: "m1", name: "Studio Mic")]
        controller.hudOptionItems = { AllInOneOptions.items(mode: $0, settings: settings, microphones: microphones) }
        controller.onHUDOption = { chosen.append($0) }
        presentHUD(controller, mode: .record)
        click(controller, try toolbarPoint(controller, .options))
        let menu = try #require(controller.lastOptionsMenu)
        #expect(box.surfaces[1]?.poppedMenus.count == 1)
        let titles = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Studio Mic"))
        #expect(titles.contains("Record System Audio"))
        let five = try #require(menu.items.first { $0.title == "5 seconds" })
        #expect(five.state == .on)
        _ = five.target?.perform(five.action, with: five)
        #expect(chosen == [.countdown(5)])
        #expect(controller.isPresented)
    }

    @Test func hudToolbarMovesToTheTopWhenTheAreaSitsUnderIt() throws {
        let controller = makeController(pointer: CGPoint(x: 1280, y: 1300))
        presentHUD(controller, area: CGRect(x: 800, y: 1200, width: 900, height: 220))
        #expect(controller.toolbarEdge == .top)
        #expect(controller.toolbarFrame.map { Double($0.minY) } == Theme.HUD.edgeInset)
        // Moving the area away brings the toolbar back down.
        controller.handle(.mouseDown(CGPoint(x: 1000, y: 1300), clickCount: 1, modifiers: []))
        controller.handle(.mouseDragged(CGPoint(x: 1000, y: 500), modifiers: []))
        controller.handle(.mouseUp(CGPoint(x: 1000, y: 500), modifiers: []))
        #expect(controller.toolbarEdge == .bottom)
    }

    @Test func hudRendersTheMockupSceneInBothAppearances() throws {
        let light = try #require(HUDDemo.renderHUD(dark: false))
        let dark = try #require(HUDDemo.renderHUD(dark: true))
        #expect(light.width == 2560 && light.height == 1600)
        #expect(try #require(ImageStats.luminance(light)).standardDeviation >= 4)
        // The toolbar (mockup region 360 728 560 44) is the dark chip in both appearances.
        let toolbar = CGRect(x: 380 * 2, y: 734 * 2, width: 60 * 2, height: 30 * 2)
        #expect(try #require(ImageStats.luminance(light, region: toolbar)).mean < 90)
        let lightMean = try #require(ImageStats.luminance(light)).mean
        let darkMean = try #require(ImageStats.luminance(dark)).mean
        #expect(lightMean - darkMean >= 40)
        // The restored area is undimmed: brighter than the dim beside it.
        let inside = try #require(ImageStats.luminance(light, region: CGRect(x: 1400, y: 500, width: 100, height: 100)))
        let outside = try #require(ImageStats.luminance(light, region: CGRect(x: 100, y: 1300, width: 100, height: 100)))
        #expect(inside.mean > outside.mean)

        let countdown = try #require(HUDDemo.renderCountdown(dark: false))
        let disc = CGRect(x: (650 - 30) * 2, y: (350 - 30) * 2, width: 120, height: 120)
        #expect(try #require(ImageStats.luminance(countdown, region: disc)).mean < 120)
    }
}
