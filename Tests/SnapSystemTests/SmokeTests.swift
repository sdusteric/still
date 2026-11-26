import SnapCore
@testable import SnapSystem
import Testing

// Live system code is never exercised here: no capture, no permission request, no hotkey.
@Suite struct SnapSystemSmokeTests {
    @Test func moduleLinksTheLiveFrameworks() {
        #expect(SnapSystem.linkedFrameworks.contains("ScreenCaptureKit"))
        #expect(SnapSystem.linkedFrameworks.contains("Carbon"))
    }

    @Test func missingWindowsAreTheExcludedOnesTheListLacks() {
        // A capture refetches the window list only when one of Still's panels is not in it.
        #expect(LiveCaptureSource.missing([7, 8], in: [1, 7, 8]).isEmpty)
        #expect(LiveCaptureSource.missing([7, 9], in: [1, 7, 8]) == [9])
        #expect(LiveCaptureSource.missing([], in: []).isEmpty)
        #expect(LiveCaptureSource.missing([9, 9], in: [1]) == [9], "a duplicate id counts once")
    }

    @Test func theTimingLineSaysWhereAFrozenCaptureSpentItsTime() {
        let line = LiveCaptureSource.timingLine(
            display: 2, content: .cached, contentSeconds: 0.0012, filterSeconds: 0.0008, screenshotSeconds: 0.1403,
            width: 5120, height: 2880
        )
        #expect(line == "capture timing display=2 content=cached content_ms=1.2 filter_ms=0.8 screenshot_ms=140.3 size=5120x2880")
    }

    @Test func sharedTypesAreVisibleThroughSnapCore() {
        let options = CaptureOptions()
        #expect(options.hideDesktopIcons)
        #expect(options.includeWindowShadow)
    }
}
