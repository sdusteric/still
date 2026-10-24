import Foundation
import Synchronization

public enum HistoryError: Error, Equatable, CustomStringConvertible {
    case invalidFileName(String)
    case itemNotFound(String)

    public var description: String {
        switch self {
        case .invalidFileName(let name): "invalid history file name: \(name)"
        case .itemNotFound(let id): "no history item with id \(id)"
        }
    }
}

/// `SNAP_HOME/history/<id>/`: the capture PNG, the edited PNG and `item.json` (design section 9).
/// Every capture lands here first, by temp file and rename, so a crash never loses it. Items
/// older than the retention (3 days) are removed by `sweep()`, at launch and hourly.
public final class HistoryStore: Sendable {
    public static let retention: TimeInterval = 3 * 24 * 60 * 60
    public static let itemFileName = "item.json"

    /// What `item.json` holds. File names are relative to the item folder, so the folder can move.
    struct Record: Codable {
        var version = 1
        var id: String
        var createdAt: Date
        var mode: CaptureMode
        var scale: Double
        var originalName: String
        var editedName: String?
        var sourceApp: String?
    }

    public let directory: URL
    private let clock: any Clock
    private let retention: TimeInterval
    private let log: Log?
    // Serializes read-modify-write of item.json between the capture and edit queues.
    private let lock = Mutex(())

    /// - Parameter directory: `SNAP_HOME/history`.
    public init(directory: URL, clock: any Clock = SystemClock(), retention: TimeInterval = HistoryStore.retention, log: Log? = nil) {
        self.directory = directory.standardizedFileURL
        self.clock = clock
        self.retention = retention
        self.log = log
    }

    public convenience init(paths: SnapPaths, clock: any Clock = SystemClock(), log: Log? = nil) {
        self.init(directory: paths.historyDirectory, clock: clock, log: log)
    }

    public func folder(for id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }

    // MARK: Writing

    /// Writes the capture PNG and `item.json` into a new `history/<id>/` folder.
    /// - Parameters:
    ///   - fileName: the PNG name from `FileNamer`, with extension, for example `Snap 2026-10-24 at 14.03.22.png`.
    ///   - id: defaults to `CaptureItem.makeID` for the clock's current time.
    @discardableResult
    public func add(
        pngData: Data,
        fileName: String,
        mode: CaptureMode,
        scale: Double,
        sourceApp: String? = nil,
        createdAt: Date? = nil,
        id: String? = nil
    ) throws -> CaptureItem {
        try HistoryStore.validate(fileName)
        let created = createdAt ?? clock.date()
        let itemID = id ?? CaptureItem.makeID(date: created)
        let folder = folder(for: itemID)
        let record = Record(
            id: itemID, createdAt: created, mode: mode, scale: scale,
            originalName: fileName, editedName: nil, sourceApp: sourceApp
        )
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try AtomicFile.write(pngData, to: folder.appending(path: fileName, directoryHint: .notDirectory))
            try write(record, in: folder)
        }
        return item(from: record)
    }

    /// Writes `<file name> (edited).png` next to the original and records it. Called again, it
    /// replaces the earlier edited version.
    @discardableResult
    public func saveEdited(id: String, pngData: Data) throws -> CaptureItem {
        let folder = folder(for: id)
        return try lock.withLock { _ -> CaptureItem in
            guard var record = try readRecord(in: folder) else { throw HistoryError.itemNotFound(id) }
            let base = URL(filePath: record.originalName).deletingPathExtension().lastPathComponent
            let editedName = "\(base) (edited).png"
            try AtomicFile.write(pngData, to: folder.appending(path: editedName, directoryHint: .notDirectory))
            record.editedName = editedName
            try write(record, in: folder)
            return item(from: record)
        }
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
        for folder in try itemFolders() {
            do {
                let record = try lock.withLock { _ in try readRecord(in: folder) }
                if let record { items.append(item(from: record)) }
            } catch {
                log?.warning("history: skipped \(folder.lastPathComponent): \(error)")
            }
        }
        return items.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id > rhs.id : lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: Retention

    /// Removes item folders older than the retention and returns their ids. A folder without a
    /// readable `item.json` is judged by its modification date. Only direct children of the history
    /// folder are ever removed.
    @discardableResult
    public func sweep() throws -> [String] {
        let cutoff = clock.date().addingTimeInterval(-retention)
        var removed: [String] = []
        for folder in try itemFolders() {
            guard let created = createdDate(of: folder), created < cutoff else { continue }
            try lock.withLock { _ in try FileManager.default.removeItem(at: folder) }
            removed.append(folder.lastPathComponent)
            log?.info("history: removed \(folder.lastPathComponent)")
        }
        return removed
    }

    /// Removes one item at the user's request.
    public func remove(id: String) throws {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try lock.withLock { _ in try FileManager.default.removeItem(at: folder) }
    }

    // MARK: Helpers

    private func itemFolders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
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

    private func readRecord(in folder: URL) throws -> Record? {
        let file = folder.appending(path: HistoryStore.itemFileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Record.self, from: Data(contentsOf: file))
    }

    private func write(_ record: Record, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let file = folder.appending(path: HistoryStore.itemFileName, directoryHint: .notDirectory)
        try AtomicFile.write(try encoder.encode(record), to: file)
    }

    private func item(from record: Record) -> CaptureItem {
        let folder = folder(for: record.id)
        return CaptureItem(
            id: record.id,
            createdAt: record.createdAt,
            mode: record.mode,
            scale: record.scale,
            originalURL: folder.appending(path: record.originalName, directoryHint: .notDirectory),
            editedURL: record.editedName.map { folder.appending(path: $0, directoryHint: .notDirectory) },
            sourceApp: record.sourceApp
        )
    }

    private static func validate(_ fileName: String) throws {
        if fileName.isEmpty || fileName.contains("/") || fileName.contains(":") || fileName.hasPrefix(".")
            || fileName == HistoryStore.itemFileName {
            throw HistoryError.invalidFileName(fileName)
        }
    }
}
