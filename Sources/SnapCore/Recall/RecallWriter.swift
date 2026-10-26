import Foundation

/// Writes and removes Recall entry files and their previews in Snap's recall folder. The folder is
/// 0700 and every file 0600, written as the status file is (temp file, fsync, rename).
public struct RecallWriter: Sendable {
    public enum WriteError: Error, Equatable {
        case tooLarge
    }

    public static let maxEntryBytes = 4 * 1024 * 1024
    public static let maxPreviewBytes = 80 * 1024
    public static let previewLongSide = 480

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// Writes the preview first, so an entry never names a file that is not there yet.
    public func write(_ entry: RecallEntry, previewFrom imageURL: URL?) throws {
        try prepareDirectory()
        var entry = entry
        entry.preview = nil
        if let imageURL,
           let data = ShelfStatusWriter.previewData(for: imageURL, maxPixels: Self.previewLongSide, maxBytes: Self.maxPreviewBytes) {
            try ShelfStatusWriter.writeAtomically(data, to: previewURL(entry.id))
            entry.preview = previewURL(entry.id).lastPathComponent
        } else {
            try removeIfPresent(previewURL(entry.id))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        guard data.count <= Self.maxEntryBytes else {
            try removeIfPresent(previewURL(entry.id))
            throw WriteError.tooLarge
        }
        try ShelfStatusWriter.writeAtomically(data, to: entryURL(entry.id))
    }

    public func remove(id: String) throws {
        try removeIfPresent(entryURL(id))
        try removeIfPresent(previewURL(id))
    }

    /// Everything this writer wrote; the rest of the recall folder is left alone.
    public func removeAll() throws {
        for name in try names() where name.hasSuffix(".json") || name.hasSuffix(".jpg") || name.hasSuffix(".tmp") {
            try removeIfPresent(directory.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// Deletes every preview and rewrites each entry without its `preview` field.
    public func removePreviews() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for id in try storedIDs() {
            try removeIfPresent(previewURL(id))
            guard let data = FileManager.default.contents(atPath: entryURL(id).path(percentEncoded: false)),
                  var entry = try? decoder.decode(RecallEntry.self, from: data), entry.preview != nil else { continue }
            entry.preview = nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try ShelfStatusWriter.writeAtomically(try encoder.encode(entry), to: entryURL(id))
        }
    }

    public func storedIDs() throws -> Set<String> {
        Set(try names().filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) })
    }

    func entryURL(_ id: String) -> URL { directory.appending(path: "\(id).json", directoryHint: .notDirectory) }
    func previewURL(_ id: String) -> URL { directory.appending(path: "\(id).jpg", directoryHint: .notDirectory) }

    private func names() throws -> [String] {
        let path = directory.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
    }

    private func removeIfPresent(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
