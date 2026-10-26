import Foundation

/// Reads the text in an image on this Mac. Vision in the app; a fake in tests.
public protocol TextRecognizer: Sendable {
    func recognize(imageAt url: URL) async throws -> OCRResult
}

/// What OCR found in one capture, cached as `history/<id>/ocr.json` so a rebuild of the recall
/// folder needs no second OCR. It keeps the raw text; only the Recall entry is filtered.
public struct OCRResult: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var text: String
        public var confidence: Float
        /// Normalized `[x, y, w, h]` from the top left.
        public var box: [Double]

        public init(text: String, confidence: Float, box: [Double]) {
            self.text = text
            self.confidence = confidence
            self.box = box
        }
    }

    public var version = 1
    /// The image the text was read from: the original or the edited PNG.
    public var imageName: String
    public var language: String?
    public var lines: [Line]

    public init(imageName: String, language: String?, lines: [Line]) {
        self.imageName = imageName
        self.language = language
        self.lines = lines
    }
}
