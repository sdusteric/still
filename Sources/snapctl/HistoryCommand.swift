import Foundation
import SnapCore

/// `snapctl history` (design 20.14), over `SNAP_HOME/history`:
/// - `gen --items N --days D [--seed S] [--now ISO]`: writes a `HistoryFixture` and its manifest
///   (`SNAP_HOME/history-fixture.json`).
/// - `list [--query q] [--kind image|video] [--runs R] [--now ISO] --json`: the matching items and
///   the p50 and p95 time of `allItems()` plus the query over R runs.
/// - `sweep [--now ISO] [--skip id,...] --json`: the retention sweep, skipping in-use ids.
/// - `recover --json`: marks items still `recording` as `interrupted`, as the app does at launch.
/// `gen` and `sweep` refuse the default SNAP_HOME, so they never touch the user's real history.
enum HistoryCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let sub = arguments.first else { throw UsageError("history needs gen, list, sweep or recover") }
            let parsed = try CommandArguments(Array(arguments.dropFirst()))
            let paths = SnapPaths()
            switch sub {
            case "gen": return try generate(parsed, paths: paths)
            case "list": return try list(parsed, paths: paths)
            case "sweep": return try sweep(parsed, paths: paths)
            case "recover": return try recover(parsed, paths: paths)
            default: throw UsageError("unknown history command \(sub)")
            }
        } catch {
            return exitStatus(for: error)
        }
    }

    // MARK: gen

    private static func generate(_ parsed: CommandArguments, paths: SnapPaths) throws -> Int32 {
        try refuseDefaultHome(paths, command: "history gen")
        let items = try intOption(parsed, "--items", required: true) ?? 0
        let days = try intOption(parsed, "--days", required: true) ?? 1
        guard items > 0, days > 0 else { throw UsageError("--items and --days must be positive") }
        let seed = try parsed.options["--seed"].map { value -> UInt64 in
            guard let seed = UInt64(value) else { throw UsageError("--seed must be a whole number") }
            return seed
        } ?? 1
        let now = try dateOption(parsed) ?? Date()
        try paths.createDirectories()
        let store = HistoryStore(paths: paths)
        let manifest = try HistoryFixture.generate(
            into: store, options: HistoryFixture.Options(items: items, days: days, seed: seed, now: now)
        )
        let data = try HistoryFixture.encode(manifest)
        let manifestURL = paths.home.appending(path: HistoryFixture.manifestFileName, directoryHint: .notDirectory)
        try AtomicFile.write(data, to: manifestURL)
        if parsed.json {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("wrote \(manifest.ids.count) items (\(manifest.oldIDs.count) older than 72 h) and \(manifestURL.path(percentEncoded: false))")
        }
        return 0
    }

    // MARK: list

    private struct ListedItem: Encodable {
        var id: String
        var kind: CaptureKind
        var state: CaptureState
        var mode: CaptureMode
        var createdAt: Date
        var sourceApp: String?
        var file: String
        var edited: Bool
        var screenRect: [Double]?
        var pixelSize: PixelSize?
        var durationSeconds: Double?
        var poster: String?
        var codec: String?
        var fps: Double?
        var audio: [AudioSource]

        init(_ item: CaptureItem) {
            id = item.id
            kind = item.kind
            state = item.state
            mode = item.mode
            createdAt = item.createdAt
            sourceApp = item.sourceApp
            file = item.originalURL.path(percentEncoded: false)
            edited = item.isEdited
            screenRect = item.screenRect.map { [$0.origin.x, $0.origin.y, $0.width, $0.height] }
            pixelSize = item.pixelSize
            durationSeconds = item.durationSeconds
            poster = item.posterURL?.path(percentEncoded: false)
            codec = item.codec
            fps = item.fps
            audio = item.audio
        }
    }

    private struct Timing: Encodable {
        var runs: Int
        var p50Ms: Double
        var p95Ms: Double
        var maxMs: Double
    }

    private struct ListOutput: Encodable {
        var count: Int
        var totalBytes: Int64
        var query: String?
        var kind: String?
        var now: Date
        var ids: [String]
        var items: [ListedItem]
        var timing: Timing
    }

    private static func list(_ parsed: CommandArguments, paths: SnapPaths) throws -> Int32 {
        let kind: HistoryQuery.KindFilter
        switch parsed.options["--kind"] {
        case nil, "all": kind = .all
        case "image", "images": kind = .images
        case "video", "videos": kind = .videos
        case let other?: throw UsageError("unknown --kind \(other) (image, video)")
        }
        let runs = try intOption(parsed, "--runs", required: false) ?? 1
        guard runs > 0 else { throw UsageError("--runs must be positive") }
        let now = try dateOption(parsed) ?? Date()
        let store = HistoryStore(paths: paths)
        let query = HistoryQuery(kind: kind, text: parsed.options["--query"] ?? "")
        let context = HistoryDateContext(now: now)

        var durations: [Double] = []
        var result: [CaptureItem] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            result = query.filter(try store.allItems(), context: context)
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let output = ListOutput(
            count: result.count, totalBytes: try store.totalBytes(), query: parsed.options["--query"],
            kind: parsed.options["--kind"], now: now, ids: result.map(\.id), items: result.map(ListedItem.init),
            timing: Timing(
                runs: runs, p50Ms: percentile(durations, 0.50), p95Ms: percentile(durations, 0.95),
                maxMs: durations.max() ?? 0
            )
        )
        if parsed.json {
            print(try jsonString(output))
        } else {
            for item in result {
                print("\(item.id)  \(item.kind.rawValue)  \(item.state.rawValue)  \(item.sourceApp ?? "-")  \(item.fileName)")
            }
            print("\(result.count) items, p50 \(format(output.timing.p50Ms)) ms, p95 \(format(output.timing.p95Ms)) ms")
        }
        return 0
    }

    // MARK: sweep and recover

    private struct SweepOutput: Encodable {
        var now: Date
        var skipped: [String]
        var removed: [String]
        var remaining: Int
    }

    private static func sweep(_ parsed: CommandArguments, paths: SnapPaths) throws -> Int32 {
        try refuseDefaultHome(paths, command: "history sweep")
        let now = try dateOption(parsed) ?? Date()
        let skip = (parsed.options["--skip"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let store = HistoryStore(paths: paths)
        let removed = try store.sweep(skipping: Set(skip), now: now)
        let output = SweepOutput(now: now, skipped: skip, removed: removed, remaining: try store.allItems().count)
        if parsed.json {
            print(try jsonString(output))
        } else {
            print("removed \(removed.count) items, \(output.remaining) left")
        }
        return 0
    }

    private struct RecoverOutput: Encodable {
        var interrupted: [String]
    }

    private static func recover(_ parsed: CommandArguments, paths: SnapPaths) throws -> Int32 {
        try refuseDefaultHome(paths, command: "history recover")
        let interrupted = try HistoryStore(paths: paths).markInterrupted()
        if parsed.json {
            print(try jsonString(RecoverOutput(interrupted: interrupted)))
        } else {
            print("marked \(interrupted.count) items interrupted")
        }
        return 0
    }

    // MARK: Helpers

    private static func refuseDefaultHome(_ paths: SnapPaths, command: String) throws {
        if paths.isDefaultHome {
            throw UsageError("\(command) changes history; set SNAP_HOME to a temp dir")
        }
    }

    private static func intOption(_ parsed: CommandArguments, _ name: String, required: Bool) throws -> Int? {
        guard let value = parsed.options[name] else {
            if required { throw UsageError("missing \(name) <n>") }
            return nil
        }
        guard let number = Int(value) else { throw UsageError("\(name) must be a whole number") }
        return number
    }

    private static func dateOption(_ parsed: CommandArguments) throws -> Date? {
        guard let value = parsed.options["--now"] else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: value) ?? fractional.date(from: value) else {
            throw UsageError("--now must be an ISO 8601 date such as 2026-10-24T14:00:00Z")
        }
        return date
    }

    /// Nearest-rank percentile.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func jsonString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
