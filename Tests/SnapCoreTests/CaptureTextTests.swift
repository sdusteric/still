import Foundation
@testable import SnapCore
import Testing

@Suite struct CaptureTextTests {
    @Test func linesJoinInReadingOrder() {
        let result = OCRResult(imageName: "Snap.png", language: "en-US", lines: [
            .init(text: "Hello", confidence: 0.9, box: [0, 0, 1, 0.1]),
            .init(text: "  ", confidence: 0.9, box: [0, 0.2, 1, 0.1]),
            .init(text: "world", confidence: 0.9, box: [0, 0.4, 1, 0.1]),
        ])
        #expect(CaptureText.text(result) == "Hello\nworld")
        #expect(CaptureText.text(OCRResult(imageName: "Snap.png", language: nil, lines: [])) == nil)
    }

    @Test func aCachedResultIsUsedWithoutOCR() async throws {
        let rig = try await IndexerRig(results: ["Snap.png": ["fresh"]])
        defer { RecallTestSupport.remove(rig.home) }
        let item = try rig.add("Snap.png")
        let cached = OCRResult(imageName: item.currentURL.lastPathComponent, language: "en-US", lines: [.init(text: "cached", confidence: 0.9, box: [0, 0, 1, 1])])
        try rig.ocr.save(cached, id: item.id)

        let text = try await CaptureText.read(item, ocr: rig.ocr, recognizer: rig.recognizer)
        #expect(text == "cached")
        #expect(rig.recognizer.calls.isEmpty)
    }

    @Test func withoutACacheItReadsTheImageOnceAndKeepsTheResult() async throws {
        let rig = try await IndexerRig(results: ["Snap.png": ["Line one", "Line two"]])
        defer { RecallTestSupport.remove(rig.home) }
        let item = try rig.add("Snap.png")

        #expect(try await CaptureText.read(item, ocr: rig.ocr, recognizer: rig.recognizer) == "Line one\nLine two")
        #expect(try await CaptureText.read(item, ocr: rig.ocr, recognizer: rig.recognizer) == "Line one\nLine two")
        #expect(rig.recognizer.calls.count == 1)
        #expect(rig.ocr.load(id: item.id)?.lines.count == 2)
    }

    @Test func theSearchIndexKeepsFoundTextAndRereadsAnEditedCapture() async throws {
        let rig = try await IndexerRig()
        defer { RecallTestSupport.remove(rig.home) }
        var item = try rig.add("Snap.png")
        let index = CaptureTextIndex()
        #expect(index.texts(for: [item], ocr: rig.ocr).isEmpty, "no OCR yet")

        let name = item.currentURL.lastPathComponent
        try rig.ocr.save(OCRResult(imageName: name, language: nil, lines: [.init(text: "Invoice", confidence: 0.9, box: [0, 0, 1, 1])]), id: item.id)
        #expect(index.texts(for: [item], ocr: rig.ocr) == [item.id: "invoice"], "OCR that finished later is picked up")

        try rig.ocr.discard(id: item.id)
        #expect(index.texts(for: [item], ocr: rig.ocr) == [item.id: "invoice"], "an unchanged capture is not read again")

        item.editedURL = item.originalURL.deletingLastPathComponent().appending(path: "Snap (edited).png")
        #expect(index.texts(for: [item], ocr: rig.ocr).isEmpty, "an edited capture needs its own OCR")
    }

    @Test func aRecordingHasNoText() async throws {
        let rig = try await IndexerRig()
        defer { RecallTestSupport.remove(rig.home) }
        let video = CaptureItem(id: "v", createdAt: IndexerRig.now, mode: .area, scale: 2, originalURL: rig.home.appending(path: "v.mp4"), kind: .video)
        #expect(try await CaptureText.read(video, ocr: rig.ocr, recognizer: rig.recognizer) == nil)
        #expect(rig.recognizer.calls.isEmpty)
    }
}
