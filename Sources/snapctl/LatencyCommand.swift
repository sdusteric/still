import CoreGraphics
import Foundation
import SnapCore
import Synchronization

/// `snapctl latency --fake`: runs CaptureCoordinator with FakeCaptureSource, FakeWindowSource, a
/// recording overlay and a real monotonic clock, then prints p50, p95 and max for each stage and
/// the event order of every run (design 6.6, acceptance AC05). Exits 1 when any run's order is wrong.
enum LatencyCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            guard parsed.flags.contains("--fake") else {
                throw UsageError("latency needs --fake: snapctl never captures the screen")
            }
            let runs = try parsed.int("--runs", default: 50)
            guard runs > 0 else { throw UsageError("--runs must be at least 1") }
            let spec = parsed.options["--display"] ?? "5120x2880@2"
            guard let display = DisplayInfo(spec: spec) else {
                throw UsageError("--display must look like 5120x2880@2")
            }
            let delayMS = try parsed.double("--capture-delay-ms", default: 0)
            let report = try await measure(runs: runs, display: display, captureDelay: delayMS / 1000)
            let summary = LatencyReport(
                mode: CaptureMode.area.rawValue, display: spec, runs: runs, warmupRuns: warmupRuns,
                captureDelayMs: delayMS, expectedOrder: LatencyLog.fullOrder.map(\.rawValue), runDetails: report
            )
            if parsed.json {
                print(try PresetCommand.jsonString(summary))
            } else {
                print(summary.text)
            }
            return summary.orderOK ? 0 : 1
        } catch {
            return exitStatus(for: error)
        }
    }

    /// One untimed run first, so one-time setup (image caches, the PNG encoder) is not counted.
    static let warmupRuns = 1

    @MainActor
    private static func measure(runs: Int, display: DisplayInfo, captureDelay: TimeInterval) async throws -> [RunDetail] {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "snapctl-latency-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: home)
            } catch {
                FileHandle.standardError.write(Data("snapctl: could not remove \(home.path(percentEncoded: false)): \(error)\n".utf8))
            }
        }

        let clock = SystemClock()
        let source = FakeCaptureSource(displays: [display], windows: FakeWindowSource.sample, delay: captureDelay, clock: clock)
        let overlay = LatencyOverlay(selection: selectionRect(on: display), displayID: display.id)
        let results = LatencyResults()
        let stage = CaptureOutputStage(
            history: HistoryStore(paths: SnapPaths(home: home), clock: clock), clipboard: DiscardingClipboard(), clock: clock
        )
        let coordinator = CaptureCoordinator(
            captureSource: source, windowSource: FakeWindowSource(), overlay: overlay, results: results,
            output: stage, clock: clock
        )
        try await coordinator.refreshDisplays()

        var details: [RunDetail] = []
        for index in 0..<(runs + warmupRuns) {
            overlay.reset()
            let trigger = clock.now()
            guard let ticket = await coordinator.run(mode: .area, eventTime: trigger) else {
                throw LatencyError.runFailed(index + 1, results.lastFailure ?? "cancelled")
            }
            guard await ticket.stored.value != nil else {
                throw LatencyError.runFailed(index + 1, results.lastFailure ?? "output stage failed")
            }
            guard index >= warmupRuns else { continue }
            let trace = ticket.result.trace
            let sample = LatencySample(trace: trace)
            details.append(RunDetail(
                run: index + 1 - warmupRuns,
                order: trace.order.map(\.rawValue),
                orderOK: trace.order == LatencyLog.fullOrder,
                presentMs: sample.overlayMS,
                frozenMs: sample.frozenMS,
                cardMs: sample.cardMS
            ))
        }
        return details
    }

    /// The Notes window of the sample desktop, clamped to the display: 842x516 points.
    private static func selectionRect(on display: DisplayInfo) -> CGRect {
        let bounds = display.frameTopLeft
        let width = min(842, bounds.width)
        let height = min(516, bounds.height)
        let x = bounds.minX + min(400, bounds.width - width)
        let y = bounds.minY + min(200, bounds.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum LatencyError: Error, CustomStringConvertible {
        case runFailed(Int, String)

        var description: String {
            switch self {
            case .runFailed(let run, let reason): "latency run \(run) failed: \(reason)"
            }
        }
    }
}

/// Stands in for the overlay panels: the user's mouse-up is simulated right after the frozen
/// image is handed over, since no person selects faster than that.
@MainActor
private final class LatencyOverlay: OverlayPresenter {
    private let area: CGRect
    private let displayID: DisplayID
    private var frozen = false
    private var pending: CheckedContinuation<OverlaySelection, Never>?

    init(selection: CGRect, displayID: DisplayID) {
        self.area = selection
        self.displayID = displayID
    }

    func reset() {
        frozen = false
    }

    func present(mode: CaptureMode, displays: [DisplayInfo]) {}

    func showFrozen(_ image: CapturedImage, displayID: DisplayID) {
        guard displayID == self.displayID else { return }
        frozen = true
        resume(with: .area(displayID: displayID, rect: area))
    }

    func updateWindows(_ windows: [WindowInfo]) {}

    func selection() async -> OverlaySelection {
        if frozen { return .area(displayID: displayID, rect: area) }
        return await withCheckedContinuation { pending = $0 }
    }

    func dismiss() {
        resume(with: .cancelled)
    }

    private func resume(with selection: OverlaySelection) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: selection)
    }
}

@MainActor
private final class LatencyResults: CaptureResultPresenter {
    var lastFailure: String?

    func showCard(for capture: CaptureResult) {}
    func captureStored(_ stored: StoredCapture) {}
    func captureFailed(_ failure: CaptureFailure) { lastFailure = failure.message }
}

/// snapctl never touches the pasteboard; this only counts the write so the event is recorded.
private final class DiscardingClipboard: ClipboardWriting {
    private let writes = Atomic<Int>(0)

    func writeImage(pngData: Data, image: CGImage, scale: Double) throws {
        writes.add(1, ordering: .relaxed)
    }

    func writeFileURL(_ url: URL) throws {
        writes.add(1, ordering: .relaxed)
    }
}

private struct RunDetail: Encodable {
    var run: Int
    var order: [String]
    var orderOK: Bool
    var presentMs: Double?
    var frozenMs: Double?
    var cardMs: Double?
}

private struct StageSummary: Encodable {
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double

    init?(_ values: [Double?]) {
        guard let summary = LatencyLog.summarize(values.compactMap { $0 }) else { return nil }
        p50Ms = LatencyReport.rounded(summary.p50)
        p95Ms = LatencyReport.rounded(summary.p95)
        maxMs = LatencyReport.rounded(summary.max)
    }
}

/// The `--json` output. `stages.present` is trigger to overlay, `stages.frozen` trigger to frozen
/// image ready and `stages.card` confirm to Quick Access card, all in milliseconds.
private struct LatencyReport: Encodable {
    var mode: String
    var display: String
    var runs: Int
    var warmupRuns: Int
    var captureDelayMs: Double
    var expectedOrder: [String]
    var orderOK: Bool
    var stages: [String: StageSummary]
    var runDetails: [RunDetail]

    init(
        mode: String, display: String, runs: Int, warmupRuns: Int, captureDelayMs: Double,
        expectedOrder: [String], runDetails: [RunDetail]
    ) {
        self.mode = mode
        self.display = display
        self.runs = runs
        self.warmupRuns = warmupRuns
        self.captureDelayMs = captureDelayMs
        self.expectedOrder = expectedOrder
        self.orderOK = runDetails.count == runs && runDetails.allSatisfy(\.orderOK)
        var stages: [String: StageSummary] = [:]
        stages["present"] = StageSummary(runDetails.map(\.presentMs))
        stages["frozen"] = StageSummary(runDetails.map(\.frozenMs))
        stages["card"] = StageSummary(runDetails.map(\.cardMs))
        self.stages = stages
        self.runDetails = runDetails.map { detail in
            var copy = detail
            copy.presentMs = detail.presentMs.map(LatencyReport.rounded)
            copy.frozenMs = detail.frozenMs.map(LatencyReport.rounded)
            copy.cardMs = detail.cardMs.map(LatencyReport.rounded)
            return copy
        }
    }

    /// Three decimals, so the JSON stays readable.
    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    var text: String {
        var lines = ["latency mode=\(mode) display=\(display) runs=\(runs) capture_delay_ms=\(captureDelayMs)"]
        for name in ["present", "frozen", "card"] {
            guard let stage = stages[name] else {
                lines.append("\(name): no samples")
                continue
            }
            lines.append("\(name): p50 \(stage.p50Ms) ms, p95 \(stage.p95Ms) ms, max \(stage.maxMs) ms")
        }
        let wrong = runDetails.filter { !$0.orderOK }
        lines.append(wrong.isEmpty
            ? "order: \(expectedOrder.joined(separator: ", ")) in every run"
            : "order wrong in runs \(wrong.map { String($0.run) }.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
