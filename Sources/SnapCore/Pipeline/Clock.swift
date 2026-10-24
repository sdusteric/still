import Foundation

/// Time for the pipeline, latency log and Quick Access timers. Injected so tests drive it with
/// `FakeClock`; the app and `snapbench latency` use `SystemClock`.
///
/// This shadows `Swift.Clock` inside modules that import SnapCore; spell the standard one
/// `Swift.Clock` where both are needed.
public protocol Clock: Sendable {
    /// Monotonic seconds since an arbitrary origin. Only differences are meaningful.
    func now() -> TimeInterval
    /// Wall-clock date, for file names and history.
    func date() -> Date
    /// Suspends for `seconds`; throws `CancellationError` when the task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

/// The real clock: `ContinuousClock` for intervals, `Date()` for wall time.
public struct SystemClock: Clock {
    // Shared by every instance so readings from two SystemClock values compare.
    private static let origin = ContinuousClock.now

    public init() {}

    public func now() -> TimeInterval {
        let elapsed = ContinuousClock.now - SystemClock.origin
        let parts = elapsed.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    public func date() -> Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
