import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

enum FakeImages {
    static var fallback: CGImage {
        guard let context = SyntheticImages.makeContext(width: 1, height: 1), let image = context.makeImage() else {
            fatalError("a 1 x 1 bitmap context could not be made")
        }
        return image
    }
}

@MainActor
final class FakeQuickAccessSurface: QuickAccessSurface {
    var frames: [CGRect] = []
    var hideCount = 0
    var acceptsKeys: [Bool] = []
    var isVisible = false

    /// Always set, so the tests check the controller's own visibility gate.
    var windowID: WindowID? { 8100 }

    func show(frame: CGRect) {
        frames.append(frame)
        isVisible = true
    }

    func hide() {
        hideCount += 1
        isVisible = false
    }

    func setAcceptsKeys(_ accepts: Bool) { acceptsKeys.append(accepts) }
}

/// Records which closures a card called.
@MainActor
final class ActionLog {
    var calls: [String] = []
    var closed: [(String, QuickAccessStack.CloseReason)] = []
    var copySucceeds = true
    var savedURL: URL? = URL(filePath: "/tmp/snap-test/Still shot.png")
    var thumbnail: QuickAccessThumbnail?
    var pinSucceeds = true
    var copyTextOutcome: CaptureText.Outcome = .copied
    var trashSucceeds = true

    func actions() -> QuickAccessActions {
        QuickAccessActions(
            copy: { id in
                self.calls.append("copy \(id)")
                return self.copySucceeds
            },
            copyFile: { id in
                self.calls.append("copy file \(id)")
                return self.copySucceeds
            },
            save: { id in
                self.calls.append("save \(id)")
                return self.savedURL
            },
            toggleBackground: { id in
                self.calls.append("background \(id)")
                return self.thumbnail
            },
            openBackgroundEditor: { id in self.calls.append("editor \(id)") },
            annotate: { id in self.calls.append("annotate \(id)") },
            reveal: { url in self.calls.append("reveal \(url.lastPathComponent)") },
            dragURL: { id in URL(filePath: "/tmp/snap-test/\(id).png") },
            pin: { id in
                self.calls.append("pin \(id)")
                return self.pinSucceeds
            },
            open: { id in self.calls.append("open \(id)") },
            copyText: { id in
                self.calls.append("copy text \(id)")
                return self.copyTextOutcome
            },
            trash: { id in
                self.calls.append("trash \(id)")
                return self.trashSucceeds
            },
            closed: { id, reason in self.closed.append((id, reason)) }
        )
    }
}

@MainActor
@Suite struct QuickAccessControllerTests {
    let clock = FakeClock()
    let log = ActionLog()
    let visible = CGRect(x: 0, y: 0, width: 2560, height: 1415)

    final class SurfaceBox {
        var surface: FakeQuickAccessSurface?
        var made = 0
    }

    final class OptionKey {
        var held = false
    }

    func makeController(
        settings: QuickAccessSettings = QuickAccessSettings(), box: SurfaceBox? = nil, option: OptionKey = OptionKey(),
        reduceMotion: Bool = false
    ) -> QuickAccessController {
        let visible = visible
        var factory: QuickAccessController.SurfaceFactory?
        if let box {
            factory = { _ in
                box.made += 1
                let surface = FakeQuickAccessSurface()
                box.surface = surface
                return surface
            }
        }
        return QuickAccessController(
            clock: clock,
            settings: settings,
            actions: log.actions(),
            visibleFrame: { visible },
            reduceMotion: { reduceMotion },
            optionHeld: { option.held },
            makeSurface: factory
        )
    }

    func item(_ id: String, size: CGSize = CGSize(width: 842, height: 516), copied: Bool = true) -> QuickAccessItem {
        let image = SyntheticImages.solid(width: 84, height: 52, color: .white) ?? FakeImages.fallback
        return QuickAccessItem(id: id, thumbnail: image, pointSize: size, copied: copied)
    }

    func advance(_ controller: QuickAccessController, by seconds: Double) {
        clock.advance(by: seconds)
        controller.processTimers()
    }

    @Test func newestCardComesFirstAndCopiedShowsForTwoSeconds() {
        let controller = makeController()
        controller.show(item("a"))
        controller.show(item("b"))
        #expect(controller.cards.map(\.id) == ["b", "a"])
        #expect(controller.card("a")?.showsCopied == true)
        advance(controller, by: 1.9)
        #expect(controller.card("a")?.showsCopied == true)
        advance(controller, by: 0.1)
        #expect(controller.card("a")?.showsCopied == false)
        #expect(controller.card("b")?.dimensionText == "842 \u{00D7} 516")
    }

    @Test func cardsCloseAfterFifteenSeconds() {
        let controller = makeController()
        controller.show(item("a"))
        advance(controller, by: 14.9)
        #expect(controller.cards.count == 1)
        advance(controller, by: 0.1)
        #expect(controller.cards.isEmpty)
        #expect(log.closed.map(\.0) == ["a"])
        #expect(log.closed.first?.1 == .autoClose)
    }

    @Test func hoverPausesAndLeavingRestartsTheFullInterval() {
        let controller = makeController()
        controller.show(item("a"))
        advance(controller, by: 10)
        controller.setHovered(true, for: "a")
        advance(controller, by: 30)
        #expect(controller.cards.count == 1)
        controller.setHovered(false, for: "a")
        advance(controller, by: 14.9)
        #expect(controller.cards.count == 1)
        advance(controller, by: 0.1)
        #expect(controller.cards.isEmpty)
    }

    @Test func countdownShowsOnlyInTheLastFiveSecondsAndNotWhileHovered() {
        let controller = makeController()
        controller.show(item("a"))
        advance(controller, by: 9.9)
        #expect(controller.card("a")?.countdown == nil)
        advance(controller, by: 0.1)
        let countdown = controller.card("a")?.countdown
        #expect(countdown != nil)
        #expect(countdown?.startFraction == 1)
        controller.setHovered(true, for: "a")
        #expect(controller.card("a")?.countdown == nil)
        #expect(controller.nextWake == nil)
    }

    @Test func aSixthCardClosesTheOldest() {
        let controller = makeController()
        for index in 1...6 { controller.show(item("c\(index)")) }
        #expect(controller.cards.map(\.id) == ["c6", "c5", "c4", "c3", "c2"])
        #expect(log.closed.first?.0 == "c1")
        #expect(log.closed.first?.1 == .overflow)
    }

    @Test func theStackStaysUnderSeventyPercentOfTheScreen() {
        let controller = makeController()
        // Tall captures make 236 pt cards; 70% of 1415 is 990.5, so four fit and the fifth pushes one out.
        for index in 1...5 { controller.show(item("t\(index)", size: CGSize(width: 300, height: 900))) }
        #expect(controller.cards.count == 4)
        #expect(log.closed.first?.1 == .tooTall)
        #expect(controller.stack.stackHeight <= QuickAccessLayout.maxStackHeight(visibleFrame: visible))
    }

    @Test func copyShowsACheckForNineHundredMillisecondsThenCloses() async {
        let controller = makeController()
        controller.show(item("a"))
        await controller.perform(.copy, on: "a")
        #expect(log.calls == ["copy a"])
        #expect(controller.card("a")?.confirmedAction == .copy)
        advance(controller, by: 0.89)
        #expect(controller.cards.count == 1)
        advance(controller, by: 0.01)
        #expect(controller.cards.isEmpty)
        #expect(log.closed.first?.1 == .copied)
    }

    @Test func optionOnCopyCopiesTheFileInstead() async {
        let option = OptionKey()
        let controller = makeController(option: option)
        controller.show(item("a"))
        controller.show(item("b"))
        controller.handler(for: "a").perform(.copy)
        for _ in 0..<5 { await Task.yield() }
        #expect(log.calls == ["copy a"])

        option.held = true
        controller.handler(for: "b").hover(true)
        #expect(controller.card("b")?.copiesFile == true)
        controller.handler(for: "b").perform(.copy)
        for _ in 0..<5 { await Task.yield() }
        #expect(log.calls == ["copy a", "copy file b"])
        #expect(controller.card("b")?.confirmedAction == .copy)

        // The panel reports Option going up, and the button reads Copy again.
        controller.setOptionHeld(false)
        #expect(controller.card("b")?.copiesFile == false)
    }

    @Test func optionCOnAHoveredCardCopiesTheFile() async {
        #expect(QuickAccessKey(characters: "c", keyCode: 8, modifiers: .option) != nil)
        #expect(QuickAccessKey(characters: "c", keyCode: 8, modifiers: .option) == .copyFile)
        #expect(QuickAccessKey(characters: "s", keyCode: 1, modifiers: .option) == nil)
        let controller = makeController()
        controller.show(item("a"))
        controller.setHovered(true, for: "a")
        #expect(controller.handleKey(.copyFile))
        for _ in 0..<5 { await Task.yield() }
        #expect(log.calls == ["copy file a"])
    }

    @Test func aFailedCopyKeepsTheCardWithoutACheck() async {
        log.copySucceeds = false
        let controller = makeController()
        controller.show(item("a"))
        await controller.perform(.copy, on: "a")
        #expect(controller.card("a")?.confirmedAction == nil)
        advance(controller, by: 1)
        #expect(controller.cards.count == 1)
    }

    @Test func withCloseAfterCopyOffTheCheckRevertsAndTheCardStays() async {
        var settings = QuickAccessSettings()
        settings.closeAfterCopyOrSave = false
        let controller = makeController(settings: settings)
        controller.show(item("a"))
        await controller.perform(.copy, on: "a")
        advance(controller, by: 0.9)
        #expect(controller.cards.count == 1)
        #expect(controller.card("a")?.confirmedAction == nil)
    }

    @Test func saveRecordsTheFileAndRevealUsesIt() async {
        var settings = QuickAccessSettings()
        settings.closeAfterCopyOrSave = false
        let controller = makeController(settings: settings)
        controller.show(item("a"))
        #expect(controller.card("a")?.compactBar == false)
        await controller.perform(.save, on: "a")
        #expect(controller.card("a")?.savedURL?.lastPathComponent == "Still shot.png")
        #expect(controller.card("a")?.compactBar == true)
        await controller.perform(.reveal, on: "a")
        #expect(log.calls == ["save a", "reveal Still shot.png"])
    }

    @Test func saveClosesTheCardWhenTheSettingIsOn() async {
        let controller = makeController()
        controller.show(item("a"))
        await controller.perform(.save, on: "a")
        advance(controller, by: 0.9)
        #expect(controller.cards.isEmpty)
        #expect(log.closed.first?.1 == .saved)
    }

    @Test func backgroundSwapsTheThumbnailAndThePill() async throws {
        let controller = makeController()
        controller.show(item("a"))
        let image = try #require(SyntheticImages.solid(width: 91, height: 59, color: .red))
        log.thumbnail = QuickAccessThumbnail(image: image, pointSize: CGSize(width: 914, height: 588), backgroundApplied: true)
        await controller.perform(.background, on: "a")
        let card = try #require(controller.card("a"))
        #expect(card.thumbnail === image)
        #expect(card.thumbnailVersion == 1)
        #expect(card.backgroundApplied)
        #expect(card.dimensionText == "914 \u{00D7} 588")
        #expect(controller.stack.cards.first?.height == QuickAccessLayout.cardHeight(pointSize: card.pointSize, size: .medium))
    }

    @Test func editorAnnotateAndCloseCallTheApp() async {
        let controller = makeController()
        controller.show(item("a"))
        await controller.perform(.backgroundEditor, on: "a")
        await controller.perform(.annotate, on: "a")
        await controller.perform(.close, on: "a")
        #expect(log.calls == ["editor a", "annotate a"])
        #expect(controller.cards.isEmpty)
        #expect(log.closed.first?.1 == .dismissed)
    }

    @Test func copyTextShowsItsOutcomeAsANoteAndLeavesTheCardOpen() async {
        let controller = makeController()
        controller.show(item("a"))
        await controller.perform(.copyText, on: "a")
        #expect(log.calls == ["copy text a"])
        #expect(controller.card("a")?.note == "Text copied")
        log.copyTextOutcome = .noText
        await controller.perform(.copyText, on: "a")
        #expect(controller.card("a")?.note == "No text found")
        advance(controller, by: Theme.QuickAccessM2.noteSeconds)
        #expect(controller.card("a")?.note == nil)
        #expect(controller.card("a") != nil)
        #expect(QuickAccessKey(characters: "t", keyCode: 17) == .copyText)
        #expect(!QuickAccessCardAction.copyText.isAvailable(on: .video))
    }

    @Test func trashMovesTheCaptureToTheTrashAndClosesItsCard() async {
        let controller = makeController()
        controller.show(item("a"))
        controller.show(item("b"))
        await controller.perform(.trash, on: "a")
        #expect(log.calls == ["trash a"])
        #expect(controller.card("a") == nil)
        #expect(log.closed.last.map { $0.0 == "a" && $0.1 == .trashed } == true)
        #expect(controller.card("b") != nil)

        log.trashSucceeds = false
        await controller.perform(.trash, on: "b")
        #expect(controller.card("b") != nil, "a failed trash keeps the card")

        #expect(QuickAccessKey(characters: nil, keyCode: 51, modifiers: .command) == .trash)
        #expect(QuickAccessKey(characters: nil, keyCode: 117, modifiers: .command) == .trash)
        #expect(QuickAccessKey(characters: nil, keyCode: 51) == .close, "plain Delete still only closes")
        #expect(QuickAccessCardAction.trash.isAvailable(on: .video))
    }

    @Test func aFailedClipboardWriteTakesBackTheCopiedChip() {
        let controller = makeController()
        controller.show(item("a"))
        #expect(controller.card("a")?.showsCopied == true)
        controller.markNotCopied("a")
        #expect(controller.card("a")?.showsCopied == false)
        #expect(controller.card("a")?.note == "Not copied")
        controller.showNote("Not saved to History", on: "a")
        #expect(controller.card("a")?.note == "Not saved to History")
    }

    @Test func aHoveredCardGrabsItsKeysBecauseTheBackgroundPanelGetsNone() async throws {
        let controller = makeController()
        var grabs: [Bool] = []
        controller.onKeyGrabChanged = { grabs.append($0) }
        controller.show(item("a"))
        controller.show(item("b"))
        controller.setHovered(true, for: "a")
        controller.setHovered(true, for: "b")
        #expect(grabs == [true], "one grab while any card is hovered")
        let annotate = try #require(QuickAccessController.grabbedKeys.firstIndex { $0.key == .annotate })
        controller.grabbedKey(at: annotate)
        for _ in 0..<5 { await Task.yield() }
        #expect(log.calls.contains("annotate a") || log.calls.contains("annotate b"))
        controller.setHovered(false, for: "a")
        controller.setHovered(false, for: "b")
        #expect(grabs == [true, false])

        let keys = QuickAccessController.grabbedKeys
        #expect(keys.contains { $0.shortcut == KeyShortcut(keyCode: 51, modifiers: KeyShortcut.Modifier.command) && $0.key == .trash })
        #expect(keys.contains { $0.shortcut == KeyShortcut(keyCode: 8, modifiers: KeyShortcut.Modifier.option) && $0.key == .copyFile })
        #expect(keys.contains { $0.shortcut == KeyShortcut(keyCode: 53, modifiers: 0) && $0.key == .close })
    }

    @Test func theCardKeyGrabEndsAfterAFewSecondsSoTypingElsewhereIsNotStolen() async {
        // Letters grabbed system-wide while the pointer only rests on a card would be lost to the
        // app the user types in; the grab lasts a few seconds from the hover or the last key.
        let controller = makeController()
        var grabs: [Bool] = []
        controller.onKeyGrabChanged = { grabs.append($0) }
        controller.show(item("a"))
        controller.setHovered(true, for: "a")
        #expect(grabs == [true])
        for _ in 0..<5 { await Task.yield() }
        clock.advance(by: QuickAccessController.keyGrabSeconds - 0.5)
        for _ in 0..<5 { await Task.yield() }
        #expect(grabs == [true])
        clock.advance(by: 0.5)
        for _ in 0..<20 where grabs.count < 2 { await Task.yield() }
        #expect(grabs == [true, false], "still hovered, but the keys go back to the front app")
        controller.setHovered(false, for: "a")
        controller.setHovered(true, for: "a")
        #expect(grabs == [true, false, true], "a new hover grabs again")
    }

    @Test func keysActOnlyOnTheHoveredCard() async {
        let controller = makeController()
        controller.show(item("a"))
        controller.show(item("b"))
        #expect(!controller.handleKey(.annotate))
        controller.setHovered(true, for: "a")
        #expect(controller.handleKey(.annotate))
        for _ in 0..<5 { await Task.yield() }
        #expect(log.calls == ["annotate a"])

        #expect(QuickAccessKey(characters: "c", keyCode: 8) == .copy)
        #expect(QuickAccessKey(characters: "S", keyCode: 1) == .save)
        #expect(QuickAccessKey(characters: "a", keyCode: 0) == .annotate)
        #expect(QuickAccessKey(characters: "b", keyCode: 11) == .background)
        #expect(QuickAccessKey(characters: nil, keyCode: 51) == .close)
        #expect(QuickAccessKey(characters: "\u{1B}", keyCode: 53) == .close)
        #expect(QuickAccessKey(characters: "c", keyCode: 8, modifiers: .command) == nil)
        #expect(QuickAccessKey(characters: "x", keyCode: 7) == nil)
    }

    @Test func thePanelTakesKeysOnlyWhileACardIsHovered() async throws {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.show(item("a"))
        controller.show(item("b"))
        let surface = try #require(box.surface)
        #expect(!surface.acceptsKeys.contains(true), "showing a card must not take the keys")

        controller.handler(for: "a").hover(true)
        #expect(surface.acceptsKeys.last == true)
        controller.handler(for: "a").hover(false)
        #expect(surface.acceptsKeys.last == false)
        #expect(!controller.handleKey(.close), "Esc with nothing hovered belongs to the frontmost app")

        // Esc on the hovered card closes it. The closed card never reports the pointer leaving,
        // so the controller itself hands the keys back while card "a" stays on screen.
        controller.handler(for: "b").hover(true)
        #expect(surface.acceptsKeys.last == true)
        #expect(controller.handleKey(.close))
        for _ in 0..<5 { await Task.yield() }
        #expect(controller.card("b") == nil)
        #expect(controller.card("a") != nil)
        #expect(surface.acceptsKeys.last == false)
        #expect(controller.hoveredCard == nil)
    }

    @Test func closingTheHoveredCardAnyWayHandsTheKeysBack() async throws {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        controller.show(item("a"))
        controller.show(item("b"))
        controller.show(item("c"))
        let surface = try #require(box.surface)

        controller.setHovered(true, for: "c")
        controller.dragBegan("c")
        controller.dragEnded("c", accepted: true)
        #expect(controller.card("c") == nil)
        #expect(surface.acceptsKeys.last == false, "after a drag-out")

        controller.setHovered(true, for: "b")
        controller.close("b")
        #expect(surface.acceptsKeys.last == false, "after the close button")

        controller.setHovered(true, for: "a")
        #expect(surface.acceptsKeys.last == true)
        advance(controller, by: 30)
        #expect(controller.card("a") != nil, "a hovered card does not auto close")
        controller.setHovered(false, for: "a")
        advance(controller, by: 30)
        #expect(controller.cards.isEmpty)
        #expect(surface.acceptsKeys.last == false, "after auto close")
    }

    @Test func anAcceptedDropClosesAndACancelledDragKeepsTheCard() {
        let controller = makeController()
        controller.show(item("a"))
        controller.show(item("b"))
        controller.dragBegan("a")
        #expect(controller.card("a")?.isDragging == true)
        advance(controller, by: 30)
        #expect(controller.card("a") != nil)
        controller.dragEnded("a", accepted: false)
        #expect(controller.card("a")?.isDragging == false)
        advance(controller, by: 14.9)
        #expect(controller.card("a") != nil)
        controller.dragBegan("a")
        controller.dragEnded("a", accepted: true)
        #expect(controller.card("a") == nil)
        #expect(log.closed.contains { $0.0 == "a" && $0.1 == .draggedOut })
    }

    @Test func swipeDismissUsesTheDistanceAndVelocityThresholds() {
        let left = SwipeDismissRule(corner: .bottomLeft)
        #expect(!left.shouldDismiss(translation: -79, velocity: -100))
        #expect(left.shouldDismiss(translation: -81, velocity: 0))
        #expect(left.shouldDismiss(translation: -10, velocity: -401))
        #expect(!left.shouldDismiss(translation: 200, velocity: 900))
        #expect(left.displayOffset(for: -50) == -50)
        #expect(left.displayOffset(for: 100) == 100 * Theme.QuickAccess.rubberBand)
        let right = SwipeDismissRule(corner: .topRight)
        #expect(right.shouldDismiss(translation: 81, velocity: 0))
        #expect(!right.shouldDismiss(translation: -81, velocity: 0))

        let controller = makeController()
        controller.show(item("a"))
        controller.swipeChanged("a", translation: 40)
        #expect(controller.card("a")?.swipeOffset == 40 * Theme.QuickAccess.rubberBand)
        #expect(!controller.swipeEnded("a", translation: -60, velocity: -100))
        #expect(controller.card("a")?.swipeOffset == 0)
        #expect(controller.swipeEnded("a", translation: -90, velocity: 0))
        #expect(controller.cards.isEmpty)
    }

    @Test func aSwipeDismissCarriesTheCardTowardTheEdgeAndOnlyFades() throws {
        let controller = makeController()
        controller.show(item("a"))
        let card = try #require(controller.card("a"))
        controller.swipeChanged("a", translation: -60)
        #expect(controller.swipeEnded("a", translation: -60, velocity: -900))
        #expect(card.swipeDismissed)
        #expect(card.swipeOffset == -60 + Theme.Motion.cardDismissOffsetX)
        #expect(controller.cards.isEmpty)

        let reduced = makeController(reduceMotion: true)
        reduced.show(item("b"))
        let still = try #require(reduced.card("b"))
        reduced.swipeChanged("b", translation: -90)
        #expect(reduced.swipeEnded("b", translation: -90, velocity: 0))
        #expect(!still.swipeDismissed)
        #expect(still.swipeOffset == -90)
    }

    @Test func stackMotionUsesTheSpringForReflowAndTheExitCurveForRemoval() {
        #expect(QuickAccessMotion.reflow(reduceMotion: false) == Theme.Motion.spring)
        #expect(QuickAccessMotion.reflow(reduceMotion: true) == nil)
        #expect(QuickAccessMotion.removal(reduceMotion: false) == Theme.Motion.exit(Theme.Motion.dismiss))
        #expect(QuickAccessMotion.removal(reduceMotion: true) == .easeOut(duration: Theme.Motion.reducedMotionFade))
        #expect(QuickAccessMotion.swipeRelease(velocity: 400) != QuickAccessMotion.swipeRelease(velocity: 0))
    }

    @Test func layoutMatchesTheDesignSizes() {
        #expect(QuickAccessLayout.cardWidth(.medium) == 256)
        #expect(QuickAccessLayout.thumbnailHeight(pointSize: CGSize(width: 842, height: 516), size: .medium) == 147)
        #expect(QuickAccessLayout.thumbnailHeight(pointSize: CGSize(width: 560, height: 640), size: .medium) == 220)
        #expect(QuickAccessLayout.thumbnailHeight(pointSize: CGSize(width: 2000, height: 100), size: .medium) == 96)
        #expect(QuickAccessLayout.cardWidth(.small) == 196)
        let frame = QuickAccessLayout.panelFrame(visibleFrame: visible, corner: .bottomLeft, size: .medium)
        #expect(frame.minX + QuickAccessLayout.shadowMargin == 16)
        #expect(frame.minY + QuickAccessLayout.shadowMargin == 16)
        let topRight = QuickAccessLayout.panelFrame(visibleFrame: visible, corner: .topRight, size: .medium)
        #expect(abs(topRight.maxX - QuickAccessLayout.shadowMargin - (visible.maxX - 16)) < 0.001)
        #expect(abs(topRight.maxY - QuickAccessLayout.shadowMargin - (visible.maxY - 16)) < 0.001)
    }

    @Test func thePanelIsMadeLazilyOnceAndHiddenAfterTheLastCard() {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        #expect(box.made == 0)
        controller.show(item("a"))
        controller.show(item("b"))
        #expect(box.made == 1)
        #expect(box.surface?.isVisible == true)
        #expect(box.surface?.frames.last == QuickAccessLayout.panelFrame(visibleFrame: visible, corner: .bottomLeft, size: .medium))
        controller.setHovered(true, for: "a")
        #expect(box.surface?.acceptsKeys.last == true)
        controller.setHovered(false, for: "a")
        #expect(box.surface?.acceptsKeys.last == false)
        controller.closeAll()
        #expect(box.surface?.isVisible == true)
        advance(controller, by: 0.3)
        #expect(box.surface?.isVisible == false)
    }

    /// Regression: an earlier card must not be baked into the next capture, so the panel is in
    /// the exclusion list exactly while it is on screen.
    @Test func panelWindowIsExcludedOnlyWhileOnScreen() {
        let box = SurfaceBox()
        let controller = makeController(box: box)
        #expect(controller.surfaceWindowIDs.isEmpty)
        controller.show(item("a"))
        #expect(controller.surfaceWindowIDs == [8100])
        controller.closeAll()
        #expect(controller.surfaceWindowIDs == [8100])
        advance(controller, by: 0.3)
        #expect(box.surface?.isVisible == false)
        #expect(controller.surfaceWindowIDs.isEmpty)
        #expect(makeController().surfaceWindowIDs.isEmpty)
    }

    @Test func scheduledTimersFireThroughTheClock() async {
        let controller = makeController()
        controller.show(item("a"))
        #expect(controller.nextWake == 2)
        for _ in 0..<20 where clock.sleeperCount == 0 { await Task.yield() }
        #expect(clock.sleeperCount == 1)
        for step in [2.0, 8.0, 5.0] {
            clock.advance(by: step)
            for _ in 0..<50 { await Task.yield() }
        }
        #expect(controller.cards.isEmpty)
    }
}

@MainActor
@Suite struct QuickAccessCardRenderTests {
    func render(_ card: QuickAccessCardModel, dark: Bool) -> CGImage? {
        let size = CGSize(width: card.cardSize.width + 80, height: card.cardSize.height + 80)
        let view = ZStack {
            (dark ? Color.black : Color.white)
            QuickAccessCardView(card: card, interactive: false)
        }
        .frame(width: size.width, height: size.height)
        return QuickAccessDemo.render(view, size: size, dark: dark)
    }

    @Test func aCardRendersNonBlankAndDiffersBetweenLightAndDark() throws {
        let light = try #require(QuickAccessDemo.cards(dark: false).first)
        let dark = try #require(QuickAccessDemo.cards(dark: true).first)
        let lightImage = try #require(render(light, dark: false))
        let darkImage = try #require(render(dark, dark: true))
        #expect(lightImage.width == Int((light.cardSize.width + 80) * 2))
        let lightStats = try #require(ImageStats.luminance(lightImage))
        let darkStats = try #require(ImageStats.luminance(darkImage))
        #expect(lightStats.standardDeviation >= 4)
        #expect(darkStats.standardDeviation >= 4)
        #expect(lightStats.mean - darkStats.mean >= 40)
    }

    @Test func hoverDarkensTheThumbnailWithTheScrim() throws {
        let resting = try #require(QuickAccessDemo.cards(dark: false).first)
        let hovered = try #require(QuickAccessDemo.cards(dark: false).first)
        hovered.isHovered = true
        let restingImage = try #require(render(resting, dark: false))
        let hoveredImage = try #require(render(hovered, dark: false))
        // The thumbnail's middle: 40 pt card margin + 8 pt padding, centre of the 240 x 147 box.
        let region = CGRect(x: (48 + 60) * 2, y: (48 + 30) * 2, width: 120 * 2, height: 40 * 2)
        let restingMean = try #require(ImageStats.luminance(restingImage, region: region)).mean
        let hoveredMean = try #require(ImageStats.luminance(hoveredImage, region: region)).mean
        #expect(restingMean - hoveredMean >= 20)
    }

    @Test func theDemoSceneRendersAtTwoX() throws {
        let light = try #require(QuickAccessDemo.renderScene(dark: false))
        let dark = try #require(QuickAccessDemo.renderScene(dark: true))
        #expect(light.width == 1200)
        #expect(light.height == 1520)
        let lightStats = try #require(ImageStats.luminance(light))
        let darkStats = try #require(ImageStats.luminance(dark))
        #expect(lightStats.standardDeviation >= 4)
        #expect(lightStats.mean - darkStats.mean >= 40)
        #expect(QuickAccessDemo.cards().count == 3)
    }
}

@MainActor
@Suite struct PermissionHintControllerTests {
    @MainActor
    final class FakeHintSurface: PermissionHintSurface {
        var frames: [CGRect] = []
        var hideCount = 0
        var windowID: WindowID? { 8200 }
        func show(frame: CGRect) { frames.append(frame) }
        func hide() { hideCount += 1 }
    }

    /// The hint stays in the exclusion list through its fade-out and leaves it once ordered out.
    @Test func hintWindowIsExcludedUntilItIsOrderedOut() {
        let clock = FakeClock()
        let surface = FakeHintSurface()
        let controller = PermissionHintController(clock: clock, makeSurface: { _ in surface })
        #expect(controller.surfaceWindowIDs.isEmpty)
        controller.show(near: CGPoint(x: 640, y: 400), visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775))
        #expect(controller.surfaceWindowIDs == [8200])
        clock.advance(by: Theme.HintPanel.visibleSeconds)
        controller.processTimers()
        #expect(!controller.isVisible)
        #expect(controller.surfaceWindowIDs == [8200])
        clock.advance(by: Theme.Motion.hintOut)
        controller.processTimers()
        #expect(controller.surfaceWindowIDs.isEmpty)
    }

    @Test func theHintShowsForSixSecondsThenOrdersOut() {
        let clock = FakeClock()
        let surface = FakeHintSurface()
        var opened = 0
        let controller = PermissionHintController(clock: clock, onOpenSettings: { opened += 1 }) { _ in surface }
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 775)
        controller.show(near: CGPoint(x: 640, y: 400), visibleFrame: visible)
        #expect(controller.isVisible)
        #expect(surface.frames.count == 1)
        clock.advance(by: 5.9)
        controller.processTimers()
        #expect(controller.isVisible)
        clock.advance(by: 0.1)
        controller.processTimers()
        #expect(!controller.isVisible)
        #expect(surface.hideCount == 0)
        clock.advance(by: Theme.Motion.hintOut)
        controller.processTimers()
        #expect(surface.hideCount == 1)

        controller.show(near: CGPoint(x: 640, y: 400), visibleFrame: visible)
        controller.openSettings()
        #expect(opened == 1)
        #expect(!controller.isVisible)
    }

    @Test func aStaleGrantExplainsHowToReAddSnap() {
        let controller = PermissionHintController(clock: FakeClock())
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 775)
        controller.show(near: CGPoint(x: 640, y: 400), visibleFrame: visible)
        #expect(controller.detail == "Turn on Still in Screen & System Audio Recording.")
        controller.show(near: CGPoint(x: 640, y: 400), visibleFrame: visible, reapproval: true)
        #expect(controller.detail?.contains("remove it") == true)
        #expect(controller.detail?.contains("relaunch Still") == true)
    }

    @Test func aMessageChipShowsForFourSecondsAndThePermissionCardClearsIt() {
        let clock = FakeClock()
        let surface = FakeHintSurface()
        let controller = PermissionHintController(clock: clock, makeSurface: { _ in surface })
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 775)
        controller.show(message: "Recording could not start", near: CGPoint(x: 640, y: 400), visibleFrame: visible)
        #expect(controller.isVisible)
        #expect(controller.message == "Recording could not start")
        #expect(surface.frames.count == 1)
        clock.advance(by: 3.9)
        controller.processTimers()
        #expect(controller.isVisible)
        clock.advance(by: 0.1)
        controller.processTimers()
        #expect(!controller.isVisible)
        #expect(controller.message == nil)
        // The permission hint afterwards is the card again, not the old message.
        controller.show(near: CGPoint(x: 640, y: 400), visibleFrame: visible)
        #expect(controller.isVisible)
        #expect(controller.message == nil)
    }

    @Test func thePanelStaysInsideTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 775)
        let margin = PermissionHintController.margin
        let frame = PermissionHintController.panelFrame(pointer: CGPoint(x: 5, y: 5), visibleFrame: visible)
        #expect(frame.minX + margin >= visible.minX)
        #expect(frame.minY + margin >= visible.minY)
        let centred = PermissionHintController.panelFrame(pointer: CGPoint(x: 640, y: 400), visibleFrame: visible)
        #expect(centred.midX == 640)
        #expect(centred.maxY - margin <= 400)
    }

    @Test func theHintViewRendersInBothAppearances() throws {
        let size = CGSize(width: 580, height: 144)
        func image(dark: Bool) -> CGImage? {
            QuickAccessDemo.render(
                ZStack { (dark ? Color.black : Color.white); PermissionHintView() }.frame(width: size.width, height: size.height),
                size: size, dark: dark
            )
        }
        let light = try #require(image(dark: false))
        let dark = try #require(image(dark: true))
        #expect(try #require(ImageStats.luminance(light)).standardDeviation >= 4)
        #expect(try #require(ImageStats.luminance(light)).mean - (try #require(ImageStats.luminance(dark)).mean) >= 40)
    }
}
