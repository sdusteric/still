import Foundation
import SnapCore
import Testing

@Suite struct QuickAccessStackTests {
    typealias Stack = QuickAccessStack

    private func makeStack(
        _ configuration: Stack.Configuration = .init(), clock: FakeClock = FakeClock()
    ) -> (stack: Stack, clock: FakeClock) {
        (Stack(clock: clock, configuration: configuration), clock)
    }

    @Test func newestCardComesFirst() {
        var (stack, _) = makeStack()
        stack.push(id: "a", height: 100)
        stack.push(id: "b", height: 100)
        stack.push(id: "c", height: 100)
        #expect(stack.ids == ["c", "b", "a"])
    }

    @Test func aSixthCardEvictsTheOldest() {
        var (stack, _) = makeStack()
        for id in ["a", "b", "c", "d", "e"] {
            #expect(stack.push(id: id, height: 100).isEmpty)
        }
        let closed = stack.push(id: "f", height: 100)
        #expect(closed == [Stack.Closure(id: "a", reason: .overflow)])
        #expect(stack.ids == ["f", "e", "d", "c", "b"])
        #expect(stack.count == 5)
    }

    @Test func stackHeightCapClosesOldestCardsFirst() {
        var (stack, _) = makeStack(.init(maxStackHeight: 500))
        stack.push(id: "a", height: 200)
        stack.push(id: "b", height: 200)
        // 200 + 8 + 200 = 408 fits; a third card makes 624.
        let closed = stack.push(id: "c", height: 200)
        #expect(closed == [Stack.Closure(id: "a", reason: .tooTall)])
        #expect(stack.ids == ["c", "b"])
        #expect(stack.stackHeight == 408)
    }

    @Test func aSingleCardTallerThanTheLimitStays() {
        var (stack, _) = makeStack(.init(maxStackHeight: 100))
        stack.push(id: "a", height: 300)
        #expect(stack.ids == ["a"])
    }

    @Test func cardClosesAfterFifteenSeconds() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        clock.advance(by: 14.9)
        #expect(stack.expire().isEmpty)
        clock.advance(by: 0.2)
        #expect(stack.expire() == [Stack.Closure(id: "a", reason: .autoClose)])
        #expect(stack.count == 0)
    }

    @Test func eachCardHasItsOwnTimer() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        clock.advance(by: 10)
        stack.push(id: "b", height: 100)
        clock.advance(by: 5)
        #expect(stack.expire().map(\.id) == ["a"])
        #expect(stack.ids == ["b"])
        #expect(stack.nextExpiry == 10)
    }

    @Test func hoverPausesTheTimer() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        stack.setHovered(true, for: "a")
        clock.advance(by: 120)
        #expect(stack.expire().isEmpty)
        #expect(stack.secondsRemaining(for: "a") == nil)
        #expect(stack.nextExpiry == nil)
    }

    @Test func leavingRestartsTheFullInterval() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        clock.advance(by: 12)
        stack.setHovered(true, for: "a")
        clock.advance(by: 30)
        stack.setHovered(false, for: "a")
        #expect(stack.secondsRemaining(for: "a") == 15)
        clock.advance(by: 14)
        #expect(stack.expire().isEmpty)
        clock.advance(by: 1)
        #expect(stack.expire().map(\.id) == ["a"])
    }

    @Test func dragPausesTheTimerAndACancelledDragRestartsIt() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        clock.advance(by: 5)
        stack.dragBegan("a")
        clock.advance(by: 60)
        #expect(stack.expire().isEmpty)
        #expect(stack.dragEnded("a", dropAccepted: false) == nil)
        #expect(stack.contains("a"))
        #expect(stack.secondsRemaining(for: "a") == 15)
    }

    @Test func pointerStillOverTheCardKeepsItPausedAfterTheDrag() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        stack.setHovered(true, for: "a")
        stack.dragBegan("a")
        stack.dragEnded("a", dropAccepted: false)
        clock.advance(by: 60)
        #expect(stack.expire().isEmpty)
    }

    @Test func successfulDragOutClosesTheCard() {
        var (stack, _) = makeStack()
        stack.push(id: "a", height: 100)
        stack.push(id: "b", height: 100)
        stack.dragBegan("a")
        #expect(stack.dragEnded("a", dropAccepted: true) == Stack.Closure(id: "a", reason: .draggedOut))
        #expect(stack.ids == ["b"])
    }

    @Test func dragOutKeepsTheCardWhenTheSettingIsOff() {
        var (stack, _) = makeStack(.init(closeAfterDragOut: false))
        stack.push(id: "a", height: 100)
        stack.dragBegan("a")
        #expect(stack.dragEnded("a", dropAccepted: true) == nil)
        #expect(stack.contains("a"))
    }

    @Test func copyAndSaveCloseTheCardOnlyWhenTheSettingIsOn() {
        var (on, _) = makeStack()
        on.push(id: "a", height: 100)
        #expect(on.closesAfter(.copy))
        #expect(on.actionSucceeded(.save, on: "a") == Stack.Closure(id: "a", reason: .saved))

        var (off, _) = makeStack(.init(closeAfterCopyOrSave: false))
        off.push(id: "a", height: 100)
        #expect(off.closesAfter(.copy) == false)
        #expect(off.actionSucceeded(.copy, on: "a") == nil)
        #expect(off.contains("a"))
    }

    @Test func autoCloseOffNeverExpires() {
        var (stack, clock) = makeStack(.init(autoClose: false))
        stack.push(id: "a", height: 100)
        clock.advance(by: 3600)
        #expect(stack.expire().isEmpty)
        #expect(stack.nextExpiry == nil)
    }

    @Test func intervalFollowsTheSettings() {
        let settings = QuickAccessSettings(autoCloseSeconds: 30)
        var (stack, clock) = makeStack(.init(settings: settings))
        stack.push(id: "a", height: 100)
        clock.advance(by: 29)
        #expect(stack.expire().isEmpty)
        clock.advance(by: 1)
        #expect(stack.expire().count == 1)
    }

    @Test func countdownShowsOnlyInTheLastFiveSecondsAndNotWhileHovered() {
        var (stack, clock) = makeStack()
        stack.push(id: "a", height: 100)
        clock.advance(by: 9)
        #expect(stack.showsCountdown(for: "a") == false)
        clock.advance(by: 1)
        #expect(stack.showsCountdown(for: "a"))
        stack.setHovered(true, for: "a")
        #expect(stack.showsCountdown(for: "a") == false)
    }

    @Test func closeRemovesAndReportsOnlyKnownCards() {
        var (stack, _) = makeStack()
        stack.push(id: "a", height: 100)
        #expect(stack.close("zzz") == nil)
        #expect(stack.close("a") == Stack.Closure(id: "a", reason: .dismissed))
        #expect(stack.count == 0)
    }

    @Test func pushingAnExistingIdMovesItToTheFront() {
        var (stack, _) = makeStack()
        stack.push(id: "a", height: 100)
        stack.push(id: "b", height: 100)
        stack.push(id: "a", height: 120)
        #expect(stack.ids == ["a", "b"])
    }

    @Test func applyingSettingsStartsAndClearsTimers() {
        var (stack, clock) = makeStack(.init(autoClose: false))
        stack.push(id: "a", height: 100)
        stack.push(id: "b", height: 100)
        stack.setHovered(true, for: "b")
        stack.apply(.init(autoClose: true, autoCloseSeconds: 20))
        #expect(stack.secondsRemaining(for: "a") == 20)
        #expect(stack.secondsRemaining(for: "b") == nil)
        clock.advance(by: 20)
        #expect(stack.expire().map(\.id) == ["a"])
    }

    @Test func reapplyingTheSameSettingsKeepsRunningTimers() {
        var (stack, clock) = makeStack(.init(autoClose: true, autoCloseSeconds: 15))
        stack.push(id: "a", height: 100)
        clock.advance(by: 10)
        stack.push(id: "b", height: 100)
        // An unrelated settings change (the key hints switching off) reapplies the same values.
        stack.apply(.init(autoClose: true, autoCloseSeconds: 15))
        #expect(stack.secondsRemaining(for: "a") == 5)
        #expect(stack.secondsRemaining(for: "b") == 15)
        clock.advance(by: 5)
        #expect(stack.expire().map(\.id) == ["a"])
    }

    @Test func turningAutoCloseOnOnlyStartsCardsWithoutATimer() {
        var (stack, clock) = makeStack(.init(autoClose: true, autoCloseSeconds: 15))
        stack.push(id: "a", height: 100)
        clock.advance(by: 4)
        stack.apply(.init(autoClose: false, autoCloseSeconds: 15))
        #expect(stack.secondsRemaining(for: "a") == nil)
        clock.advance(by: 30)
        #expect(stack.expire().isEmpty)
        stack.apply(.init(autoClose: true, autoCloseSeconds: 15))
        #expect(stack.secondsRemaining(for: "a") == 15)
        clock.advance(by: 3)
        stack.apply(.init(autoClose: true, autoCloseSeconds: 15))
        #expect(stack.secondsRemaining(for: "a") == 12)
    }

    @Test func aNewIntervalKeepsTheTimeAlreadyUsed() {
        var (stack, clock) = makeStack(.init(autoClose: true, autoCloseSeconds: 15))
        stack.push(id: "a", height: 100)
        clock.advance(by: 5)
        stack.apply(.init(autoClose: true, autoCloseSeconds: 30))
        #expect(stack.secondsRemaining(for: "a") == 25)
    }

    @Test func settingTheHeightCanTriggerTheHeightLimit() {
        var (stack, _) = makeStack(.init(maxStackHeight: 400))
        stack.push(id: "a", height: 150)
        stack.push(id: "b", height: 150)
        let closed = stack.setHeight(300, for: "b")
        #expect(closed == [Stack.Closure(id: "a", reason: .tooTall)])
    }

    // MARK: Card kind (design 20.6)

    @Test func cardsRememberTheirKind() {
        var (stack, _) = makeStack()
        stack.push(id: "shot", height: 163)
        stack.push(id: "movie", height: 166, kind: .video)
        #expect(stack.kind(of: "shot") == .screenshot)
        #expect(stack.kind(of: "movie") == .video)
        #expect(stack.kind(of: "gone") == nil)
    }

    @Test func videoCardsOfferOpenAndFileCopyButNotEditsOrPin() {
        let video = Stack.CardKind.video
        #expect(video.canOpen && video.copiesFileURL)
        #expect(!video.canEdit && !video.canPin)
        let shot = Stack.CardKind.screenshot
        #expect(shot.canEdit && shot.canPin)
        #expect(!shot.canOpen && !shot.copiesFileURL)
    }

    @Test func pinningClosesAScreenshotCardButNotAVideoCard() {
        var (stack, _) = makeStack()
        stack.push(id: "shot", height: 163)
        stack.push(id: "movie", height: 166, kind: .video)
        #expect(stack.pinned("movie") == nil)
        #expect(stack.pinned("shot") == Stack.Closure(id: "shot", reason: .pinned))
        #expect(stack.ids == ["movie"])
    }

    @Test func videoCardsStackAndExpireLikeScreenshots() {
        var (stack, clock) = makeStack()
        stack.push(id: "movie", height: 166, kind: .video)
        clock.advance(by: 15)
        #expect(stack.expire() == [Stack.Closure(id: "movie", reason: .autoClose)])
    }
}
