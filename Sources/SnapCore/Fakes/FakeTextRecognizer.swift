import Foundation
import Synchronization

/// Scripted OCR for tests: results by image file name, an optional delay, and the calls made.
public final class FakeTextRecognizer: TextRecognizer {
    private let results: [String: OCRResult]
    private let delay: Duration
    private let log = Mutex<[URL]>([])

    public init(results: [String: OCRResult] = [:], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    public var calls: [URL] { log.withLock { $0 } }

    public func recognize(imageAt url: URL) async throws -> OCRResult {
        log.withLock { $0.append(url) }
        if delay > .zero { try await Task.sleep(for: delay) }
        var result = results[url.lastPathComponent] ?? OCRResult(imageName: url.lastPathComponent, language: nil, lines: [])
        result.imageName = url.lastPathComponent
        return result
    }
}
