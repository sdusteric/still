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

    @Test func sharedTypesAreVisibleThroughSnapCore() {
        let options = CaptureOptions()
        #expect(options.hideDesktopIcons)
        #expect(options.includeWindowShadow)
    }
}
