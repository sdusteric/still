import Foundation
import Synchronization

/// A Screen Recording preflight that answers what the test says and counts how often it was read.
/// It never calls `CGPreflightScreenCaptureAccess`, and nothing can make it request access.
public final class FakePermissionSource: ScreenRecordingPermissionSource {
    private struct State {
        var granted: Bool
        var reads = 0
    }

    private let state: Mutex<State>

    public init(granted: Bool) {
        state = Mutex(State(granted: granted))
    }

    public var granted: Bool {
        get { state.withLock { $0.granted } }
        set { state.withLock { $0.granted = newValue } }
    }

    /// Times `preflight()` was read.
    public var reads: Int { state.withLock { $0.reads } }

    public func preflight() -> Bool {
        state.withLock { state in
            state.reads += 1
            return state.granted
        }
    }
}
