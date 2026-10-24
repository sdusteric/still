import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

/// Records what the overlay view forwards.
@MainActor
final class RecordingOverlaySink: OverlayEventSink {
    var events: [OverlayInputEvent] = []
    func overlayEvent(_ event: OverlayInputEvent) { events.append(event) }
}

/// The Snap side of the hands-on checks in docs/acceptance.md, checked without a window: the
/// AppKit glue between an event or a drag and the controllers. What is left for the user is only
/// what the window server does (key focus, cursor visibility, click routing, drops in other apps).
@MainActor
@Suite struct PanelGlueTests {
    private func keyDown(_ keyCode: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    // MARK: Check 2: overlay keys

    @Test func theOverlayViewTakesFirstResponderAndForwardsEscSpaceAndTab() throws {
        let display = try #require(DisplayInfo.fakeSideBySide.first)
        let view = SelectionOverlayView(state: SelectionOverlayState(display: display), drawsFrozenImage: false)
        let sink = RecordingOverlaySink()
        view.eventSink = sink
        #expect(view.acceptsFirstResponder, "makeFirstResponder(overlayView) needs this")

        // Delivered straight to the view object: nothing is posted to the system.
        view.keyDown(with: try keyDown(53, "\u{1B}"))
        view.keyDown(with: try keyDown(49, " "))
        view.keyDown(with: try keyDown(48, "\t"))
        #expect(sink.events == [
            .keyDown(.escape, modifiers: [], isRepeat: false),
            .keyDown(.space, modifiers: [], isRepeat: false),
            .keyDown(.tab, modifiers: [], isRepeat: false),
        ])
    }

    // MARK: Check 3: Quick Access keys

    @Test func handingTheKeysBackOrdersThePanelOutAndFrontInsteadOfResigningKey() {
        typealias Panel = QuickAccessPanel
        // Taking the keys: only a visible panel is made key.
        #expect(Panel.keySteps(accepts: true, isVisible: true, isKey: false) == [.makeKey])
        #expect(Panel.keySteps(accepts: true, isVisible: false, isKey: false).isEmpty)
        // Handing them back: resignKey() must not be invoked directly (AppKit only informs the
        // window then), so the key panel is ordered out, which returns key focus to the active
        // app, and ordered front again with its cards still showing.
        #expect(Panel.keySteps(accepts: false, isVisible: true, isKey: true) == [.orderOut, .orderFront])
        // A panel that is not key has nothing to hand back and must not flicker.
        #expect(Panel.keySteps(accepts: false, isVisible: true, isKey: false).isEmpty)
        #expect(Panel.keySteps(accepts: false, isVisible: false, isKey: false).isEmpty)
    }

    // MARK: Check 5: drag-out

    @Test func theDragOffersOnlyACopyOfTheHistoryFile() throws {
        #expect(ThumbnailDragSourceView.operationMask(for: .outsideApplication) == .copy)
        #expect(ThumbnailDragSourceView.operationMask(for: .withinApplication) == .copy)

        // The same writer the drag puts on the drag pasteboard, written to a private one.
        let url = URL(filePath: "/tmp/snap-test/history/a/Snap 2026-10-24 at 10.00.00.png")
        let board = NSPasteboard(name: NSPasteboard.Name("dev.sdusteric.snap.tests.drag.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(board.writeObjects([ThumbnailDragSourceView.pasteboardWriter(for: url)]))
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.types?.contains(.fileURL) == true)
        let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(read == [url])
    }

    // MARK: Check 4: clicks through the transparent panel

    /// The window server passes a click through a non-opaque window only where its pixels are
    /// fully transparent. The panel is a 70% tall column, so everything above the stack and its
    /// shadow margin must render with alpha 0, in both appearances.
    @Test func thePanelIsFullyTransparentAboveTheStack() throws {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = QuickAccessLayout.panelFrame(visibleFrame: visible, corner: .bottomLeft, size: .medium)
        let pointSize = CGSize(width: 842, height: 516)
        let thumbnail = SyntheticImages.solid(width: 84, height: 52, color: .white) ?? FakeImages.fallback
        let margin = QuickAccessLayout.shadowMargin
        let cardHeight = QuickAccessLayout.cardHeight(pointSize: pointSize, size: .medium)
        let cardTop = frame.height - margin - cardHeight

        for dark in [false, true] {
            let card = QuickAccessCardModel(id: "a", thumbnail: thumbnail, pointSize: pointSize)
            let stack = QuickAccessStackView(cards: [card], corner: .bottomLeft, interactive: false) { _ in .inert }
            let image = try #require(QuickAccessDemo.render(stack, size: frame.size, dark: dark, scale: 2))
            #expect(image.width == Int(frame.width * 2) && image.height == Int(frame.height * 2), "panel size")
            let bytes = try #require(SyntheticImages.rgbaBytes(of: image))
            func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * image.width + x) * 4 + 3] }

            let clearRows = Int(((cardTop - margin) * 2).rounded(.down))
            #expect(clearRows > 100, "the test needs a transparent region to look at")
            var maxAlpha: UInt8 = 0
            for y in 0..<clearRows {
                for x in 0..<image.width { maxAlpha = max(maxAlpha, alpha(x, y)) }
            }
            #expect(maxAlpha == 0, "dark \(dark): a pixel above the stack has alpha \(maxAlpha)")

            let centreX = Int((margin + QuickAccessLayout.cardWidth(.medium) / 2) * 2)
            let centreY = Int((cardTop + cardHeight / 2) * 2)
            #expect(alpha(centreX, centreY) == 255, "dark \(dark): the card itself must take the click")
        }
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }
}
