import Foundation
import Synchronization

/// Microphone access for tests: a fixed status, and a count of requests so tests can prove a
/// recording start never asks (design 20.7). Never touches a device.
public final class FakeMicrophoneAuthorization: MicrophoneAuthorizing {
    private struct State {
        var status: MicrophoneAccess
        var requests = 0
        var grantsOnRequest: Bool
    }

    private let state: Mutex<State>

    /// - Parameter grantsOnRequest: what a request answers while the status is not determined.
    public init(status: MicrophoneAccess = .authorized, grantsOnRequest: Bool = true) {
        state = Mutex(State(status: status, grantsOnRequest: grantsOnRequest))
    }

    public var currentStatus: MicrophoneAccess {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    /// Number of `requestAccess` calls so far.
    public var requestCount: Int { state.withLock { $0.requests } }

    public func status() -> MicrophoneAccess { state.withLock { $0.status } }

    public func requestAccess() async -> Bool {
        state.withLock { state in
            state.requests += 1
            if state.status == .notDetermined {
                state.status = state.grantsOnRequest ? .authorized : .denied
            }
            return state.status == .authorized
        }
    }
}
