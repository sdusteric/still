import Foundation
import Vision

/// Vision text recognition (Recall design 7.2). Offline, and it needs no permission.
public struct VisionTextRecognizer: TextRecognizer {
    static let languages = ["en-US", "zh-Hans", "zh-Hant"]
    static let minimumConfidence: Float = 0.3
    static let minimumLength = 2

    public init() {}

    public func recognize(imageAt url: URL) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = Self.languages.map { Locale.Language(identifier: $0) }
        let observations = try await request.perform(on: url)
        let lines = observations.compactMap { observation -> OCRResult.Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let rect = observation.boundingBox.cgRect
            // Vision's origin is the bottom left; entries use the top left.
            return OCRResult.Line(
                text: candidate.string, confidence: candidate.confidence,
                box: [rect.minX, 1 - rect.maxY, rect.width, rect.height].map { min(1, max(0, $0)) }
            )
        }
        let kept = Self.keep(lines)
        return OCRResult(imageName: url.lastPathComponent, language: Self.dominantLanguage(kept), lines: kept)
    }

    /// Drops lines under 2 characters and lines Vision is not sure of.
    static func keep(_ lines: [OCRResult.Line]) -> [OCRResult.Line] {
        lines.filter {
            $0.text.trimmingCharacters(in: .whitespaces).count >= minimumLength && $0.confidence >= minimumConfidence
        }
    }

    static func dominantLanguage(_ lines: [OCRResult.Line]) -> String? {
        let text = lines.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return han * 2 > text.count ? "zh-Hans" : "en-US"
    }
}
