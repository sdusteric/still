import Foundation
@testable import SnapCore
import Testing

@Suite struct VisionTextRecognizerTests {
    private func image(_ lines: [String], width: Int = 1600, height: Int = 400, fontSize: CGFloat = 36) throws -> (URL, URL) {
        let home = try RecallTestSupport.makeHome()
        let url = home.appending(path: "text.png")
        try SyntheticText.png(lines: lines, size: CGSize(width: width, height: height), fontSize: fontSize).write(to: url)
        return (home, url)
    }

    private func words(_ result: OCRResult) -> Set<String> {
        Set(result.lines.flatMap { $0.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) })
    }

    @Test func recognizesEnglishLines() async throws {
        let (home, url) = try image(["Quarterly Stripe error 4402", "card declined"])
        defer { RecallTestSupport.remove(home) }
        let result = try await VisionTextRecognizer().recognize(imageAt: url)
        #expect(words(result).isSuperset(of: ["quarterly", "stripe", "error", "4402", "card", "declined"]))
        #expect(result.imageName == "text.png")
        #expect(result.lines.allSatisfy { $0.box.count == 4 && $0.box.allSatisfy { (0...1).contains($0) } })
    }

    @Test func recognizesChineseLine() async throws {
        let (home, url) = try image(["截图里的错误信息"], width: 900, height: 200, fontSize: 48)
        defer { RecallTestSupport.remove(home) }
        let result = try await VisionTextRecognizer().recognize(imageAt: url)
        #expect(result.lines.map(\.text).joined().contains("错误"))
    }

    @Test func dropsShortAndLowConfidence() {
        let lines = [
            OCRResult.Line(text: "a", confidence: 0.9, box: [0, 0, 0.1, 0.1]),
            OCRResult.Line(text: "faint words", confidence: 0.2, box: [0, 0, 0.1, 0.1]),
            OCRResult.Line(text: "kept line", confidence: 0.8, box: [0, 0, 0.1, 0.1]),
        ]
        #expect(VisionTextRecognizer.keep(lines).map(\.text) == ["kept line"])
    }

    @Test func fullDisplayTiming() async throws {
        let lines = (1...40).map { "Line \($0): release notes for Snap and Shelf, build \($0 * 37)" }
        let (home, url) = try image(lines, width: 5120, height: 2880, fontSize: 40)
        defer { RecallTestSupport.remove(home) }
        let start = ContinuousClock.now
        let result = try await VisionTextRecognizer().recognize(imageAt: url)
        let elapsed = ContinuousClock.now - start
        print("ocr 5120x2880 40 lines: \(elapsed), \(result.lines.count) lines")
        #expect(elapsed < .seconds(5))
        #expect(result.lines.count >= 30)
    }
}

@Suite struct OCRStoreTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    @Test func ocrStoreRoundTrip() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let history = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock())
        let item = try history.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        let store = OCRStore(history: history)
        let result = OCRResult(imageName: "a.png", language: "en-US", lines: [.init(text: "hello there", confidence: 1, box: [0, 0, 1, 1])])
        try store.save(result, id: item.id)
        #expect(store.load(id: item.id) == result)
        try store.discard(id: item.id)
        #expect(store.load(id: item.id) == nil)
    }

    @Test func ocrStoreIgnoresStaleImageName() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let history = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock())
        let item = try history.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        let store = OCRStore(history: history)
        try store.save(OCRResult(imageName: "a.png", language: nil, lines: []), id: item.id)
        _ = try history.saveEdited(id: item.id, pngData: png)
        #expect(store.load(id: item.id) == nil)
    }
}
