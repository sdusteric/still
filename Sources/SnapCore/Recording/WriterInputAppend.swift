import Foundation

/// Appends to a non-real-time `AVAssetWriter` input without the receivers' async `append`, which
/// was seen to wait forever under load with the input idle (a video-only fake recording of 15
/// frames hung in 1 run of 40). `appendImmediately` returns false while the input is not ready,
/// so this retries it every millisecond until it takes the sample.
package enum WriterInputAppend {
    package enum Outcome: Sendable, Hashable {
        case appended
        /// `giveUp` returned true before the input took the sample.
        case gaveUp
    }

    struct TimedOut: Error, Sendable, Hashable, CustomStringConvertible {
        let seconds: Double
        var description: String { "the writer input took no data for \(Int(seconds)) s" }
    }

    static let retryNanoseconds: UInt64 = 1_000_000
    /// A stalled writer fails the recording instead of hanging it.
    static let timeoutSeconds: Double = 30

    /// Calls `attempt` until it returns true. Throws what `attempt` throws, or `TimedOut`.
    static func untilAccepted(
        giveUp: () -> Bool = { false },
        _ attempt: () throws -> Bool
    ) async throws -> Outcome {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
        while true {
            if try attempt() { return .appended }
            if giveUp() { return .gaveUp }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw TimedOut(seconds: timeoutSeconds) }
            try await Task.sleep(nanoseconds: retryNanoseconds)
        }
    }
}
