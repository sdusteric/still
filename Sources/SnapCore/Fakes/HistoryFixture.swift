import CoreGraphics
import Foundation
import Synchronization

/// A trasher for tests: moves folders into its own directory (a temp dir), never the real Trash,
/// and records what it moved.
public final class FakeTrasher: HistoryTrasher {
    public let directory: URL
    private let moved = Mutex<[URL]>([])

    public init(directory: URL) {
        self.directory = directory
    }

    /// The original URLs moved so far, in order.
    public var trashed: [URL] { moved.withLock { $0 } }

    @discardableResult
    public func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(url.lastPathComponent)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: url, to: target)
        moved.withLock { $0.append(url) }
        return target
    }
}

/// A deterministic random source (SplitMix64), so a fixture seed always gives the same items.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// `snapctl history gen` (design 20.14): N items spread over D days before `now`, screenshots and
/// recordings, some edited, some interrupted, some still recording, some with a version 1
/// `item.json`. The same seed and `now` give the same items. The manifest records the expected
/// sweep and query results, so the acceptance checks compare against it instead of re-deriving.
public enum HistoryFixture {
    public static let manifestFileName = "history-fixture.json"
    /// Apps for `sourceApp`; only "Notes" contains the word "notes".
    public static let apps = ["Notes", "Safari", "Xcode", "Figma", "Slack", "Mail", "Terminal", "Finder", "Preview", "Messages"]

    public struct Options: Sendable, Hashable {
        public var items: Int
        public var days: Int
        public var seed: UInt64
        public var now: Date
        public var timeZone: TimeZone

        public init(items: Int, days: Int, seed: UInt64 = 1, now: Date, timeZone: TimeZone = .current) {
            self.items = max(items, 0)
            self.days = max(days, 1)
            self.seed = seed
            // item.json stores whole seconds, so the fixture works in whole seconds too.
            self.now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            self.timeZone = timeZone
        }
    }

    public struct ExpectedQuery: Sendable, Hashable, Codable {
        public var query: String?
        public var kind: String?
        /// The matching ids after the sweep that skips `skipID`, newest first.
        public var expectedIDs: [String]
    }

    public struct Manifest: Sendable, Hashable, Codable {
        public var seed: UInt64
        public var items: Int
        public var days: Int
        /// ISO 8601, the `--now` to sweep with.
        public var now: String
        public var timeZone: String
        /// Every id, newest first.
        public var ids: [String]
        /// Items older than the 72 h retention, oldest first.
        public var oldIDs: [String]
        /// The first old id: the in-use item the sweep check skips.
        public var skipID: String?
        /// What `history sweep --now <now> --skip <skipID>` removes, oldest first.
        public var expectedSweptIDs: [String]
        /// What is left after that sweep, newest first.
        public var remainingIDs: [String]
        public var version1IDs: [String]
        public var videoIDs: [String]
        public var editedIDs: [String]
        public var interruptedIDs: [String]
        public var recordingIDs: [String]
        public var queries: [ExpectedQuery]
    }

    /// Writes the items into `history` and returns the manifest. Does not write the manifest file.
    public static func generate(into history: HistoryStore, options: Options) throws -> Manifest {
        var random = SeededGenerator(seed: options.seed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = options.timeZone
        let now = options.now
        let span = TimeInterval(options.days) * 86_400
        let todaySeconds = max(now.timeIntervalSince(calendar.startOfDay(for: now)), 1)
        let png = try imageData(width: 320, height: 200)
        let poster = try imageData(width: 320, height: 200)
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = options.timeZone
        timeFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        var created: [(id: String, date: Date, kind: CaptureKind, app: String?)] = []
        var version1: [String] = []
        var edited: [String] = []
        var interrupted: [String] = []
        var recording: [String] = []
        var usedIDs: Set<String> = []

        for index in 0..<options.items {
            var age: TimeInterval
            if index < 3 {
                // A few "Notes" captures today, so "notes today" always has answers.
                age = Double(UInt64.random(in: 0...UInt64(todaySeconds - 1), using: &random))
            } else {
                age = Double(UInt64.random(in: 0...UInt64(max(span - 1, 0)), using: &random))
            }
            // Stay clear of the retention boundary so the expected sweep is unambiguous.
            if abs(age - HistoryStore.retention) < 120 { age += 240 }
            let date = now.addingTimeInterval(-age)
            var suffix = String(format: "%08x", UInt32(truncatingIfNeeded: random.next()))
            var id = CaptureItem.makeID(date: date, suffix: suffix, timeZone: options.timeZone)
            while usedIDs.contains(id) {
                suffix = String(format: "%08x", UInt32(truncatingIfNeeded: random.next()))
                id = CaptureItem.makeID(date: date, suffix: suffix, timeZone: options.timeZone)
            }
            usedIDs.insert(id)

            let app: String? = index < 3 ? "Notes"
                : (Int.random(in: 0..<10, using: &random) == 0 ? nil : apps[Int.random(in: 0..<apps.count, using: &random)])
            let mode = CaptureMode.allCases[Int.random(in: 0..<3, using: &random)]
            let scale: Double = Int.random(in: 0..<4, using: &random) == 0 ? 1 : 2
            let isVideo = index >= 3 && Int.random(in: 0..<100, using: &random) < 15
            let base = "Still \(timeFormatter.string(from: date))"
            let rect = mode == .fullscreen ? nil
                : CGRect(x: Double(Int.random(in: 0..<1200, using: &random)), y: Double(Int.random(in: 0..<700, using: &random)),
                         width: Double(Int.random(in: 200...900, using: &random)), height: Double(Int.random(in: 150...600, using: &random)))
            let points = rect?.size ?? CGSize(width: 2560, height: 1440)
            let pixels = PixelSize(width: Int(points.width * scale), height: Int(points.height * scale))

            if isVideo {
                let codec = Int.random(in: 0..<3, using: &random) == 0 ? "hvc1" : "avc1"
                let video = NewVideo(
                    fileName: "\(base).mp4", mode: mode, scale: scale, sourceApp: app, screenRect: rect,
                    pixelSize: PixelSize(width: pixels.width & ~1, height: pixels.height & ~1), codec: codec, fps: 30
                )
                let item = try history.add(video: video, createdAt: date, id: id)
                // A placeholder, not a playable mp4: listing and sweeping never read it.
                try AtomicFile.write(Data("snap history fixture placeholder\n".utf8), to: item.originalURL)
                let roll = Int.random(in: 0..<8, using: &random)
                if roll == 0 {
                    recording.append(id)
                } else {
                    let state: CaptureState = roll <= 2 ? .interrupted : .complete
                    if state == .interrupted { interrupted.append(id) }
                    let duration = Double(Int.random(in: 20...1200, using: &random)) / 10
                    _ = try history.finishVideo(id: id, FinishedVideo(durationSeconds: duration, posterPNGData: poster, state: state))
                }
                created.append((id, date, .video, app))
                continue
            }

            let roll = Int.random(in: 0..<100, using: &random)
            if index >= 3 && roll < 15 {
                try writeVersion1(into: history, id: id, date: date, mode: mode, scale: scale, fileName: "\(base).png", app: app, png: png)
                version1.append(id)
            } else {
                _ = try history.add(
                    pngData: png, fileName: "\(base).png", mode: mode, scale: scale, sourceApp: app,
                    createdAt: date, id: id, screenRect: rect, pixelSize: pixels
                )
                if roll >= 80 {
                    _ = try history.saveEdited(id: id, pngData: png)
                    edited.append(id)
                }
            }
            created.append((id, date, .image, app))
        }

        let newestFirst = created.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
        let cutoff = now.addingTimeInterval(-HistoryStore.retention)
        let old = created.filter { $0.date < cutoff }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let skipID = old.first?.id
        let swept = old.map(\.id).filter { $0 != skipID }
        let sweptSet = Set(swept)
        let remaining = newestFirst.filter { !sweptSet.contains($0.id) }
        let context = HistoryDateContext(now: now, calendar: calendar)
        let notesToday = remaining.filter { $0.app == "Notes" && context.isToday($0.date) }.map(\.id)
        let videos = remaining.filter { $0.kind == .video }.map(\.id)
        let images = remaining.filter { $0.kind == .image }.map(\.id)

        let iso = ISO8601DateFormatter()
        return Manifest(
            seed: options.seed, items: options.items, days: options.days,
            now: iso.string(from: now), timeZone: options.timeZone.identifier,
            ids: newestFirst.map(\.id), oldIDs: old.map(\.id), skipID: skipID,
            expectedSweptIDs: swept, remainingIDs: remaining.map(\.id),
            version1IDs: version1.sorted(), videoIDs: created.filter { $0.kind == .video }.map(\.id).sorted(),
            editedIDs: edited.sorted(), interruptedIDs: interrupted.sorted(), recordingIDs: recording.sorted(),
            queries: [
                ExpectedQuery(query: "notes today", kind: nil, expectedIDs: notesToday),
                ExpectedQuery(query: nil, kind: CaptureKind.video.rawValue, expectedIDs: videos),
                ExpectedQuery(query: nil, kind: CaptureKind.image.rawValue, expectedIDs: images),
            ]
        )
    }

    public enum FixtureError: Error, Equatable {
        case cannotRenderImage
    }

    /// The manifest as pretty JSON.
    public static func encode(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    /// A version 1 `item.json`, exactly as M1 wrote it: no kind, state or video fields.
    private static func writeVersion1(
        into history: HistoryStore, id: String, date: Date, mode: CaptureMode, scale: Double,
        fileName: String, app: String?, png: Data
    ) throws {
        struct VersionOne: Encodable {
            var version = 1
            var id: String
            var createdAt: Date
            var mode: CaptureMode
            var scale: Double
            var originalName: String
            var sourceApp: String?
        }
        let folder = history.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AtomicFile.write(png, to: folder.appending(path: fileName, directoryHint: .notDirectory))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let record = VersionOne(id: id, createdAt: date, mode: mode, scale: scale, originalName: fileName, sourceApp: app)
        try AtomicFile.write(try encoder.encode(record), to: folder.appending(path: HistoryStore.itemFileName, directoryHint: .notDirectory))
    }

    private static func imageData(width: Int, height: Int) throws -> Data {
        guard let image = SyntheticImages.gradientGrid(width: width, height: height, scale: 2) else {
            throw FixtureError.cannotRenderImage
        }
        return try PNGWriter.data(for: image, scale: 2)
    }
}
