import Foundation
import Synchronization

/// A clock that moves only when told to. `sleep` suspends until `advance` passes its deadline,
/// so timer logic (Quick Access auto close, permission hint) is tested without waiting.
public final class FakeClock: Clock {
    /// 2026-10-24 12:00:00 UTC, the default wall time at `now() == 0`.
    public static let defaultStartDate = Date(timeIntervalSince1970: 1_792_843_200)

    private struct Sleeper {
        let id: UInt64
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelled: Set<UInt64> = []
    }

    public let startDate: Date
    private let origin: TimeInterval
    private let state: Mutex<State>

    public init(now: TimeInterval = 0, startDate: Date = FakeClock.defaultStartDate) {
        self.origin = now
        self.startDate = startDate
        self.state = Mutex(State(now: now))
    }

    public func now() -> TimeInterval { state.withLock { $0.now } }

    public func date() -> Date { startDate.addingTimeInterval(now() - origin) }

    /// Number of tasks waiting in `sleep`.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Moves time forward and wakes every sleeper whose deadline has passed, earliest first.
    public func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += max(seconds, 0)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    public func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        guard seconds > 0 else { return }
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case waiting, cancelled }
                let outcome = state.withLock { state -> Outcome in
                    if state.cancelled.remove(id) != nil { return .cancelled }
                    let deadline = state.now + seconds
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .waiting
                }
                switch outcome {
                case .waiting: break
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                // Cancelled before the continuation was registered: leave a mark for it.
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
