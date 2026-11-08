import Foundation

/// `history/<id>/ocr.json`. It lives and dies with its history item.
public struct OCRStore: Sendable {
    public static let fileName = "ocr.json"
    private let history: HistoryStore

    public init(history: HistoryStore) {
        self.history = history
    }

    /// Nil when there is none, it does not decode, or it was read from an image that is no longer
    /// the item's current one (the capture was edited since).
    public func load(id: String) -> OCRResult? {
        let url = fileURL(id)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        let result: OCRResult
        let item: CaptureItem?
        do {
            result = try JSONDecoder().decode(OCRResult.self, from: data)
            item = try history.item(id: id)
        } catch {
            return nil
        }
        guard let item, item.currentURL.lastPathComponent == result.imageName else { return nil }
        return result
    }

    /// `load(id:)` for a caller that already holds the item: skips reading `item.json` again.
    public func load(id: String, currentImageName: String) -> OCRResult? {
        let url = fileURL(id)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            let result = try JSONDecoder().decode(OCRResult.self, from: data)
            return result.imageName == currentImageName ? result : nil
        } catch {
            return nil
        }
    }

    public func save(_ result: OCRResult, id: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try ShelfStatusWriter.writeAtomically(try encoder.encode(result), to: fileURL(id))
    }

    public func discard(id: String) throws {
        let path = fileURL(id).path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    private func fileURL(_ id: String) -> URL {
        history.folder(for: id).appending(path: Self.fileName, directoryHint: .notDirectory)
    }
}
