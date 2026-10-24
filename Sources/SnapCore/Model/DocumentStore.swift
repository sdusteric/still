import Foundation
import Synchronization

private struct VersionProbe: Decodable { var version: Int }

/// A JSON document with a schema version, stored in one file.
public protocol VersionedDocument: Codable, Sendable, Equatable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

/// What `load()` found.
public enum StoreLoadOutcome: Sendable, Equatable {
    /// No file yet: the defaults are in use.
    case missing
    case loaded
    /// The file did not decode. It was moved aside (never deleted) and the defaults are in use.
    case recovered(movedTo: URL)
    /// The file was written by a newer schema. It was moved aside and the defaults are in use.
    case newerVersion(movedTo: URL)
}

/// Atomic file writes: a temp file in the same directory, then `rename(2)` over the target, so a
/// reader never sees a half-written file (design section 14).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(
            path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))",
            directoryHint: .notDirectory
        )
        try data.write(to: temp)
        let status = rename(temp.path(percentEncoded: false), url.path(percentEncoded: false))
        if status != 0 {
            let code = errno
            do {
                try FileManager.default.removeItem(at: temp)
            } catch {
                // The rename failure below is the useful error; a stray temp file is harmless.
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// One JSON file with atomic writes and recovery from a corrupt or newer file. Settings, state
/// and presets share it. A change is applied in memory, then `flush()` writes it; a failed write
/// leaves the change pending so the next flush retries, and the error reaches the caller.
public final class DocumentStore<Document: VersionedDocument>: Sendable {
    private struct State {
        var document: Document
        var dirty = false
        var writeCount = 0
    }

    public let fileURL: URL
    private let defaultDocument: Document
    private let now: @Sendable () -> Date
    private let state: Mutex<State>

    public init(fileURL: URL, defaultDocument: Document, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.defaultDocument = defaultDocument
        self.now = now
        self.state = Mutex(State(document: defaultDocument))
    }

    public var document: Document { state.withLock { $0.document } }
    public var hasPendingWrite: Bool { state.withLock { $0.dirty } }
    public var writeCount: Int { state.withLock { $0.writeCount } }

    /// Reads the file. A missing file means defaults; a corrupt or newer one is moved aside.
    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            state.withLock { $0.document = defaultDocument; $0.dirty = false }
            return .missing
        }
        let decoder = DocumentStore.makeDecoder()
        do {
            let probe = try decoder.decode(VersionProbe.self, from: data)
            if probe.version > Document.currentVersion {
                let moved = try moveAside(suffix: "newer")
                state.withLock { $0.document = defaultDocument; $0.dirty = false }
                return .newerVersion(movedTo: moved)
            }
            let document = try decoder.decode(Document.self, from: data)
            state.withLock { $0.document = document; $0.dirty = false }
            return .loaded
        } catch is DecodingError {
            let moved = try moveAside(suffix: "corrupt")
            state.withLock { $0.document = defaultDocument; $0.dirty = false }
            return .recovered(movedTo: moved)
        }
    }

    /// Applies `body` and marks the document pending when it changed. Does not write.
    @discardableResult
    public func mutate<Result>(_ body: (inout Document) -> Result) -> Result {
        state.withLock { state in
            var copy = state.document
            let result = body(&copy)
            if copy != state.document {
                state.document = copy
                state.dirty = true
            }
            return result
        }
    }

    /// Writes a pending change now. Returns true when it wrote.
    @discardableResult
    public func flush() throws -> Bool {
        try state.withLock { state in
            guard state.dirty else { return false }
            let data = try DocumentStore.encode(state.document)
            try AtomicFile.write(data, to: fileURL)
            state.dirty = false
            state.writeCount += 1
            return true
        }
    }

    static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func moveAside(suffix: String) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: now())
        let base = fileURL.deletingLastPathComponent()
        var target = base.appending(path: "\(fileURL.lastPathComponent).\(suffix)-\(stamp)", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            target = base.appending(
                path: "\(fileURL.lastPathComponent).\(suffix)-\(stamp)-\(UUID().uuidString.prefix(8))",
                directoryHint: .notDirectory
            )
        }
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }
}
