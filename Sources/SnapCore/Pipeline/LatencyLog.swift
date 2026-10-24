import Foundation
import Synchronization

/// One step of a capture, in the order the hotkey path must produce them (design 6.6).
public enum CaptureEvent: String, Sendable, Hashable, Codable, CaseIterable {
    /// Overlay panels ordered front (not used for fullscreen, which has no overlay).
    case present
    /// Every display's frozen image is ready and handed to its panel.
    case frozen
    /// The coordinator received the selection (mouse-up or click).
    case confirm
    /// The Quick Access card was asked to show.
    case card
    /// PNG encoding finished on the background stage.
    case encode
    /// The capture is in `SNAP_HOME/history`.
    case history
    /// The pasteboard holds the image.
    case clipboard
    /// The optional "Save to folder" copy was written.
    case save
}

/// One recorded event and its time on the coordinator's clock.
public struct CaptureEventRecord: Sendable, Hashable {
    public var event: CaptureEvent
    public var time: TimeInterval

    public init(event: CaptureEvent, time: TimeInterval) {
        self.event = event
        self.time = time
    }
}

/// The ordered event log of one capture. The hotkey path and the background output stage both
/// append to it, so it is locked.
public final class CaptureTrace: Sendable {
    public let mode: CaptureMode
    /// The hotkey event time (or the moment `begin` ran), on the coordinator's clock.
    public let triggerTime: TimeInterval
    private let records: Mutex<[CaptureEventRecord]>

    public init(mode: CaptureMode, triggerTime: TimeInterval) {
        self.mode = mode
        self.triggerTime = triggerTime
        self.records = Mutex([])
    }

    public func record(_ event: CaptureEvent, at time: TimeInterval) {
        records.withLock { $0.append(CaptureEventRecord(event: event, time: time)) }
    }

    public var events: [CaptureEventRecord] { records.withLock { $0 } }

    public var order: [CaptureEvent] { events.map(\.event) }

    /// The first time `event` was recorded.
    public func time(of event: CaptureEvent) -> TimeInterval? {
        events.first { $0.event == event }?.time
    }

    /// Milliseconds from the trigger to `event`.
    public func millisecondsFromTrigger(to event: CaptureEvent) -> Double? {
        time(of: event).map { ($0 - triggerTime) * 1000 }
    }

    /// Milliseconds between two recorded events.
    public func milliseconds(from start: CaptureEvent, to end: CaptureEvent) -> Double? {
        guard let first = time(of: start), let last = time(of: end) else { return nil }
        return (last - first) * 1000
    }
}

/// The three numbers the app logs per capture and `snapbench latency` summarizes.
public struct LatencySample: Sendable, Hashable, Codable {
    /// Trigger to overlay presented.
    public var overlayMS: Double?
    /// Trigger to every frozen image ready.
    public var frozenMS: Double?
    /// Confirm to Quick Access card.
    public var cardMS: Double?

    public init(overlayMS: Double?, frozenMS: Double?, cardMS: Double?) {
        self.overlayMS = overlayMS
        self.frozenMS = frozenMS
        self.cardMS = cardMS
    }

    public init(trace: CaptureTrace) {
        self.init(
            overlayMS: trace.millisecondsFromTrigger(to: .present),
            frozenMS: trace.millisecondsFromTrigger(to: .frozen),
            cardMS: trace.milliseconds(from: .confirm, to: .card)
        )
    }
}

/// p50, p95 and max of one stage, in milliseconds.
public struct LatencySummary: Sendable, Hashable, Codable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var max: Double

    public init(count: Int, p50: Double, p95: Double, max: Double) {
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.max = max
    }
}

/// Formats and checks latency (design 6.6): the `latency mode=.. overlay_ms=.. frozen_ms=..
/// card_ms=..` line in `SNAP_HOME/logs/snap.log`, percentiles and the event order rule.
public enum LatencyLog {
    /// The order every capture follows. Events that did not happen (no overlay for fullscreen,
    /// clipboard off) are left out, but the rest never change places.
    public static let canonicalOrder: [CaptureEvent] = CaptureEvent.allCases

    /// The full area or window order with the clipboard on and no save, which `snapbench latency`
    /// requires of every run.
    public static let fullOrder: [CaptureEvent] = [.present, .frozen, .confirm, .card, .encode, .history, .clipboard]

    /// One log line, for example `latency mode=area overlay_ms=3.1 frozen_ms=9.8 card_ms=1.2`.
    /// A stage that did not happen prints `-`.
    public static func line(for trace: CaptureTrace) -> String {
        line(mode: trace.mode, sample: LatencySample(trace: trace))
    }

    public static func line(mode: CaptureMode, sample: LatencySample) -> String {
        "latency mode=\(mode.rawValue) overlay_ms=\(format(sample.overlayMS)) "
            + "frozen_ms=\(format(sample.frozenMS)) card_ms=\(format(sample.cardMS))"
    }

    /// Milliseconds with one decimal, `-` for nil.
    public static func format(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite else { return "-" }
        return String(format: "%.1f", milliseconds)
    }

    /// True when `order` follows `canonicalOrder` with each event at most once, so the card is
    /// always before encoding and history is always before the clipboard.
    public static func followsCanonicalOrder(_ order: [CaptureEvent]) -> Bool {
        var lastIndex = -1
        for event in order {
            guard let index = canonicalOrder.firstIndex(of: event), index > lastIndex else { return false }
            lastIndex = index
        }
        return true
    }

    /// Nearest-rank percentile (`fraction` 0.5 for p50, 0.95 for p95) of `values`; nil when empty.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    public static func summarize(_ values: [Double]) -> LatencySummary? {
        guard let p50 = percentile(values, 0.5), let p95 = percentile(values, 0.95), let max = values.max() else {
            return nil
        }
        return LatencySummary(count: values.count, p50: p50, p95: p95, max: max)
    }
}
