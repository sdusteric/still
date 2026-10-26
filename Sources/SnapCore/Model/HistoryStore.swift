import CoreGraphics
import Foundation
import Synchronization

public enum HistoryError: Error, Equatable, CustomStringConvertible {
    case invalidFileName(String)
    case itemNotFound(String)
    case notAVideo(String)

    public var description: String {
        switch self {
        case .invalidFileName(let name): "invalid history file name: \(name)"
        case .itemNotFound(let id): "no history item with id \(id)"
        case .notAVideo(let id): "history item \(id) is not a recording"
        }
    }
}

/// Moves a history folder to the Trash. The app uses `FileManagerTrasher`; tests inject a fake so
/// they never touch the real Trash.
public protocol HistoryTrasher: Sendable {
    /// Moves `url` to the Trash and returns where it went, when known.
    @discardableResult
    func trash(_ url: URL) throws -> URL?
}

/// `FileManager.trashItem`, so a Move to Trash slip is recoverable from the Finder's Trash.
public struct FileManagerTrasher: HistoryTrasher {
    public init() {}

    @discardableResult
    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// A recording about to start: what `add(video:)` writes into `item.json` before the first frame.
public struct NewVideo: Sendable, Hashable {
    /// The mp4 name from `FileNamer`, with extension, for example `Snap 2026-10-24 at 14.03.22.mp4`.
    public var fileName: String
    public var mode: CaptureMode
    public var scale: Double
    public var sourceApp: String?
    public var screenRect: CGRect?
    public var pixelSize: PixelSize?
    public var codec: String?
    public var fps: Double?
    public var audio: [AudioSource]

    public init(
        fileName: String,
        mode: CaptureMode,
        scale: Double,
        sourceApp: String? = nil,
        screenRect: CGRect? = nil,
        pixelSize: PixelSize? = nil,
        codec: String? = nil,
        fps: Double? = nil,
        audio: [AudioSource] = []
    ) {
        self.fileName = fileName
        self.mode = mode
        self.scale = scale
        self.sourceApp = sourceApp
        self.screenRect = screenRect
        self.pixelSize = pixelSize
        self.codec = codec
        self.fps = fps
        self.audio = audio
    }
}

/// What a finished recording probed as (design 20.4 step 3). Nil fields keep the started values.
public struct FinishedVideo: Sendable, Hashable {
    public var durationSeconds: Double
    public var pixelSize: PixelSize?
    public var codec: String?
    public var fps: Double?
    public var audio: [AudioSource]?
    /// The poster PNG, written as `<file name> poster.png` next to the mp4. Nil writes none.
    public var posterPNGData: Data?
    /// `.complete` for a playable file, `.interrupted` when it did not probe as playable.
    public var state: CaptureState
    /// Whether the asked-for audio is in the file; nil when none was asked for.
    public var audioCheck: AudioCheck?

    public init(
        durationSeconds: Double,
        pixelSize: PixelSize? = nil,
        codec: String? = nil,
        fps: Double? = nil,
        audio: [AudioSource]? = nil,
        posterPNGData: Data? = nil,
        state: CaptureState = .complete,
        audioCheck: AudioCheck? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.pixelSize = pixelSize
        self.codec = codec
        self.fps = fps
        self.audio = audio
        self.posterPNGData = posterPNGData
        self.state = state
        self.audioCheck = audioCheck
    }
}

/// `SNAP_HOME/history/<id>/`: the capture PNG or recording mp4, the edited PNG or poster, and
/// `item.json` (design sections 9 and 20.4). The folder is the database: there is no index file.
/// Every capture lands here first, by temp file and rename, so a crash never loses it. Items
/// older than the retention (3 days) are removed by `sweep(skipping:)`, at launch and hourly.
public final class HistoryStore: Sendable {
    public static let retention: TimeInterval = 3 * 24 * 60 * 60
    public static let itemFileName = "item.json"
    public static let currentVersion = 3

    /// What `item.json` holds. File names are relative to the item folder, so the folder can move.
    /// Every field added in versions 2 and 3 is optional, so a version 1 file reads as a complete
    /// image and a version 2 file as an item without annotations or audio check.
    struct Record: Codable {
        var version = HistoryStore.currentVersion
        var id: String
        var createdAt: Date
        var mode: CaptureMode
        var scale: Double
        var originalName: String
        var editedName: String?
        var sourceApp: String?
        var kind: CaptureKind?
        var state: CaptureState?
        /// `[x, y, w, h]`, global top-left points.
        var screenRect: [Double]?
        var pixelSize: PixelSize?
        var durationSeconds: Double?
        var posterName: String?
        var codec: String?
        var fps: Double?
        var audio: [String]?
        /// Version 3: `annotations.json` next to an edited image.
        var annotationsName: String?
        /// Version 3: `AudioCheck` of a finished recording.
        var audioCheck: String?

        var resolvedKind: CaptureKind { kind ?? .image }
        var resolvedState: CaptureState { state ?? .complete }
    }

    public let directory: URL
    private let clock: any Clock
    private let retention: TimeInterval
    private let log: Log?
    private let trasher: any HistoryTrasher
    // Serializes read-modify-write of item.json between the capture, edit and recording queues.
    private let lock = Mutex(())

    /// - Parameter directory: `SNAP_HOME/history`.
    public init(
        directory: URL,
        clock: any Clock = SystemClock(),
        retention: TimeInterval = HistoryStore.retention,
        log: Log? = nil,
        trasher: any HistoryTrasher = FileManagerTrasher()
    ) {
        self.directory = directory.standardizedFileURL
        self.clock = clock
        self.retention = retention
        self.log = log
        self.trasher = trasher
    }

    public convenience init(
        paths: SnapPaths,
        clock: any Clock = SystemClock(),
        log: Log? = nil,
        trasher: any HistoryTrasher = FileManagerTrasher()
    ) {
        self.init(directory: paths.historyDirectory, clock: clock, log: log, trasher: trasher)
    }

    public func folder(for id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }

    // MARK: Writing

    /// Writes the capture PNG and `item.json` into a new `history/<id>/` folder.
    /// - Parameters:
    ///   - fileName: the PNG name from `FileNamer`, with extension, for example `Snap 2026-10-24 at 14.03.22.png`.
    ///   - screenRect: where the capture was, global top-left points (area and window captures).
    ///   - id: defaults to `CaptureItem.makeID` for the clock's current time.
    @discardableResult
    public func add(
        pngData: Data,
        fileName: String,
        mode: CaptureMode,
        scale: Double,
        sourceApp: String? = nil,
        createdAt: Date? = nil,
        id: String? = nil,
        screenRect: CGRect? = nil,
        pixelSize: PixelSize? = nil
    ) throws -> CaptureItem {
        try HistoryStore.validate(fileName)
        let created = createdAt ?? clock.date()
        let itemID = id ?? CaptureItem.makeID(date: created)
        let folder = folder(for: itemID)
        var record = Record(
            id: itemID, createdAt: created, mode: mode, scale: scale,
            originalName: fileName, editedName: nil, sourceApp: sourceApp
        )
        record.kind = .image
        record.state = .complete
        record.screenRect = screenRect.map(HistoryStore.encodeRect)
        record.pixelSize = pixelSize
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try AtomicFile.write(pngData, to: folder.appending(path: fileName, directoryHint: .notDirectory))
            try write(record, in: folder)
        }
        return item(from: record)
    }

    /// Creates `history/<id>/` and writes `item.json` with `kind: video, state: recording` before the
    /// stream starts (design 20.4 step 1). The recorder then writes the mp4 at `originalURL`.
    @discardableResult
    public func add(video: NewVideo, createdAt: Date? = nil, id: String? = nil) throws -> CaptureItem {
        try HistoryStore.validate(video.fileName)
        let created = createdAt ?? clock.date()
        let itemID = id ?? CaptureItem.makeID(date: created)
        let folder = folder(for: itemID)
        var record = Record(
            id: itemID, createdAt: created, mode: video.mode, scale: video.scale,
            originalName: video.fileName, editedName: nil, sourceApp: video.sourceApp
        )
        record.kind = .video
        record.state = .recording
        record.screenRect = video.screenRect.map(HistoryStore.encodeRect)
        record.pixelSize = video.pixelSize
        record.codec = video.codec
        record.fps = video.fps
        record.audio = video.audio.map(\.rawValue)
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(record, in: folder)
        }
        return item(from: record)
    }

    /// Writes the poster (when given) and rewrites `item.json` with the finished state, duration and
    /// probed fields (design 20.4 step 3).
    @discardableResult
    public func finishVideo(id: String, _ finished: FinishedVideo) throws -> CaptureItem {
        let folder = folder(for: id)
        return try lock.withLock { _ -> CaptureItem in
            guard var record = try readRecord(in: folder) else { throw HistoryError.itemNotFound(id) }
            guard record.resolvedKind == .video else { throw HistoryError.notAVideo(id) }
            if let poster = finished.posterPNGData {
                let name = HistoryStore.posterName(for: record.originalName)
                try AtomicFile.write(poster, to: folder.appending(path: name, directoryHint: .notDirectory))
                record.posterName = name
            }
            record.state = finished.state
            record.durationSeconds = finished.durationSeconds
            if let pixelSize = finished.pixelSize { record.pixelSize = pixelSize }
            if let codec = finished.codec { record.codec = codec }
            if let fps = finished.fps { record.fps = fps }
            if let audio = finished.audio { record.audio = audio.map(\.rawValue) }
            record.audioCheck = finished.audioCheck?.rawValue
            try write(record, in: folder)
            return item(from: record)
        }
    }

    /// Writes `<file name> (edited).png` next to the original and records it. Called again, it
    /// replaces the earlier edited version. With `annotations`, also writes `annotations.json`
    /// (version 3) so the edit can be reopened with every annotation editable; without, an
    /// existing `annotations.json` is left as it is.
    @discardableResult
    public func saveEdited(id: String, pngData: Data, annotations: AnnotationFile? = nil) throws -> CaptureItem {
        let folder = folder(for: id)
        let annotationData = try annotations.map { try HistoryStore.makeEncoder().encode($0) }
        return try lock.withLock { _ -> CaptureItem in
            guard var record = try readRecord(in: folder) else { throw HistoryError.itemNotFound(id) }
            let base = URL(filePath: record.originalName).deletingPathExtension().lastPathComponent
            let editedName = "\(base) (edited).png"
            try AtomicFile.write(pngData, to: folder.appending(path: editedName, directoryHint: .notDirectory))
            record.editedName = editedName
            if let annotationData {
                let name = AnnotationFile.fileName
                try AtomicFile.write(annotationData, to: folder.appending(path: name, directoryHint: .notDirectory))
                record.annotationsName = name
            }
            try write(record, in: folder)
            return item(from: record)
        }
    }

    /// The annotations of an edited capture, nil when it has none (unedited, or edited before
    /// version 3). Throws when the file exists but does not decode.
    public func annotations(id: String) throws -> AnnotationFile? {
        let folder = folder(for: id)
        return try lock.withLock { _ -> AnnotationFile? in
            guard let record = try readRecord(in: folder), let name = record.annotationsName else { return nil }
            let data: Data
            do {
                data = try Data(contentsOf: folder.appending(path: name, directoryHint: .notDirectory))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return nil
            }
            return try JSONDecoder().decode(AnnotationFile.self, from: data)
        }
    }

    /// At launch, before the first sweep: every item still in `state: recording` becomes
    /// `interrupted` (the app or the Mac stopped mid-recording). Returns the ids it changed.
    @discardableResult
    public func markInterrupted() throws -> [String] {
        var changed: [String] = []
        for folder in try itemFolders() {
            do {
                let didChange = try lock.withLock { _ -> Bool in
                    guard var record = try readRecord(in: folder), record.resolvedState == .recording else { return false }
                    record.state = .interrupted
                    try write(record, in: folder)
                    return true
                }
                if didChange {
                    changed.append(folder.lastPathComponent)
                    log?.info("history: marked \(folder.lastPathComponent) interrupted")
                }
            } catch {
                log?.warning("history: could not check \(folder.lastPathComponent) for an interrupted recording: \(error)")
            }
        }
        return changed.sorted()
    }

    // MARK: Reading

    /// One item, nil when its folder or `item.json` does not exist.
    public func item(id: String) throws -> CaptureItem? {
        let folder = folder(for: id)
        return try lock.withLock { _ in
            try readRecord(in: folder).map(item(from:))
        }
    }

    /// The newest `limit` items, newest first. A folder with an unreadable `item.json` is logged
    /// and skipped.
    public func recent(limit: Int) throws -> [CaptureItem] {
        Array(try allItems().prefix(max(limit, 0)))
    }

    /// Every item, newest first.
    public func allItems() throws -> [CaptureItem] {
        var items: [CaptureItem] = []
        let decoder = HistoryStore.makeDecoder()
        for folder in try itemFolders() {
            do {
                let record = try lock.withLock { _ in try readRecord(in: folder, decoder: decoder) }
                if let record { items.append(item(from: record)) }
            } catch {
                log?.warning("history: skipped \(folder.lastPathComponent): \(error)")
            }
        }
        return items.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id > rhs.id : lhs.createdAt > rhs.createdAt
        }
    }

    /// Bytes of every file under the history folder (the history footer total).
    public func totalBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Retention

    /// Removes item folders older than the retention and returns their ids, oldest first. Ids in
    /// `skipping` are in use (an open card, a pin, an editor, a recording) and wait for the next
    /// sweep. A folder without a readable `item.json` is judged by its modification date. Only
    /// direct children of the history folder are ever removed.
    /// - Parameter now: the time to judge against; defaults to the clock's date.
    @discardableResult
    /// `imageRetention` applies to screenshots; recordings always use `retention` (Recall design 7.4).
    public func sweep(skipping: Set<String> = [], now: Date? = nil, imageRetention: TimeInterval? = nil) throws -> [String] {
        let now = now ?? clock.date()
        let videoCutoff = now.addingTimeInterval(-retention)
        let imageCutoff = now.addingTimeInterval(-(imageRetention ?? retention))
        var expired: [(id: String, created: Date, folder: URL)] = []
        for folder in try itemFolders() {
            let id = folder.lastPathComponent
            guard !skipping.contains(id), let (created, kind) = createdDateAndKind(of: folder) else { continue }
            guard created < (kind == .video ? videoCutoff : imageCutoff) else { continue }
            expired.append((id, created, folder))
        }
        expired.sort { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
        var removed: [String] = []
        for entry in expired {
            try lock.withLock { _ in try FileManager.default.removeItem(at: entry.folder) }
            removed.append(entry.id)
            log?.info("history: removed \(entry.id)")
        }
        return removed
    }

    /// Removes one item outright: a recording that failed before its first frame (design 20.4
    /// step 5). The user's delete goes through `trash(id:)`.
    public func remove(id: String) throws {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try lock.withLock { _ in try FileManager.default.removeItem(at: folder) }
    }

    /// Moves one item folder to the Trash (Move to Trash, Cmd+Delete, Cancel Recording). Returns
    /// false when there is no such item.
    @discardableResult
    public func trash(id: String) throws -> Bool {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return false }
        try lock.withLock { _ in _ = try trasher.trash(folder) }
        log?.info("history: moved \(id) to the Trash")
        return true
    }

    // MARK: Helpers

    /// `<base> poster.png` for an mp4 named `<base>.mp4`.
    public static func posterName(for videoName: String) -> String {
        let base = URL(filePath: videoName).deletingPathExtension().lastPathComponent
        return "\(base) poster.png"
    }

    private func itemFolders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    }

    private func createdDateAndKind(of folder: URL) -> (Date, CaptureKind)? {
        do {
            if let record = try readRecord(in: folder) { return (record.createdAt, record.kind ?? .image) }
        } catch {
            log?.warning("history: unreadable item.json in \(folder.lastPathComponent): \(error)")
        }
        return createdDate(of: folder).map { ($0, .image) }
    }

    private func createdDate(of folder: URL) -> Date? {
        do {
            if let record = try readRecord(in: folder) { return record.createdAt }
        } catch {
            log?.warning("history: unreadable item.json in \(folder.lastPathComponent): \(error)")
        }
        do {
            return try folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch {
            log?.warning("history: no date for \(folder.lastPathComponent): \(error)")
            return nil
        }
    }

    private func readRecord(in folder: URL, decoder: JSONDecoder = HistoryStore.makeDecoder()) throws -> Record? {
        let file = folder.appending(path: HistoryStore.itemFileName, directoryHint: .notDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        return try decoder.decode(Record.self, from: data)
    }

    private func write(_ record: Record, in folder: URL) throws {
        var record = record
        record.version = HistoryStore.currentVersion
        let file = folder.appending(path: HistoryStore.itemFileName, directoryHint: .notDirectory)
        try AtomicFile.write(try HistoryStore.makeEncoder().encode(record), to: file)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func item(from record: Record) -> CaptureItem {
        let folder = folder(for: record.id)
        let isVideo = record.resolvedKind == .video
        return CaptureItem(
            id: record.id,
            createdAt: record.createdAt,
            mode: record.mode,
            scale: record.scale,
            originalURL: folder.appending(path: record.originalName, directoryHint: .notDirectory),
            editedURL: isVideo ? nil : record.editedName.map { folder.appending(path: $0, directoryHint: .notDirectory) },
            sourceApp: record.sourceApp,
            kind: record.resolvedKind,
            state: isVideo ? record.resolvedState : .complete,
            screenRect: record.screenRect.flatMap(HistoryStore.decodeRect),
            pixelSize: record.pixelSize,
            durationSeconds: isVideo ? record.durationSeconds : nil,
            posterURL: isVideo ? record.posterName.map { folder.appending(path: $0, directoryHint: .notDirectory) } : nil,
            codec: isVideo ? record.codec : nil,
            fps: isVideo ? record.fps : nil,
            audio: isVideo ? (record.audio ?? []).compactMap(AudioSource.init(rawValue:)) : [],
            audioCheck: isVideo ? record.audioCheck.flatMap(AudioCheck.init(rawValue:)) : nil,
            annotationsURL: isVideo ? nil : record.annotationsName.map { folder.appending(path: $0, directoryHint: .notDirectory) }
        )
    }

    static func encodeRect(_ rect: CGRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.width, rect.height]
    }

    static func decodeRect(_ values: [Double]) -> CGRect? {
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func validate(_ fileName: String) throws {
        if fileName.isEmpty || fileName.contains("/") || fileName.contains(":") || fileName.hasPrefix(".")
            || fileName == HistoryStore.itemFileName {
            throw HistoryError.invalidFileName(fileName)
        }
    }
}
