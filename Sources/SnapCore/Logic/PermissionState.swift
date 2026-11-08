import Foundation

/// Where the Screen Recording preflight comes from: `CGPreflightScreenCaptureAccess()` in the app
/// (`PermissionProbe.Source`), `FakePermissionSource` in tests. Reading it never prompts.
public protocol ScreenRecordingPermissionSource: Sendable {
    func preflight() -> Bool
}

/// The Screen Recording permission as a pure state machine (design section 13). The preflight
/// check is injected, so the rules are unit tests: `CGRequestScreenCaptureAccess` is requested at
/// most once ever (the date is persisted in `state.json`), a hotkey while denied shows a hint
/// instead of a request, and a capture error such as -3801 marks the permission as unknown.
public struct PermissionState: Sendable {
    /// `SCStreamErrorUserDeclined`: the user declined or has to re-approve ("Continue to Allow").
    public static let userDeclinedErrorCode = -3801

    public enum Status: Sendable, Hashable {
        case granted
        case denied
        /// A capture failed after a grant, so the grant may have lapsed.
        case unknown
    }

    /// What the app does when the capture hotkey is pressed.
    public enum HotkeyOutcome: Sendable, Hashable {
        case capture
        /// Show the small "Screen Recording needs your OK" panel. Never a request.
        case showHint
    }

    /// What the app does when the request button is clicked.
    public enum RequestDecision: Sendable, Hashable {
        /// First time: call `CGRequestScreenCaptureAccess` once, then `recordRequest(at:)`.
        case request
        /// Already asked once: open the Screen Recording pane of System Settings instead.
        case openSystemSettings
        /// Nothing to ask for.
        case alreadyGranted
    }

    public enum CaptureFailureOutcome: Sendable, Hashable {
        /// The permission lapsed or is missing: show the hint panel (once per lapse).
        case showHint
        /// The lapse was already reported; only log it.
        case logOnly
        /// The error is not about permission (stale filter, display change): log it.
        case unrelated
    }

    private let preflight: @Sendable () -> Bool
    public private(set) var requestedAt: Date?
    private var lapsed = false
    private var hintShownForLapse = false
    private var activatedAfterRequestWithoutGrant = false
    private var failedAfterGrant = false
    /// A capture was refused or failed for permission since the last capture that worked.
    private var captureBlocked = false

    /// - Parameters:
    ///   - preflight: `CGPreflightScreenCaptureAccess()` in the app, a closure in tests.
    ///   - requestedAt: the persisted `screenRecordingRequested` date.
    public init(preflight: @escaping @Sendable () -> Bool, requestedAt: Date? = nil) {
        self.preflight = preflight
        self.requestedAt = requestedAt
    }

    public init(source: any ScreenRecordingPermissionSource, requestedAt: Date? = nil) {
        self.init(preflight: { source.preflight() }, requestedAt: requestedAt)
    }

    public var hasRequested: Bool { requestedAt != nil }

    /// The current status. Reads the preflight each time, since it is cheap and never prompts.
    public var status: Status {
        if lapsed { return .unknown }
        return preflight() ? .granted : .denied
    }

    /// The first-run window shows only when permission is missing and was never requested.
    public var needsOnboarding: Bool {
        !lapsed && !preflight() && !hasRequested
    }

    /// The menu shows "Screen Recording needs your OK" for anything but a clean grant.
    public var needsAttention: Bool { status != .granted }

    /// The badge on the menu bar symbol: a capture was refused or failed because permission is
    /// missing or needs re-approval, and it is still not back. Cleared by a capture that works, or
    /// by a preflight that says yes when no lapse is pending.
    public var showsBadge: Bool { captureBlocked && needsAttention }

    /// Permission was asked for before and macOS still says no. After a rebuild with a new
    /// signature, the old entry in System Settings can look on while it no longer counts.
    public var needsReapproval: Bool { hasRequested && status == .denied }

    /// The menu offers "Relaunch Snap" under the status line: macOS applies a new grant only to a
    /// fresh process.
    public var offersRelaunchFromMenu: Bool { needsReapproval || offersRelaunch }

    /// The onboarding window offers "Relaunch Snap": the user came back from System Settings and
    /// the preflight still says no, or a capture failed although the preflight says yes.
    public var offersRelaunch: Bool {
        (activatedAfterRequestWithoutGrant && !preflight()) || failedAfterGrant
    }

    // MARK: Events

    public mutating func hotkeyPressed() -> HotkeyOutcome {
        guard status == .denied else { return .capture }
        captureBlocked = true
        return .showHint
    }

    /// The request button was clicked. At most one `.request` is ever returned: after
    /// `recordRequest(at:)` (or a persisted date) every call returns `.openSystemSettings`.
    public func requestDecision() -> RequestDecision {
        if status == .granted { return .alreadyGranted }
        return hasRequested ? .openSystemSettings : .request
    }

    /// Call right after `CGRequestScreenCaptureAccess`. Keeps the first date.
    public mutating func recordRequest(at date: Date) {
        if requestedAt == nil { requestedAt = date }
    }

    /// The app became active again, or Snap's settings or menu opened: re-check the preflight.
    public mutating func appDidActivate() {
        if hasRequested && !preflight() {
            activatedAfterRequestWithoutGrant = true
        }
        if preflight() {
            activatedAfterRequestWithoutGrant = false
            if !lapsed { captureBlocked = false }
        }
    }

    /// A capture failed with `errorCode` (the `NSError` code of the ScreenCaptureKit error).
    public mutating func captureFailed(errorCode: Int?) -> CaptureFailureOutcome {
        let granted = preflight()
        if errorCode == PermissionState.userDeclinedErrorCode {
            lapsed = true
            captureBlocked = true
            if granted { failedAfterGrant = true }
            return reportLapse()
        }
        // Permission is missing outright: the status is already .denied, so the hotkey shows the hint.
        if granted { return .unrelated }
        captureBlocked = true
        return .showHint
    }

    /// A capture worked: any lapse is over.
    public mutating func captureSucceeded() {
        lapsed = false
        hintShownForLapse = false
        failedAfterGrant = false
        captureBlocked = false
    }

    private mutating func reportLapse() -> CaptureFailureOutcome {
        if hintShownForLapse { return .logOnly }
        hintShownForLapse = true
        return .showHint
    }
}
