import SnapCore
import SnapSystem
import Testing

// Live system code is never exercised here: no capture, no permission request, no hotkey.
@Suite struct SnapSystemSmokeTests {
    @Test func moduleLinksTheLiveFrameworks() {
        #expect(SnapSystem.linkedFrameworks.contains("ScreenCaptureKit"))
        #expect(SnapSystem.linkedFrameworks.contains("Carbon"))
    }

    @Test func sharedTypesAreVisibleThroughSnapCore() {
        let options = CaptureOptions()
        #expect(options.hideDesktopIcons)
        #expect(options.includeWindowShadow)
    }
}
