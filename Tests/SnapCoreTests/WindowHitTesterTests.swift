import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct WindowHitTesterTests {
    let tester = WindowHitTester(ownPID: FakeWindowSource.snapPID)
    let sample = FakeWindowSource.sample

    private func window(
        _ id: WindowID, pid: Int32 = 10, frame: CGRect, layer: Int = 0, alpha: Double = 1, order: Int
    ) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, frame: frame, layer: layer, alpha: alpha, order: order)
    }

    @Test func topmostWindowContainingThePointWins() {
        // Notes (202) is in front of Safari (203) where they overlap.
        #expect(tester.window(at: CGPoint(x: 500, y: 300), in: sample)?.id == 202)
        #expect(tester.window(at: CGPoint(x: 1500, y: 900), in: sample)?.id == 203)
    }

    @Test func listOrderDecidesNotArrayPosition() {
        let back = window(1, frame: CGRect(x: 0, y: 0, width: 500, height: 500), order: 5)
        let front = window(2, frame: CGRect(x: 0, y: 0, width: 500, height: 500), order: 1)
        #expect(tester.window(at: CGPoint(x: 10, y: 10), in: [back, front])?.id == 2)
        #expect(tester.window(at: CGPoint(x: 10, y: 10), in: [front, back])?.id == 2)
    }

    @Test func alphaZeroHelperWindowsAreSkipped() {
        // The sample has a full-screen alpha-0 Finder window in front of Notes and Safari.
        let hit = tester.window(at: CGPoint(x: 500, y: 300), in: sample)
        #expect(hit?.ownerName == "Notes")
        let helper = window(1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), alpha: 0, order: 0)
        #expect(tester.window(at: CGPoint(x: 10, y: 10), in: [helper]) == nil)
    }

    @Test func windowsBelowTheMinimumSizeAreSkipped() {
        // "Clock Mini" is 30x30.
        #expect(tester.window(at: CGPoint(x: 2010, y: 310), in: sample) == nil)
        let narrow = window(1, frame: CGRect(x: 0, y: 0, width: 39.5, height: 200), order: 0)
        let short = window(2, frame: CGRect(x: 0, y: 0, width: 200, height: 39.5), order: 0)
        let exact = window(3, frame: CGRect(x: 0, y: 0, width: 40, height: 40), order: 0)
        #expect(tester.isSelectable(narrow) == false)
        #expect(tester.isSelectable(short) == false)
        #expect(tester.isSelectable(exact))
    }

    @Test func ownWindowsAreSkippedEvenInFront() {
        let own = window(1, pid: FakeWindowSource.snapPID, frame: CGRect(x: 0, y: 0, width: 900, height: 900), order: 0)
        let other = window(2, frame: CGRect(x: 0, y: 0, width: 900, height: 900), order: 1)
        #expect(tester.window(at: CGPoint(x: 50, y: 50), in: [own, other])?.id == 2)
        #expect(tester.window(at: CGPoint(x: 50, y: 50), in: [own]) == nil)
    }

    @Test func menuBarAndDockCanBeSelected() {
        // The menu bar is 24 points tall, so the 40 point rule does not apply to it.
        #expect(tester.window(at: CGPoint(x: 100, y: 10), in: sample)?.id == 101)
        // A Dock window that is only the strip, as before macOS 27.
        let dock = window(1, frame: CGRect(x: 760, y: 1360, width: 1040, height: 80), layer: WindowLayer.dock, order: 0)
        let behind = window(2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), order: 1)
        #expect(tester.window(at: CGPoint(x: 1000, y: 1400), in: [dock, behind])?.id == 1)
    }

    @Test func aDockWindowCoveringTheDisplayDoesNotHideTheWindowsBehindIt() {
        // macOS 27: the Dock's window is the whole display and comes before every app window.
        #expect(tester.window(at: CGPoint(x: 300, y: 150), in: sample)?.ownerName == "Safari")
        #expect(tester.window(at: CGPoint(x: 500, y: 300), in: sample)?.ownerName == "Notes")
        #expect(tester.window(at: CGPoint(x: 2500, y: 700), in: sample) == nil)
    }

    @Test func otherLayersAreNotSelectable() {
        // Status items (layer 25), Finder's desktop icons and the wallpaper never match.
        #expect(tester.window(at: CGPoint(x: 2400, y: 10), in: sample)?.id == 101)
        #expect(tester.window(at: CGPoint(x: 2500, y: 700), in: sample) == nil)
        let overlay = window(1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 1000, order: 0)
        let floating = window(2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 3, order: 1)
        #expect(tester.window(at: CGPoint(x: 10, y: 10), in: [overlay, floating]) == nil)
    }

    @Test func pointOnTheRightOrBottomEdgeIsOutside() {
        let one = window(1, frame: CGRect(x: 100, y: 100, width: 200, height: 100), order: 0)
        #expect(tester.window(at: CGPoint(x: 100, y: 100), in: [one])?.id == 1)
        #expect(tester.window(at: CGPoint(x: 300, y: 150), in: [one]) == nil)
        #expect(tester.window(at: CGPoint(x: 150, y: 200), in: [one]) == nil)
    }

    @Test func windowsOnASecondDisplayAreHitInGlobalPoints() {
        let onSecond = window(7, frame: CGRect(x: 2800, y: 100, width: 600, height: 400), order: 0)
        let onFirst = window(8, frame: CGRect(x: 100, y: 100, width: 600, height: 400), order: 1)
        let list = [onSecond, onFirst]
        #expect(tester.window(at: CGPoint(x: 3000, y: 300), in: list)?.id == 7)
        #expect(tester.window(at: CGPoint(x: 300, y: 300), in: list)?.id == 8)
        #expect(tester.window(at: CGPoint(x: 2000, y: 300), in: list) == nil)
    }

    @Test func candidatesAreListedFrontToBack() {
        let ids = tester.candidates(in: sample).map(\.id)
        // The sample's Dock (103) covers the display, as on macOS 27, so it is not a candidate.
        #expect(ids == [101, 202, 203])
    }
}
