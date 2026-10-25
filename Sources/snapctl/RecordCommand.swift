import CoreGraphics
import Foundation
import SnapCore

/// `snapctl record --fake` (design 20.14): runs the real `RecordingController` with
/// `FakeRecordingSource` (synthetic frames written by `AVAssetWriter`, no screen, no audio
/// device), `FakeDiskSpace`, `FakeMicrophoneAuthorization` and a `FakeClock` into
/// `SNAP_HOME/history`. Prints item.json, the file, its probe, the poster, the event log and the
/// p50 and p95 wall times of confirm to recording and stop to card ready over `--runs` runs.
///
/// Options: `--target area|window|fullscreen --display WxH@S [--rect x,y,w,h] --frames N --fps F
/// [--codec h264|hevc] [--audio system,microphone] [--countdown S] [--kill-after-frames K]
/// [--runs R] [--json]`. Test flags: `--press-esc` and `--press-return` press Esc or Return at
/// the first countdown tick; `--microphone-denied` records with microphone access off;
/// `--tone-dbfs D` writes a 440 Hz tone at D dBFS instead of silence and `--no-audio-track` leaves
/// the audio tracks out (the audio check, design 20.6).
/// Refuses the default SNAP_HOME, so it never writes into the user's history.
@MainActor
enum RecordCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            let request = try Request(parsed)
            return try await record(request, json: parsed.json)
        } catch {
            return exitStatus(for: error)
        }
    }

    // MARK: Request

    struct Request {
        var target: RecordingTarget
        var display: DisplayInfo
        var settings: Settings
        var frames: Int
        var countdown: Int
        var killAfterFrames: Int?
        var runs: Int
        var pressEsc: Bool
        var pressReturn: Bool
        var microphoneDenied: Bool
        var toneDBFS: Double?
        var writesAudioTracks: Bool

        init(_ parsed: CommandArguments) throws {
            guard parsed.flags.contains("--fake") else {
                throw UsageError("record runs only with --fake (Snap never records the screen from snapctl)")
            }
            guard let displaySpec = parsed.options["--display"], let display = DisplayInfo(spec: displaySpec) else {
                throw UsageError("missing or invalid --display WxH@S")
            }
            self.display = display
            let rect = try parsed.options["--rect"].map(RecordCommand.parseRect)
            switch parsed.options["--target"] ?? "area" {
            case "area":
                let area = rect ?? CGRect(
                    x: (display.frameTopLeft.width - 640) / 2, y: (display.frameTopLeft.height - 400) / 2,
                    width: 640, height: 400
                )
                target = .area(area)
            case "window":
                let frame = rect ?? CGRect(x: 120, y: 90, width: 800, height: 500)
                target = .window(WindowInfo(id: 4242, ownerPID: 4242, ownerName: "Notes", frame: frame, order: 0))
            case "fullscreen":
                target = .fullscreen(displayID: display.id)
            case let other:
                throw UsageError("unknown --target \(other) (area, window, fullscreen)")
            }
            frames = try RecordCommand.intOption(parsed, "--frames") ?? 90
            guard frames > 0 else { throw UsageError("--frames must be positive") }
            let fps = try RecordCommand.intOption(parsed, "--fps") ?? 30
            guard fps == 30 || fps == 60 else { throw UsageError("--fps must be 30 or 60") }
            countdown = try RecordCommand.intOption(parsed, "--countdown") ?? 0
            guard countdown >= 0 else { throw UsageError("--countdown must not be negative") }
            killAfterFrames = try RecordCommand.intOption(parsed, "--kill-after-frames")
            if let kill = killAfterFrames, kill <= 0 { throw UsageError("--kill-after-frames must be positive") }
            runs = try RecordCommand.intOption(parsed, "--runs") ?? 1
            guard runs > 0 else { throw UsageError("--runs must be positive") }

            var settings = Settings()
            settings.recording.fps = fps
            switch parsed.options["--codec"] ?? "h264" {
            case "h264", "avc1": settings.recording.format = .h264
            case "hevc", "hvc1": settings.recording.format = .hevc
            case let other: throw UsageError("unknown --codec \(other) (h264, hevc)")
            }
            let audio = (parsed.options["--audio"] ?? "").split(separator: ",").map(String.init)
            for source in audio where AudioSource(rawValue: source) == nil && source != "none" {
                throw UsageError("unknown --audio source \(source) (system, microphone)")
            }
            settings.recording.systemAudio = audio.contains("system")
            settings.recording.microphone = audio.contains("microphone")
            self.settings = settings
            pressEsc = parsed.flags.contains("--press-esc")
            pressReturn = parsed.flags.contains("--press-return")
            microphoneDenied = parsed.flags.contains("--microphone-denied")
            if let tone = parsed.options["--tone-dbfs"] {
                guard let value = Double(tone), value <= 0 else { throw UsageError("--tone-dbfs must be a number <= 0") }
                toneDBFS = value
            } else {
                toneDBFS = nil
            }
            writesAudioTracks = !parsed.flags.contains("--no-audio-track")
        }
    }

    // MARK: Running

    private final class Timeline {
        var starting: UInt64?
        var recording: UInt64?
        var outcome: RecordingStartOutcome?
    }

    private struct RunRecord {
        var outcome: String
        var item: CaptureItem?
        var result: RecordingResult?
        var failure: String?
        var confirmToRecordingMs: Double?
        var stopToCardReadyMs: Double?
        var events: [RecordingEvent]
        var foldersBefore: Int
        var foldersAfter: Int
    }

    private static func record(_ request: Request, json: Bool) async throws -> Int32 {
        let paths = SnapPaths()
        if paths.isDefaultHome {
            throw UsageError("record writes history; set SNAP_HOME to a temp dir")
        }
        try paths.createDirectories()
        let clock = FakeClock(startDate: Date())
        let history = HistoryStore(paths: paths, clock: clock)
        let source = FakeRecordingSource(
            clock: clock,
            options: FakeRecordingSource.Options(
                frames: request.frames, killAfterFrames: request.killAfterFrames, audioToneDBFS: request.toneDBFS,
                writesAudioTracks: request.writesAudioTracks
            )
        )
        let microphone = FakeMicrophoneAuthorization(status: request.microphoneDenied ? .denied : .authorized)
        let controller = RecordingController(
            clock: clock, history: history, source: source, diskSpace: FakeDiskSpace(), microphone: microphone,
            fileNamer: FileNamer(pattern: request.settings.general.fileNamePattern)
        )
        let plan = try RecordingPlan.make(target: request.target, displays: [request.display], settings: request.settings)

        var runs: [RunRecord] = []
        for _ in 0..<request.runs {
            runs.append(try await runOnce(request, plan: plan, controller: controller, clock: clock, source: source, paths: paths))
            if request.killAfterFrames != nil || request.pressEsc { break }
        }
        guard let last = runs.last else { return 1 }
        let output = try await makeOutput(request: request, plan: plan, runs: runs, last: last)
        if json {
            print(try jsonString(output))
        } else {
            printText(output)
        }
        switch last.outcome {
        case "complete", "recording", "cancelled": return 0
        default: return 1
        }
    }

    private static func runOnce(
        _ request: Request,
        plan: RecordingPlan,
        controller: RecordingController,
        clock: FakeClock,
        source: FakeRecordingSource,
        paths: SnapPaths
    ) async throws -> RunRecord {
        controller.clearEvents()
        let foldersBefore = try historyFolderCount(paths)
        let timeline = Timeline()
        controller.onStateChange = { state in
            switch state {
            case .starting: timeline.starting = DispatchTime.now().uptimeNanoseconds
            case .recording: timeline.recording = DispatchTime.now().uptimeNanoseconds
            default: break
            }
        }
        let startTask = Task { @MainActor in
            timeline.outcome = await controller.start(plan: plan, countdownSeconds: request.countdown)
        }
        // Drive the fake clock through the countdown: one second per tick, once the tick's sleep waits.
        var pressed = false
        while timeline.outcome == nil {
            if case .countdown = controller.state {
                if !pressed, request.pressEsc {
                    pressed = true
                    controller.cancelCountdown()
                } else if !pressed, request.pressReturn {
                    pressed = true
                    controller.skipCountdown()
                } else if clock.sleeperCount > 0 {
                    clock.advance(by: 1)
                }
            }
            try await Task.sleep(nanoseconds: 200_000)
        }
        await startTask.value
        controller.onStateChange = nil
        let confirm = elapsedMs(from: timeline.starting, to: timeline.recording)

        var entry = RunRecord(
            outcome: "failed", events: [], foldersBefore: foldersBefore, foldersAfter: foldersBefore
        )
        entry.confirmToRecordingMs = confirm
        switch timeline.outcome {
        case .cancelled:
            entry.outcome = "cancelled"
        case .failed(let failure):
            entry.failure = failure.description
        case .recording(let item):
            entry.item = item
            await source.lastSession?.waitUntilWritten()
            if request.killAfterFrames != nil {
                // A crash: no stop, no finish. The item stays `recording` until `history recover`.
                entry.outcome = "recording"
                entry.item = try history(paths).item(id: item.id) ?? item
            } else {
                let stopStart = DispatchTime.now().uptimeNanoseconds
                let result = await controller.stop(reason: .user)
                entry.stopToCardReadyMs = elapsedMs(from: stopStart, to: DispatchTime.now().uptimeNanoseconds)
                if let result {
                    entry.result = result
                    entry.item = result.item
                    entry.outcome = result.item.state.rawValue
                } else if case .failed(let failure) = controller.state {
                    entry.failure = failure.description
                }
            }
        case nil:
            entry.failure = "the controller did not start"
        }
        entry.events = controller.events
        entry.foldersAfter = try historyFolderCount(paths)
        return entry
    }

    private static func history(_ paths: SnapPaths) -> HistoryStore {
        HistoryStore(paths: paths)
    }

    private static func historyFolderCount(_ paths: SnapPaths) throws -> Int {
        let directory = paths.historyDirectory
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }.count
    }

    // MARK: Output

    struct Timing: Encodable {
        var samples: [Double]
        var p50Ms: Double
        var p95Ms: Double
        var maxMs: Double

        init(_ samples: [Double]) {
            self.samples = samples
            p50Ms = HistoryCommand.percentile(samples, 0.50)
            p95Ms = HistoryCommand.percentile(samples, 0.95)
            maxMs = samples.max() ?? 0
        }
    }

    struct PlanOutput: Encodable {
        var target: String
        var filterKind: String
        var displayID: UInt32
        var windowID: UInt32?
        var excludedWindowIDs: [UInt32]
        var sourceRect: [Double]
        var screenRect: [Double]?
        var scale: Double
        var pixelSize: PixelSize
        var fps: Int
        var minimumFrameInterval: Double
        var queueDepth: Int
        var showsCursor: Bool
        var showsMouseClicks: Bool
        var colorSpace: String
        var colorMatrix: String
        var capturesAudio: Bool
        var excludesCurrentProcessAudio: Bool
        var capturesMicrophone: Bool
        var codec: String

        init(_ plan: RecordingPlan) {
            target = plan.target.mode.rawValue
            filterKind = plan.filterKind.rawValue
            displayID = plan.displayID
            windowID = plan.windowID
            excludedWindowIDs = plan.excludedWindowIDs
            sourceRect = RecordCommand.values(plan.sourceRect)
            screenRect = plan.screenRect.map(RecordCommand.values)
            scale = plan.scale
            pixelSize = plan.pixelSize
            fps = plan.fps
            minimumFrameInterval = plan.minimumFrameInterval
            queueDepth = plan.queueDepth
            showsCursor = plan.showsCursor
            showsMouseClicks = plan.showsMouseClicks
            colorSpace = plan.colorSpaceName
            colorMatrix = plan.colorMatrix
            capturesAudio = plan.capturesAudio
            excludesCurrentProcessAudio = plan.excludesCurrentProcessAudio
            capturesMicrophone = plan.capturesMicrophone
            codec = plan.codec.fourCC
        }
    }

    struct PosterOutput: Encodable {
        var path: String
        var width: Int
        var height: Int
        var scale: Double
        var luminanceStdDev: Double
        var bytes: Int64
    }

    struct RunSummary: Encodable {
        var outcome: String
        var id: String?
        var confirmToRecordingMs: Double?
        var stopToCardReadyMs: Double?
    }

    struct Output: Encodable {
        var outcome: String
        var failure: String?
        var id: String?
        var folder: String?
        var itemFile: String?
        var item: JSONValue?
        var file: String?
        var probe: ProbeCommand.ProbeOutput?
        var poster: PosterOutput?
        var stopReason: String?
        var note: String?
        var noMicrophone: Bool
        /// `captured`, `noTrack`, `microphoneSilent` or `systemSilent`; nil when no audio was asked for.
        var audioCheck: String?
        var plan: PlanOutput
        var events: [RecordingEvent]
        var historyFoldersBefore: Int
        var historyFoldersAfter: Int
        var runs: [RunSummary]
        var confirmToRecording: Timing
        var stopToCardReady: Timing
    }

    private static func makeOutput(request: Request, plan: RecordingPlan, runs: [RunRecord], last: RunRecord) async throws -> Output {
        var output = Output(
            outcome: last.outcome, failure: last.failure, noMicrophone: last.result?.noMicrophone ?? false,
            plan: PlanOutput(plan), events: last.events,
            historyFoldersBefore: runs.first?.foldersBefore ?? 0, historyFoldersAfter: last.foldersAfter,
            runs: runs.map {
                RunSummary(
                    outcome: $0.outcome, id: $0.item?.id, confirmToRecordingMs: $0.confirmToRecordingMs,
                    stopToCardReadyMs: $0.stopToCardReadyMs
                )
            },
            confirmToRecording: Timing(runs.compactMap(\.confirmToRecordingMs)),
            stopToCardReady: Timing(runs.compactMap(\.stopToCardReadyMs))
        )
        if let item = last.item {
            let folder = item.originalURL.deletingLastPathComponent()
            let itemFile = folder.appending(path: HistoryStore.itemFileName, directoryHint: .notDirectory)
            output.id = item.id
            output.folder = folder.path(percentEncoded: false)
            output.itemFile = itemFile.path(percentEncoded: false)
            output.item = try JSONValue(fileAt: itemFile)
            output.file = item.originalURL.path(percentEncoded: false)
            output.probe = ProbeCommand.ProbeOutput(
                file: item.originalURL.path(percentEncoded: false), await VideoProbe.probe(item.originalURL, measureAudio: true)
            )
            if let posterURL = item.posterURL {
                output.poster = try posterOutput(posterURL)
            }
        }
        if let result = last.result {
            output.stopReason = result.stopReason.rawValue
            output.note = result.note
            output.audioCheck = result.audioCheck?.rawValue
        }
        return output
    }

    private static func posterOutput(_ url: URL) throws -> PosterOutput {
        let image = try PNGReader.read(url)
        return PosterOutput(
            path: url.path(percentEncoded: false), width: image.pixelWidth, height: image.pixelHeight,
            scale: image.scale, luminanceStdDev: luminanceStdDev(image.cgImage), bytes: VideoProbe.fileSize(url)
        )
    }

    private static func luminanceStdDev(_ image: CGImage) -> Double {
        guard let bytes = SyntheticImages.rgbaBytes(of: image), !bytes.isEmpty else { return 0 }
        var sum = 0.0
        var squares = 0.0
        let count = bytes.count / 4
        for index in 0..<count {
            let base = index * 4
            let value = 0.2126 * Double(bytes[base]) + 0.7152 * Double(bytes[base + 1]) + 0.0722 * Double(bytes[base + 2])
            sum += value
            squares += value * value
        }
        let mean = sum / Double(count)
        return max(squares / Double(count) - mean * mean, 0).squareRoot()
    }

    private static func printText(_ output: Output) {
        print("outcome \(output.outcome)\(output.failure.map { " (\($0))" } ?? "")")
        if let file = output.file { print("file \(file)") }
        if let probe = output.probe {
            let size = probe.pixelSize.map(\.description) ?? "-"
            print("probe \(probe.codec ?? "-") \(size) \(String(format: "%.3f", probe.durationSeconds)) s, "
                + "\(probe.frameCount.map(String.init) ?? "-") frames, \(probe.audioTrackCount) audio, playable \(probe.playable)")
        }
        if let poster = output.poster { print("poster \(poster.path) \(poster.width)x\(poster.height)") }
        for event in output.events {
            print(String(format: "%8.3f ", event.time) + event.kind.rawValue + (event.detail.map { " \($0)" } ?? ""))
        }
        print(String(
            format: "confirm to recording p50 %.2f ms p95 %.2f ms; stop to card ready p50 %.2f ms p95 %.2f ms",
            output.confirmToRecording.p50Ms, output.confirmToRecording.p95Ms,
            output.stopToCardReady.p50Ms, output.stopToCardReady.p95Ms
        ))
    }

    // MARK: Helpers

    nonisolated static func parseRect(_ text: String) throws -> CGRect {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3] else {
            throw UsageError("--rect must be x,y,w,h in points")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated static func values(_ rect: CGRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.width, rect.height]
    }

    nonisolated private static func intOption(_ parsed: CommandArguments, _ name: String) throws -> Int? {
        guard let value = parsed.options[name] else { return nil }
        guard let number = Int(value) else { throw UsageError("\(name) must be a whole number") }
        return number
    }

    private static func elapsedMs(from start: UInt64?, to end: UInt64?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }

    nonisolated static func jsonString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Any JSON value, so `record --json` can print item.json exactly as it is on disk.
enum JSONValue: Encodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(fileAt url: URL) throws {
        self.init(any: try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed]))
    }

    init(any value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
