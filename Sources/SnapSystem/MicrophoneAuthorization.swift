import AVFoundation
import Foundation
import SnapCore
import Synchronization

/// `AVCaptureDevice` audio authorization with no gate. Only `MicrophoneAuthorization` uses it;
/// compiled and linted, but never called by a test, tool or agent.
public struct SystemMicrophoneAuthorizer: MicrophoneAuthorizing {
    public init() {}

    public func status() -> MicrophoneAccess {
        MicrophoneAuthorization.access(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Microphone access as the app sees it (design 20.7, D65). `status()` is the probe and never
/// prompts. `requestAccess()` shows the system prompt at most once per install: only while the
/// status is not determined and `state.json` has no `microphoneRequested` date, and the date is
/// written before the prompt. The caller is a user action that turns the microphone on (the
/// Settings switch or the HUD Options menu), never launch and never a recording start.
public final class MicrophoneAuthorization: MicrophoneAuthorizing {
    /// Privacy & Security > Microphone, for the Settings warning row.
    public static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    private let underlying: any MicrophoneAuthorizing
    private let stateStore: StateStore
    private let now: @Sendable () -> Date
    private let log: Log?
    /// Set by the first request in this process, so two quick clicks cannot both prompt even if
    /// writing `state.json` failed.
    private let requestedInProcess = Mutex(false)

    /// - Parameter underlying: the live `AVCaptureDevice` calls; tests pass a fake.
    public init(
        stateStore: StateStore,
        underlying: any MicrophoneAuthorizing = SystemMicrophoneAuthorizer(),
        now: @escaping @Sendable () -> Date = { Date() },
        log: Log? = nil
    ) {
        self.stateStore = stateStore
        self.underlying = underlying
        self.now = now
        self.log = log
    }

    public func status() -> MicrophoneAccess {
        underlying.status()
    }

    /// Returns whether access is granted now. Without a prompt it answers from the current status.
    public func requestAccess() async -> Bool {
        let current = underlying.status()
        guard MicrophoneAuthorization.shouldRequest(
            status: current, requestedAt: stateStore.state.microphoneRequested
        ) else { return current.isAuthorized }
        let claimed = requestedInProcess.withLock { requested -> Bool in
            if requested { return false }
            requested = true
            return true
        }
        guard claimed else { return current.isAuthorized }
        do {
            let date = now()
            try stateStore.update { $0.microphoneRequested = date }
        } catch {
            log?.warning("microphone: cannot record the access request in state.json: \(error)")
        }
        log?.info("microphone: requesting access")
        let granted = await underlying.requestAccess()
        log?.info("microphone: access \(granted ? "granted" : "not granted")")
        return granted
    }

    /// The gate of D65: ask only when the system has no answer yet and Snap never asked before.
    public static func shouldRequest(status: MicrophoneAccess, requestedAt: Date?) -> Bool {
        status == .notDetermined && requestedAt == nil
    }

    /// Maps `AVAuthorizationStatus`; an unknown future value counts as restricted.
    public static func access(for status: AVAuthorizationStatus) -> MicrophoneAccess {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}
