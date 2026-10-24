import CoreGraphics
import Foundation

/// The Screen Recording permission calls (design section 13). `preflight()` never prompts and is
/// safe at launch and whenever the menu or settings open. `requestOnce()` shows the system dialog:
/// only the onboarding button calls it, after `PermissionState.requestDecision()` returned
/// `.request`, and never from a test, tool or the hotkey path.
public enum PermissionProbe {
    /// The Screen Recording pane of System Settings, for the onboarding window and the hint panel.
    public static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    /// `CGPreflightScreenCaptureAccess()`: true when Snap may capture. Never prompts.
    public static func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The closure `PermissionState` takes.
    public static let preflightCheck: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }

    /// `CGRequestScreenCaptureAccess()`: shows the system prompt the first time. The caller records
    /// the date in `state.json` right after, so it is never called again.
    @discardableResult
    public static func requestOnce() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
