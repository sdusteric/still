import CoreGraphics
import Foundation
import SnapCore
import SnapUI
import Synchronization

/// `snapbench latency --fake`: runs CaptureCoordinator with FakeCaptureSource, FakeWindowSource,
/// the real OverlayController and QuickAccessController (no panels, a cursor that does nothing)
/// and a real monotonic clock, then prints p50, p95 and max for each stage and the event order of
/// every run (design 6.6, acceptance AC05). Exits 1 when any run's order is wrong.
///
/// `--mode hud` runs the same through the all-in-one HUD (design 20.5, AC-M2-8): the controller
/// in HUD mode with the last area restored, Return pressed once the frozen image is shown. With
/// `--record` the HUD starts in Record mode, Return is pressed at once, and every run must
/// request no frozen capture.
@MainActor
enum LatencyBench {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try BenchArguments(arguments)
            guard parsed.flags.contains("--fake") else {
                throw UsageError("latency needs --fake: snapbench never captures the screen")
            }
            let runs = try parsed.int("--runs", default: 50)
            guard runs > 0 else { throw UsageError("--runs must be at least 1") }
            let spec = parsed.options["--display"] ?? "5120x2880@2"
            guard let display = DisplayInfo(spec: spec) else {
                throw UsageError("--display must look like 5120x2880@2")
            }
            let delayMS = try parsed.double("--capture-delay-ms", default: 0)
            let mode = parsed.options["--mode"] ?? "area"
            let record = parsed.flags.contains("--record")
            let recall = parsed.flags.contains("--recall")
            let summary: LatencyReport
            switch mode {
            case "area":
                guard !record else { throw UsageError("--record needs --mode hud") }
                let report = try await measure(runs: runs, display: display, captureDelay: delayMS / 1000, recall: recall)
                summary = LatencyReport(
                    mode: CaptureMode.area.rawValue, display: spec, runs: runs, warmupRuns: warmupRuns,
                    captureDelayMs: delayMS, expectedOrder: LatencyLog.fullOrder.map(\.rawValue), runDetails: report
                )
            case "hud":
                let stored = selectionRect(on: display)
                let report = try await measureHUD(
                    runs: runs, display: display, captureDelay: delayMS / 1000, record: record, stored: stored
                )
                summary = LatencyReport(
                    mode: "hud", display: spec, runs: runs, warmupRuns: warmupRuns, captureDelayMs: delayMS,
                    expectedOrder: (record ? hudRecordOrder : LatencyLog.fullOrder).map(\.rawValue), runDetails: report,
                    hud: HUDSummary(record: record, storedArea: stored, runDetails: report)
                )
            default:
                throw UsageError("--mode must be area or hud")
            }
            if parsed.flags.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            } else {
                print(summary.text)
            }
            return summary.passed ? 0 : 1
        } catch {
            return exitStatus(for: error)
        }
    }

    /// One untimed run first, so one-time setup (image caches, the PNG encoder) is not counted.
    static let warmupRuns = 1

    /// `recall`: every stored capture goes to a RecallIndexer whose fake OCR takes 300 ms, as in the
    /// app, to show that reading text never delays the card (Recall AC-R4).
    private static func measure(runs: Int, display: DisplayInfo, captureDelay: TimeInterval, recall: Bool = false) async throws -> [RunDetail] {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "snapbench-latency-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: home)
            } catch {
                FileHandle.standardError.write(Data("snapbench: could not remove \(home.path(percentEncoded: false)): \(error)\n".utf8))
            }
        }

        let clock = SystemClock()
        let source = FakeCaptureSource(displays: [display], windows: FakeWindowSource.sample, delay: captureDelay, clock: clock)
        let area = selectionRect(on: display)
        // No surface factory: the controllers keep their full state but never make a window.
        let overlay = OverlayController(
            options: OverlayController.Options(instantCapture: true),
            cursor: InertCursor(),
            pointerLocation: { CGPoint(x: area.minX, y: area.minY) }
        )
        let user = SimulatedUser(overlay: overlay, selection: area, displayID: display.id)
        let quickAccess = QuickAccessController(
            clock: clock,
            visibleFrame: { CGRect(x: 0, y: 0, width: display.frameTopLeft.width, height: display.frameTopLeft.height - 25) },
            optionHeld: { false }
        )
        let results = BenchResults(quickAccess: quickAccess)
        let history = HistoryStore(paths: SnapPaths(home: home), clock: clock)
        if recall {
            let indexer = RecallIndexer(
                history: history, ocr: OCRStore(history: history), recognizer: FakeTextRecognizer(delay: .milliseconds(300)),
                writer: RecallWriter(directory: SnapPaths(home: home).recallDirectory),
                options: RecallOptions(enabled: true, previews: true, excludedApps: []), log: nil
            )
            results.onStored = { stored in Task { await indexer.enqueue(stored.item.id) } }
        }
        let stage = CaptureOutputStage(history: history, clipboard: DiscardingClipboard(), clock: clock)
        let coordinator = CaptureCoordinator(
            captureSource: source, windowSource: FakeWindowSource(), overlay: user, results: results,
            output: stage, clock: clock
        )
        try await coordinator.refreshDisplays()

        var details: [RunDetail] = []
        for index in 0..<(runs + warmupRuns) {
            let trigger = clock.now()
            guard let ticket = await coordinator.run(mode: .area, eventTime: trigger) else {
                throw LatencyError.runFailed(index + 1, results.lastFailure ?? "cancelled")
            }
            guard await ticket.stored.value != nil else {
                throw LatencyError.runFailed(index + 1, results.lastFailure ?? "output stage failed")
            }
            guard results.cardsShown == index + 1, quickAccess.cards.first?.id == results.lastCardID else {
                throw LatencyError.runFailed(index + 1, "the Quick Access controller did not show the card")
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
        quickAccess.closeAll()
        return details
    }

    /// A HUD Record run: the overlay, then Record confirmed. No frozen capture, no card.
    static let hudRecordOrder: [CaptureEvent] = [.present, .confirm]

    private static func measureHUD(
        runs: Int, display: DisplayInfo, captureDelay: TimeInterval, record: Bool, stored: CGRect
    ) async throws -> [RunDetail] {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "snapbench-hud-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: home)
            } catch {
                FileHandle.standardError.write(Data("snapbench: could not remove \(home.path(percentEncoded: false)): \(error)\n".utf8))
            }
        }

        let clock = SystemClock()
        let source = FakeCaptureSource(displays: [display], windows: FakeWindowSource.sample, delay: captureDelay, clock: clock)
        // The pointer rests near the bottom center, where the toolbar opens.
        let pointer = CGPoint(x: display.frameTopLeft.midX, y: display.frameTopLeft.maxY - 40)
        let overlay = OverlayController(
            options: OverlayController.Options(instantCapture: true), cursor: InertCursor(), pointerLocation: { pointer }
        )
        let user = HUDUser(overlay: overlay, displayID: display.id, stored: stored)
        let quickAccess = QuickAccessController(
            clock: clock,
            visibleFrame: { CGRect(x: 0, y: 0, width: display.frameTopLeft.width, height: display.frameTopLeft.height - 25) },
            optionHeld: { false }
        )
        let results = BenchResults(quickAccess: quickAccess)
        let stage = CaptureOutputStage(
            history: HistoryStore(paths: SnapPaths(home: home), clock: clock), clipboard: DiscardingClipboard(), clock: clock
        )
        let coordinator = CaptureCoordinator(
            captureSource: source, windowSource: FakeWindowSource(), overlay: user, results: results,
            output: stage, clock: clock
        )
        try await coordinator.refreshDisplays()
        let last = LastArea(displayID: display.id, displayFrame: display.frameTopLeft, rect: stored)
        let state = AllInOneState(mode: record ? .record : .screenshot, target: .area, lastArea: last, displays: [display])

        var details: [RunDetail] = []
        for index in 0..<(runs + warmupRuns) {
            let capturesBefore = Self.displayCaptures(source)
            let trigger = clock.now()
            let outcome = await coordinator.runHUD(state, eventTime: trigger)
            let trace: CaptureTrace
            switch outcome {
            case .screenshot(let ticket):
                guard !record else { throw LatencyError.runFailed(index + 1, "a Record run ended as a screenshot") }
                guard await ticket.stored.value != nil else {
                    throw LatencyError.runFailed(index + 1, results.lastFailure ?? "output stage failed")
                }
                guard results.cardsShown > 0, quickAccess.cards.first?.id == results.lastCardID else {
                    throw LatencyError.runFailed(index + 1, "the Quick Access controller did not show the card")
                }
                trace = ticket.result.trace
            case .record(let target, let recordTrace):
                guard record else { throw LatencyError.runFailed(index + 1, "a Screenshot run ended as a recording") }
                guard target == .area(stored) else {
                    throw LatencyError.runFailed(index + 1, "the HUD asked to record \(target), not the restored area")
                }
                // The countdown would run here; the bench closes the held overlay instead.
                overlay.dismiss()
                trace = recordTrace
            case .cancelled:
                throw LatencyError.runFailed(index + 1, results.lastFailure ?? "cancelled")
            }
            let frozenRequests = Self.displayCaptures(source) - capturesBefore
            guard index >= warmupRuns else { continue }
            let sample = LatencySample(trace: trace)
            let expected = record ? hudRecordOrder : LatencyLog.fullOrder
            details.append(RunDetail(
                run: index + 1 - warmupRuns,
                order: trace.order.map(\.rawValue),
                orderOK: trace.order == expected,
                presentMs: sample.overlayMS,
                frozenMs: sample.frozenMS,
                cardMs: sample.cardMS,
                confirmMs: trace.millisecondsFromTrigger(to: .confirm),
                restoredArea: user.restoredArea.map(HUDSummary.array),
                restoredMatches: user.restoredArea == stored,
                frozenCapturesRequested: frozenRequests
            ))
        }
        quickAccess.closeAll()
        return details
    }

    private static func displayCaptures(_ source: FakeCaptureSource) -> Int {
        source.recordedCalls.filter { if case .display = $0 { true } else { false } }.count
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

/// The real overlay with a user who drags out the selection the moment the frozen image is
/// shown, since no person selects faster than that. Every presenter call goes to the controller.
@MainActor
private final class SimulatedUser: OverlayPresenter {
    private let overlay: OverlayController
    private let area: CGRect
    private let displayID: DisplayID

    init(overlay: OverlayController, selection: CGRect, displayID: DisplayID) {
        self.overlay = overlay
        self.area = selection
        self.displayID = displayID
    }

    func present(mode: CaptureMode, displays: [DisplayInfo]) {
        overlay.present(mode: mode, displays: displays)
    }

    func presentHUD(_ state: AllInOneState, displays: [DisplayInfo], modeChanged: @escaping @MainActor (HUDMode) -> Void) {
        overlay.presentHUD(state, displays: displays, modeChanged: modeChanged)
    }

    func showFrozen(_ image: CapturedImage, displayID: DisplayID) {
        overlay.showFrozen(image, displayID: displayID)
        guard displayID == self.displayID else { return }
        let start = CGPoint(x: area.minX, y: area.minY)
        let end = CGPoint(x: area.maxX, y: area.maxY)
        overlay.handle(.mouseDown(start, clickCount: 1, modifiers: []))
        overlay.handle(.mouseDragged(CGPoint(x: area.midX, y: area.midY), modifiers: []))
        overlay.handle(.mouseDragged(end, modifiers: []))
        overlay.handle(.mouseUp(end, modifiers: []))
    }

    func updateWindows(_ windows: [WindowInfo]) {
        overlay.updateWindows(windows)
    }

    func selection() async -> OverlaySelection {
        await overlay.selection()
    }

    func dismiss() {
        overlay.dismiss()
    }
}

/// The real overlay in HUD mode with a user who presses Return as soon as the HUD can confirm:
/// once the frozen image is shown in Screenshot mode, at once in Record mode. It notes the area
/// the HUD restored when it appeared.
@MainActor
private final class HUDUser: OverlayPresenter {
    private let overlay: OverlayController
    private let displayID: DisplayID
    private(set) var restoredArea: CGRect?

    init(overlay: OverlayController, displayID: DisplayID, stored: CGRect) {
        self.overlay = overlay
        self.displayID = displayID
    }

    func present(mode: CaptureMode, displays: [DisplayInfo]) {
        overlay.present(mode: mode, displays: displays)
    }

    func presentHUD(_ state: AllInOneState, displays: [DisplayInfo], modeChanged: @escaping @MainActor (HUDMode) -> Void) {
        overlay.presentHUD(state, displays: displays, modeChanged: modeChanged)
        restoredArea = overlay.hud?.area
        if state.mode == .record { pressReturn() }
    }

    func showFrozen(_ image: CapturedImage, displayID: DisplayID) {
        overlay.showFrozen(image, displayID: displayID)
        if displayID == self.displayID { pressReturn() }
    }

    func updateWindows(_ windows: [WindowInfo]) {
        overlay.updateWindows(windows)
    }

    func selection() async -> OverlaySelection {
        await overlay.selection()
    }

    func dismiss() {
        overlay.dismiss()
    }

    private func pressReturn() {
        overlay.handle(.keyDown(.returnKey, modifiers: [], isRepeat: false))
    }
}

/// The cursor stays as it is: snapbench is not the frontmost app and must not change it.
@MainActor
private final class InertCursor: OverlayCursor {
    func hide() {}
    func unhide() {}
}

/// Shows each capture as a Quick Access card, as the app does, before the output stage runs.
@MainActor
private final class BenchResults: CaptureResultPresenter {
    let quickAccess: QuickAccessController
    var lastFailure: String?
    private(set) var cardsShown = 0
    private(set) var lastCardID: String?

    init(quickAccess: QuickAccessController) {
        self.quickAccess = quickAccess
    }

    func showCard(for capture: CaptureResult) {
        cardsShown += 1
        let id = "bench-\(cardsShown)"
        lastCardID = id
        quickAccess.show(QuickAccessItem(
            id: id, thumbnail: capture.image.cgImage, pointSize: capture.image.pointSize, copied: true
        ))
    }

    var onStored: (StoredCapture) -> Void = { _ in }

    func captureStored(_ stored: StoredCapture) { onStored(stored) }
    func captureFailed(_ failure: CaptureFailure) { lastFailure = failure.message }
}

/// snapbench never touches the pasteboard; this only counts the write so the event is recorded.
nonisolated private final class DiscardingClipboard: ClipboardWriting {
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
    /// HUD runs: trigger to confirm, the area the HUD restored, whether it equals the stored
    /// rect exactly, and how many frozen display captures the run requested.
    var confirmMs: Double?
    var restoredArea: [Double]?
    var restoredMatches: Bool?
    var frozenCapturesRequested: Int?
}

/// The HUD checks of AC-M2-8.
private struct HUDSummary: Encodable {
    var record: Bool
    var storedArea: [Double]
    var restoredAreaMatchesEveryRun: Bool
    /// Record runs only: true when no run requested a frozen capture.
    var noFrozenCaptureRequested: Bool?
    var frozenCapturesRequested: Int

    init(record: Bool, storedArea: CGRect, runDetails: [RunDetail]) {
        self.record = record
        self.storedArea = HUDSummary.array(storedArea)
        restoredAreaMatchesEveryRun = !runDetails.isEmpty && runDetails.allSatisfy { $0.restoredMatches == true }
        frozenCapturesRequested = runDetails.reduce(0) { $0 + ($1.frozenCapturesRequested ?? 0) }
        noFrozenCaptureRequested = record ? frozenCapturesRequested == 0 : nil
    }

    var passed: Bool { restoredAreaMatchesEveryRun && noFrozenCaptureRequested != false }

    static func array(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
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
    var hud: HUDSummary?

    init(
        mode: String, display: String, runs: Int, warmupRuns: Int, captureDelayMs: Double,
        expectedOrder: [String], runDetails: [RunDetail], hud: HUDSummary? = nil
    ) {
        self.hud = hud
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
        if hud != nil { stages["confirm"] = StageSummary(runDetails.map(\.confirmMs)) }
        self.stages = stages
        self.runDetails = runDetails.map { detail in
            var copy = detail
            copy.presentMs = detail.presentMs.map(LatencyReport.rounded)
            copy.frozenMs = detail.frozenMs.map(LatencyReport.rounded)
            copy.cardMs = detail.cardMs.map(LatencyReport.rounded)
            copy.confirmMs = detail.confirmMs.map(LatencyReport.rounded)
            return copy
        }
    }

    /// The order held in every run, and the HUD checks when this was a HUD run.
    var passed: Bool { orderOK && (hud?.passed ?? true) }

    /// Three decimals, so the JSON stays readable.
    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    var text: String {
        var lines = ["latency mode=\(mode) display=\(display) runs=\(runs) capture_delay_ms=\(captureDelayMs)"]
        for name in ["present", "frozen", "confirm", "card"] where name != "confirm" || hud != nil {
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
        if let hud {
            lines.append("restored area \(hud.storedArea.map { String($0) }.joined(separator: ",")): "
                + (hud.restoredAreaMatchesEveryRun ? "exact in every run" : "differs in some runs"))
            if hud.record {
                lines.append("frozen captures requested: \(hud.frozenCapturesRequested)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
