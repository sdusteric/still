import Foundation
import Synchronization

/// A disk with a settable amount of free space. Records every check, so tests can see the 5 s poll.
public final class FakeDiskSpace: DiskSpaceProbe {
    /// 100 GB, plenty for any recording.
    public static let plenty: Int64 = 100 * 1024 * 1024 * 1024

    private struct State {
        var available: Int64
        var checks = 0
        var error: String?
    }

    public struct ProbeError: Error, CustomStringConvertible {
        public let description: String
    }

    private let state: Mutex<State>

    public init(availableBytes: Int64 = FakeDiskSpace.plenty) {
        state = Mutex(State(available: availableBytes))
    }

    public var available: Int64 {
        get { state.withLock { $0.available } }
        set { state.withLock { $0.available = newValue } }
    }

    /// Number of `availableBytes` calls so far.
    public var checkCount: Int { state.withLock { $0.checks } }

    /// Makes the next checks throw, as an unmounted volume would; nil clears it.
    public func setError(_ message: String?) {
        state.withLock { $0.error = message }
    }

    public func availableBytes(at url: URL) throws -> Int64 {
        try state.withLock { state in
            state.checks += 1
            if let message = state.error { throw ProbeError(description: message) }
            return state.available
        }
    }
}
