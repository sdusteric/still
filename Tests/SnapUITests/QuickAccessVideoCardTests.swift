import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

/// The video card and the Pin chip (design 20.2, 20.6 Result, D46, D67), driven without a panel.
@MainActor
@Suite struct QuickAccessVideoCardTests {
    let clock = FakeClock()
    let log = ActionLog()
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func makeController(box: QuickAccessControllerTests.SurfaceBox? = nil) -> QuickAccessController {
        var factory: QuickAccessController.SurfaceFactory?
        if let box {
            factory = { _ in
                box.made += 1
                let surface = FakeQuickAccessSurface()
                box.surface = surface
                return surface
            }
        }
        let visible = visible
        return QuickAccessController(
            clock: clock, actions: log.actions(), visibleFrame: { visible }, optionHeld: { false }, makeSurface: factory
        )
    }

    func poster() -> CGImage {
        SyntheticImages.solid(width: 128, height: 80, color: .black) ?? FakeImages.fallback
    }

    func video(_ id: String, seconds: Double = 42.4, copied: Bool = true) -> QuickAccessItem {
        QuickAccessItem(
            id: id, thumbnail: poster(), pointSize: CGSize(width: 1280, height: 800), copied: copied,
            kind: .video, durationSeconds: seconds
        )
    }

    func shot(_ id: String) -> QuickAccessItem {
        QuickAccessItem(id: id, thumbnail: poster(), pointSize: CGSize(width: 842, height: 516))
    }

    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: Video card

    @Test func videoCardShowsTheDurationInPlaceOfTheSizeAndCopied() {
        let controller = makeController()
        controller.show(video("v"))
        let card = try? #require(controller.card("v"))
        #expect(card?.isVideo == true)
        #expect(card?.durationText == "0:42")
        #expect(card?.pillText == "0:42")
        #expect(card?.showsCopied == true)
        #expect(controller.stack.kind(of: "v") == .video)
        // The poster of a 1280 x 800 recording is 150 pt tall at Medium, as in mockup 11c.
        #expect(card?.thumbnailSize == CGSize(width: 240, height: 150))
    }

    @Test func durationTextRoundsToWholeSecondsAndAddsHours() {
        #expect(QuickAccessCardModel.durationText(0) == "0:00")
        #expect(QuickAccessCardModel.durationText(2.6) == "0:03")
        #expect(QuickAccessCardModel.durationText(42.4) == "0:42")
        #expect(QuickAccessCardModel.durationText(725) == "12:05")
        #expect(QuickAccessCardModel.durationText(3725) == "1:02:05")
    }

    @Test func videoCardOffersOpenSaveRevealAndCopyOnly() {
        for action in [QuickAccessCardAction.open, .save, .reveal, .copy, .copyFile, .close] {
            #expect(action.isAvailable(on: .video))
        }
        for action in [QuickAccessCardAction.background, .backgroundEditor, .annotate, .pin] {
            #expect(!action.isAvailable(on: .video))
            #expect(action.isAvailable(on: .screenshot))
        }
        #expect(!QuickAccessCardAction.open.isAvailable(on: .screenshot))
    }

    @Test func copyOnAVideoCardCopiesTheFileURL() async {
        let controller = makeController()
        controller.show(video("v"))
        await controller.perform(.copy, on: "v")
        #expect(log.calls == ["copy file v"])
        #expect(controller.card("v")?.confirmedAction == .copy)
    }

    @Test func editActionsDoNothingOnAVideoCard() async {
        let controller = makeController()
        controller.show(video("v"))
        for action in [QuickAccessCardAction.background, .backgroundEditor, .annotate, .pin] {
            await controller.perform(action, on: "v")
        }
        #expect(log.calls.isEmpty)
        #expect(controller.card("v") != nil)
    }

    @Test func openAndRevealUseTheRecordingFile() async {
        let controller = makeController()
        controller.show(video("v"))
        await controller.perform(.open, on: "v")
        await controller.perform(.reveal, on: "v")
        // Not saved yet, so Reveal shows the mp4 in history (the drag URL).
        #expect(log.calls == ["open v", "reveal v.png"])
        controller.markSaved("v", url: URL(filePath: "/tmp/snap-test/Saved/Snap.mp4"))
        await controller.perform(.reveal, on: "v")
        #expect(log.calls.last == "reveal Snap.mp4")
        #expect(controller.card("v") != nil)
    }

    @Test func videoKeysAreOSRAndCAndEditKeysAreIgnored() async {
        #expect(QuickAccessKey(characters: "o", keyCode: 31) == .open)
        #expect(QuickAccessKey(characters: "r", keyCode: 15) == .reveal)
        #expect(QuickAccessKey(characters: "p", keyCode: 35) == .pin)
        let controller = makeController()
        controller.show(video("v"))
        controller.setHovered(true, for: "v")
        #expect(!controller.handleKey(.annotate))
        #expect(!controller.handleKey(.background))
        #expect(!controller.handleKey(.pin))
        #expect(controller.handleKey(.open))
        await settle()
        #expect(log.calls == ["open v"])
    }

    // MARK: Notes and reveal-only cards (design 20.6, D69)

    @Test func aRecordingNoteShowsForFourSecondsThenClears() {
        let controller = makeController()
        var item = video("v")
        item.note = "Stopped: the window closed"
        controller.show(item)
        #expect(controller.card("v")?.note == "Stopped: the window closed")
        clock.advance(by: 3.9)
        controller.processTimers()
        #expect(controller.card("v")?.note == "Stopped: the window closed")
        clock.advance(by: 0.1)
        controller.processTimers()
        #expect(controller.card("v")?.note == nil)
        #expect(controller.card("v") != nil, "the card stays after its note")
    }

    @Test func aRevealOnlyCardOffersRevealAndCloseOnly() async {
        let controller = makeController()
        var item = video("v", copied: false)
        item.revealOnly = true
        controller.show(item)
        let card = try? #require(controller.card("v"))
        #expect(card?.allows(.reveal) == true)
        #expect(card?.allows(.close) == true)
        for action in [QuickAccessCardAction.open, .save, .copy, .copyFile, .pin, .annotate] {
            #expect(card?.allows(action) == false, "\(action)")
            await controller.perform(action, on: "v")
        }
        #expect(log.calls.isEmpty)
        controller.setHovered(true, for: "v")
        #expect(!controller.handleKey(.open))
        #expect(!controller.handleKey(.copy))
        #expect(controller.handleKey(.reveal))
        await settle()
        #expect(log.calls == ["reveal v.png"])
    }

    @Test func aRevealOnlyCardRendersWithItsNote() throws {
        let card = QuickAccessCardModel(
            id: "v", thumbnail: poster(), pointSize: CGSize(width: 1280, height: 800), kind: .video, durationSeconds: 3
        )
        card.revealOnly = true
        card.note = "No microphone"
        let renderer = ImageRenderer(content: QuickAccessCardView(card: card, interactive: false))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0 && image.height > 0)
        card.isHovered = true
        let hovered = try #require(ImageRenderer(content: QuickAccessCardView(card: card, interactive: false)).cgImage)
        #expect(hovered.width == image.width / 2)
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }

    @Test func videoCardsCloseAfterFifteenSecondsLikeScreenshots() {
        let controller = makeController()
        controller.show(video("v"))
        clock.advance(by: 15)
        controller.processTimers()
        #expect(controller.cards.isEmpty)
        #expect(log.closed.first?.1 == .autoClose)
    }

    // MARK: Pin chip on screenshot cards

    @Test func pinClosesTheScreenshotCardWhenAPinOpened() async {
        let controller = makeController()
        controller.show(shot("s"))
        controller.setHovered(true, for: "s")
        #expect(controller.handleKey(.pin))
        await settle()
        #expect(log.calls == ["pin s"])
        #expect(controller.card("s") == nil)
        #expect(log.closed.first?.1 == .pinned)
    }

    @Test func aFailedPinKeepsTheCard() async {
        log.pinSucceeds = false
        let controller = makeController()
        controller.show(shot("s"))
        await controller.perform(.pin, on: "s")
        #expect(log.calls == ["pin s"])
        #expect(controller.card("s") != nil)
    }

    @Test func thumbnailFrameFollowsTheStackFromTheCorner() {
        let controller = makeController(box: QuickAccessControllerTests.SurfaceBox())
        controller.show(shot("old"))
        controller.show(video("new"))
        // Bottom-left: the newest card sits 16 pt in from the corner, its thumbnail 8 pt inside.
        let newest = try? #require(controller.thumbnailFrame(for: "new"))
        #expect(newest == CGRect(x: 24, y: 24, width: 240, height: 150))
        let older = try? #require(controller.thumbnailFrame(for: "old"))
        // Above it: the newest card's 166 pt plus the 8 pt gap.
        #expect(older == CGRect(x: 24, y: 16 + 166 + 8 + 8, width: 240, height: 147))
        #expect(controller.thumbnailFrame(for: "gone") == nil)
    }

    // MARK: Shot scene

    @Test func videoSceneRendersAtTwiceItsPointSizeWithoutAWindow() throws {
        let light = try #require(QuickAccessDemo.renderVideoScene(dark: false))
        let dark = try #require(QuickAccessDemo.renderVideoScene(dark: true))
        #expect(light.width == 1200 && light.height == 1520)
        #expect(dark.width == 1200 && dark.height == 1520)
        let cards = QuickAccessDemo.videoCards()
        #expect(cards.map(\.kind) == [.video, .video, .screenshot])
        #expect(cards[0].showsCopied && !cards[0].isHovered)
        #expect(cards[1].isHovered && cards[2].isHovered)
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }
}
