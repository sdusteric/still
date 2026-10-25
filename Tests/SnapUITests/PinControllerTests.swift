import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

/// A panel stand-in that records what the controller asked of it.
@MainActor
final class RecordingPinSurface: PinSurface {
    var presented: [(CGRect, PinTransition)] = []
    var frames: [CGRect] = []
    var clickThrough: [Bool] = []
    var dismissed: [PinTransition] = []

    func present(frame: CGRect, transition: PinTransition) { presented.append((frame, transition)) }
    func setFrame(_ frame: CGRect) { frames.append(frame) }
    func setClickThrough(_ on: Bool) { clickThrough.append(on) }
    func dismiss(transition: PinTransition) { dismissed.append(transition) }
}

/// The recording factory: one surface per pin, kept by pin id.
@MainActor
final class RecordingPinFactory {
    var surfaces: [Int: RecordingPinSurface] = [:]
    var made = 0

    var factory: PinController.SurfaceFactory {
        { _, model in
            self.made += 1
            let surface = RecordingPinSurface()
            self.surfaces[model.id] = surface
            return surface
        }
    }
}

@MainActor
final class PinActionLog {
    var calls: [String] = []
    var closed: [String] = []

    func actions() -> PinActions {
        PinActions(
            copy: { model in
                self.calls.append("copy \(model.itemID)")
                return true
            },
            save: { model in self.calls.append("save \(model.itemID)") },
            annotate: { id in self.calls.append("annotate \(id)") },
            showInQuickAccess: { id in self.calls.append("card \(id)") },
            reveal: { url in self.calls.append("reveal \(url.lastPathComponent)") },
            closed: { id in self.closed.append(id) }
        )
    }
}

@MainActor
final class Flags {
    var reduceMotion = false
    var existing: Set<URL> = []
    var pointer = CGPoint(x: 700, y: 400)
}

@MainActor
@Suite struct PinControllerTests {
    let clock = FakeClock()
    let log = PinActionLog()
    let flags = Flags()
    let recorder = RecordingPinFactory()
    /// One 1440 x 900 display with a 25 pt menu bar.
    let display = VisibleDisplay(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875)
    )

    func makeController(panels: Bool = true) -> PinController {
        let display = display
        let flags = flags
        return PinController(
            clock: clock,
            actions: log.actions(),
            displays: { [display] },
            pointer: { flags.pointer },
            reduceMotion: { flags.reduceMotion },
            fileExists: { flags.existing.contains($0) },
            makeSurface: panels ? recorder.factory : nil
        )
    }

    func image() -> CGImage {
        SyntheticImages.solid(width: 46, height: 27, color: .white) ?? FakeImages.fallback
    }

    func request(
        _ id: String, size: CGSize = CGSize(width: 460, height: 268), rect: CGRect? = nil, origin: PinOrigin = .menu
    ) -> PinRequest {
        PinRequest(
            itemID: id, image: image(), pointSize: size, screenRect: rect,
            fileURL: URL(filePath: "/tmp/snap-pin-test/\(id)/Snap.png"), origin: origin
        )
    }

    // MARK: Opening

    @Test func opensAtTheCaptureRectAndPresentsAPanel() throws {
        let controller = makeController()
        let rect = CGRect(x: 700, y: 300, width: 460, height: 268)
        let id = controller.open(request("a", rect: rect))
        let model = try #require(controller.pin(id))
        #expect(model.frame == rect)
        #expect(model.isOpaque)
        #expect(model.opacity == 1)
        let surface = try #require(recorder.surfaces[id])
        #expect(surface.presented.first?.0 == rect)
        #expect(surface.presented.first?.1 == .fadeScale)
        #expect(controller.pinnedItemIDs == ["a"])
    }

    @Test func entryMotionDependsOnTheOriginAndReduceMotion() {
        let controller = makeController()
        let thumb = CGRect(x: 24, y: 700, width: 240, height: 147)
        #expect(controller.entryTransition(for: .card(thumbnailFrame: thumb)) == .grow(from: thumb))
        #expect(controller.entryTransition(for: .card(thumbnailFrame: nil)) == .fadeScale)
        #expect(controller.entryTransition(for: .history) == .fadeScale)
        flags.reduceMotion = true
        #expect(controller.entryTransition(for: .card(thumbnailFrame: thumb)) == .fade)
        #expect(controller.exitTransition == .fade)
    }

    @Test func testsAndShotsMakeNoPanel() {
        let controller = makeController(panels: false)
        controller.open(request("a"))
        #expect(controller.pins.count == 1)
        #expect(recorder.made == 0)
        #expect(NSApplication.shared.windows.isEmpty)
    }

    @Test func aNinthPinClosesTheOldestAndItsPanel() throws {
        let controller = makeController()
        var ids: [Int] = []
        for index in 1...9 { ids.append(controller.open(request("p\(index)"))) }
        #expect(controller.pins.count == PinBoard.capacity)
        #expect(controller.pin(ids[0]) == nil)
        #expect(log.closed == ["p1"])
        let first = try #require(recorder.surfaces[ids[0]])
        #expect(first.dismissed == [.fadeScale])
        #expect(!controller.pinnedItemIDs.contains("p1"))
    }

    @Test func closeDismissesThePanelAndReportsTheItem() throws {
        let controller = makeController()
        let id = controller.open(request("a"))
        controller.perform(.close, on: id)
        #expect(controller.pins.isEmpty)
        #expect(log.closed == ["a"])
        #expect(try #require(recorder.surfaces[id]).dismissed == [.fadeScale])
        controller.open(request("b"))
        controller.open(request("c"))
        controller.closeAll()
        #expect(controller.pins.isEmpty)
        #expect(log.closed == ["a", "b", "c"])
    }

    // MARK: Moving, resizing, zooming

    @Test func moveFollowsThePointerOneToOneAndStaysOnTheDisplay() throws {
        let controller = makeController()
        let id = controller.open(request("a", rect: CGRect(x: 700, y: 300, width: 460, height: 268)))
        controller.moveBegan(id)
        controller.moveChanged(id, translation: CGSize(width: -100, height: 50))
        #expect(controller.pin(id)?.frame.origin == CGPoint(x: 600, y: 350))
        controller.moveChanged(id, translation: CGSize(width: 5000, height: 0))
        #expect(controller.pin(id)?.frame.maxX == 1440)
        controller.moveEnded(id)
        let surface = try #require(recorder.surfaces[id])
        #expect(surface.frames.last == controller.pin(id)?.frame)
    }

    @Test func liveResizeIsAspectLockedAndShowsTheSizeChip() throws {
        let controller = makeController()
        let id = controller.open(request("a", rect: CGRect(x: 100, y: 100, width: 460, height: 268)))
        controller.resizeBegan(id)
        #expect(controller.pin(id)?.sizeChipText == "460 \u{00D7} 268 \u{00B7} 100%")
        // The system dragged the bottom-right corner to a frame that breaks the aspect.
        controller.panelResized(id, to: CGRect(x: 100, y: 100, width: 690, height: 300))
        let frame = try #require(controller.pin(id)?.frame)
        #expect(frame.origin == CGPoint(x: 100, y: 100))
        #expect(abs(frame.width / frame.height - 460.0 / 268.0) < 0.001)
        #expect(controller.pin(id)?.sizeChipText == "690 \u{00D7} 402 \u{00B7} 150%")
        controller.resizeEnded(id)
        #expect(controller.pin(id)?.sizeChipText == nil)
    }

    @Test func resizeDragFindsTheMovedEdgeOrCorner() {
        let old = CGRect(x: 100, y: 100, width: 400, height: 200)
        let left = PinController.resizeDrag(from: old, to: CGRect(x: 60, y: 100, width: 440, height: 200))
        #expect(left?.0 == .left)
        let topLeft = PinController.resizeDrag(from: old, to: CGRect(x: 80, y: 90, width: 420, height: 210))
        #expect(topLeft?.0 == .topLeft)
        #expect(topLeft?.1 == CGPoint(x: 80, y: 90))
        let bottom = PinController.resizeDrag(from: old, to: CGRect(x: 100, y: 100, width: 400, height: 260))
        #expect(bottom?.0 == .bottom)
        #expect(PinController.resizeDrag(from: old, to: old) == nil)
    }

    @Test func zoomStepsTenPercentAndTheChipLeavesAfterASecond() async throws {
        let controller = makeController()
        let id = controller.open(request("a", rect: CGRect(x: 100, y: 100, width: 460, height: 268)))
        flags.pointer = CGPoint(x: 5, y: 5)
        controller.perform(.zoomIn, on: id)
        let zoomed = try #require(controller.pin(id)?.frame)
        #expect(abs(zoomed.width - 506) < 0.001 && abs(zoomed.height - 294.8) < 0.001)
        // Around the center when the pointer is not over the pin.
        #expect(abs(zoomed.midX - 330) < 0.001 && abs(zoomed.midY - 234) < 0.001)
        #expect(controller.pin(id)?.sizeChipText?.hasSuffix("110%") == true)
        controller.perform(.resetSize, on: id)
        #expect(controller.pin(id)?.frame.width == 460)
        clock.advance(by: 0.99)
        controller.processTimers()
        #expect(controller.pin(id)?.sizeChipText != nil)
        clock.advance(by: 0.01)
        controller.processTimers()
        #expect(controller.pin(id)?.sizeChipText == nil)
    }

    // MARK: Opacity, click-through, hover

    @Test func opacityKeysSliderAndScrollStepWithAFloor() {
        let controller = makeController()
        let id = controller.open(request("a"))
        #expect(controller.handleKey(id, characters: "5", keyCode: 23, modifiers: []))
        #expect(controller.pin(id)?.opacity == 0.5)
        #expect(controller.pin(id)?.opacityText == "50%")
        controller.stepOpacity(id, by: -20)
        #expect(controller.pin(id)?.opacity == 0.2)
        controller.perform(.setOpacity(0.73), on: id)
        #expect(controller.pin(id)?.opacity == 0.75)
        #expect(controller.handleKey(id, characters: "0", keyCode: 29, modifiers: []))
        #expect(controller.pin(id)?.opacity == 1)
    }

    @Test func clickThroughHidesTheChromeAndTellsThePanel() throws {
        let controller = makeController()
        let id = controller.open(request("a"))
        controller.setHovered(id, true)
        #expect(controller.pin(id)?.showsChrome == true)
        #expect(controller.handleKey(id, characters: "l", keyCode: 37, modifiers: []))
        let model = try #require(controller.pin(id))
        #expect(model.clickThrough && !model.isHovered && !model.showsChrome)
        controller.setHovered(id, true)
        #expect(!model.isHovered)
        controller.unlock(id)
        #expect(!model.clickThrough)
        #expect(try #require(recorder.surfaces[id]).clickThrough == [true, false])
        #expect(controller.menuEntries.map(\.clickThrough) == [false])
    }

    @Test func chromeCollapsesUnder260And120Points() {
        #expect(PinChromeLayout(width: 460) == .full)
        #expect(PinChromeLayout(width: 260) == .full)
        #expect(PinChromeLayout(width: 259) == .compact)
        #expect(PinChromeLayout(width: 120) == .compact)
        #expect(PinChromeLayout(width: 119) == .minimal)
    }

    // MARK: Keys and menu

    @Test func pinKeysMapToCommands() {
        #expect(PinKey.command(characters: "\u{1B}", keyCode: 53) == .close)
        #expect(PinKey.command(characters: "w", keyCode: 13, modifiers: .command) == .close)
        #expect(PinKey.command(characters: "c", keyCode: 8, modifiers: .command) == .copy)
        #expect(PinKey.command(characters: "s", keyCode: 1, modifiers: .command) == .save)
        #expect(PinKey.command(characters: "a", keyCode: 0) == .annotate)
        #expect(PinKey.command(characters: "=", keyCode: 24, modifiers: .command) == .zoomIn)
        #expect(PinKey.command(characters: "-", keyCode: 27, modifiers: .command) == .zoomOut)
        #expect(PinKey.command(characters: "0", keyCode: 29, modifiers: .command) == .resetSize)
        #expect(PinKey.command(characters: "0", keyCode: 29) == .setOpacity(1))
        #expect(PinKey.command(characters: "9", keyCode: 25) == .setOpacity(0.9))
        #expect(PinKey.command(characters: "1", keyCode: 18) == nil)
        #expect(PinKey.command(characters: "c", keyCode: 8) == nil)
    }

    @Test func commandsCallTheAppAndRevealNeedsTheFile() {
        let controller = makeController()
        let id = controller.open(request("a"))
        for command in [PinCommand.copy, .save, .annotate, .showInQuickAccess, .reveal] {
            controller.perform(command, on: id)
        }
        #expect(log.calls == ["copy a", "save a", "annotate a", "card a"])
        #expect(controller.moreMenu(for: id).first { $0.command == .reveal }?.isEnabled == false)
        flags.existing = [URL(filePath: "/tmp/snap-pin-test/a/Snap.png")]
        #expect(controller.moreMenu(for: id).first { $0.command == .reveal }?.isEnabled == true)
        controller.perform(.reveal, on: id)
        #expect(log.calls.last == "reveal Snap.png")
        #expect(controller.moreMenu(for: id).map(\.title) == [
            "Copy", "Save", "Open in Annotate", "Show in Quick Access", "Reveal in Finder", "Reset Size", "Close",
        ])
    }

    // MARK: Shot scene

    @Test func pinSceneRendersAtTwiceItsPointSizeWithoutAWindow() throws {
        let light = try #require(PinDemo.renderScene(dark: false))
        let dark = try #require(PinDemo.renderScene(dark: true))
        #expect(light.width == 2560 && light.height == 1600)
        #expect(dark.width == 2560 && dark.height == 1600)
        let pins = PinDemo.pins(dark: false)
        #expect(pins.contains { $0.showsChrome })
        #expect(pins.contains { $0.opacity == 0.6 })
        #expect(pins.contains { $0.clickThrough })
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }
}
