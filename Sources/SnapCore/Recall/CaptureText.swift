import Foundation
import Synchronization

/// "Copy Text": the text in one screenshot, from the cached `ocr.json` when it still matches the
/// current image, else read now with the recognizer and cached for next time.
public enum CaptureText {
    /// What a Copy Text did, for the note on the card or the chip near the pointer.
    public enum Outcome: Sendable, Hashable {
        case copied, noText, failed

        public var message: String {
            switch self {
            case .copied: "Text copied"
            case .noText: "No text found"
            case .failed: "Could not read the text"
            }
        }
    }

    /// The non-empty lines, one per line, in Vision's reading order. Nil when nothing was read.
    public static func text(_ result: OCRResult) -> String? {
        let lines = result.lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Nil for a recording or an image with no text.
    public static func read(_ item: CaptureItem, ocr: OCRStore, recognizer: any TextRecognizer) async throws -> String? {
        guard item.kind == .image else { return nil }
        if let cached = ocr.load(id: item.id, currentImageName: item.currentURL.lastPathComponent) {
            return text(cached)
        }
        let result = try await recognizer.recognize(imageAt: item.currentURL)
        // The cache only saves a second OCR; failing to write it does not fail the copy.
        do {
            try ocr.save(result, id: item.id)
        } catch {
            return text(result)
        }
        return text(result)
    }
}

/// History search text by capture, kept across reloads so a reload reads only the `ocr.json` of
/// captures it has no text for yet (or whose image changed since). Only found text is kept, so a
/// capture whose OCR finishes later is picked up by the next reload.
public final class CaptureTextIndex: Sendable {
    private struct Entry: Sendable {
        var imageName: String
        var folded: String
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    /// The folded text of each screenshot in `items` that has any, by id.
    public func texts(for items: [CaptureItem], ocr: OCRStore) -> [String: String] {
        var known = entries.withLock { $0 }
        var result: [String: String] = [:]
        var fresh: [String: Entry] = [:]
        for item in items where item.kind == .image {
            let name = item.currentURL.lastPathComponent
            if let entry = known[item.id], entry.imageName == name {
                result[item.id] = entry.folded
                fresh[item.id] = entry
                continue
            }
            guard let read = ocr.load(id: item.id, currentImageName: name), let text = CaptureText.text(read) else { continue }
            let entry = Entry(imageName: name, folded: HistoryQuery.foldText(text))
            result[item.id] = entry.folded
            fresh[item.id] = entry
        }
        known = fresh
        entries.withLock { $0 = known }
        return result
    }
}
