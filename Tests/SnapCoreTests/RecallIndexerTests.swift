import Foundation
@testable import SnapCore
import Synchronization
import Testing

final class PendingLog: Sendable {
    let values = Mutex<[Int]>([])
}

final class IndexerRig: Sendable {
    let home: URL
    let history: HistoryStore
    let writer: RecallWriter
    let ocr: OCRStore
    let recognizer: FakeTextRecognizer
    let indexer: RecallIndexer
    let pendingSeen = PendingLog()
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    init(results: [String: [String]] = [:], delay: Duration = .zero, options: RecallOptions = RecallOptions(enabled: true, previews: false, excludedApps: GeneralSettings.defaultExcludedApps)) async throws {
        home = try RecallTestSupport.makeHome()
        history = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock(startDate: Self.now))
        writer = RecallWriter(directory: SnapPaths(home: home).recallDirectory)
        ocr = OCRStore(history: history)
        recognizer = FakeTextRecognizer(
            results: results.mapValues { lines in
                OCRResult(imageName: "", language: "en-US", lines: lines.map { .init(text: $0, confidence: 0.9, box: [0, 0, 1, 1]) })
            },
            delay: delay)
        indexer = RecallIndexer(history: history, ocr: ocr, recognizer: recognizer, writer: writer, options: options, log: nil)
        let seen = pendingSeen
        await indexer.setOnPendingChange { value in seen.values.withLock { $0.append(value) } }
    }

    func add(_ name: String, app: String? = "Notes", daysAgo: Double = 0) throws -> CaptureItem {
        try history.add(pngData: Self.png, fileName: name, mode: .area, scale: 2, sourceApp: app, createdAt: Self.now.addingTimeInterval(-daysAgo * 86_400))
    }

    func entry(_ id: String) throws -> RecallEntry? {
        let url = writer.directory.appending(path: "\(id).json")
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecallEntry.self, from: data)
    }

    func text(_ id: String) throws -> [String]? { try entry(id)?.segments.map(\.text) }

    func waitForCalls(_ count: Int) async {
        let deadline = Date().addingTimeInterval(3)
        while recognizer.calls.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    deinit { RecallTestSupport.remove(home) }
}

@Suite struct RecallIndexerTests {
    @Test func storedScreenshotGetsEntry() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["Quarterly Stripe error 4402"]])
        let item = try rig.add("a.png")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        let entry = try #require(try rig.entry(item.id))
        #expect(entry.segments.map(\.text) == ["Quarterly Stripe error 4402"])
        #expect(entry.title == "Notes")
        #expect(entry.context == ["source_app": "Notes"])
        #expect(entry.createdAt == IndexerRig.now)
    }

    @Test func secretIsHiddenInEntry() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["key sk_live_51HxQe2LkS8vA0bC9dEfGh12"]])
        let item = try rig.add("a.png")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        #expect(try rig.text(item.id) == ["key [hidden]"])
        #expect(rig.ocr.load(id: item.id)?.lines.first?.text == "key sk_live_51HxQe2LkS8vA0bC9dEfGh12")
    }

    @Test func recordingsAreSkipped() async throws {
        let rig = try await IndexerRig()
        let video = try rig.history.add(video: NewVideo(fileName: "v.mp4", mode: .fullscreen, scale: 2))
        await rig.indexer.enqueue(video.id)
        await rig.indexer.drain()
        #expect(try rig.entry(video.id) == nil)
        #expect(rig.recognizer.calls.isEmpty)
    }

    @Test func excludedAppIsSkipped() async throws {
        let rig = try await IndexerRig()
        let item = try rig.add("a.png", app: "1Password")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        #expect(try rig.entry(item.id) == nil)
        #expect(rig.recognizer.calls.isEmpty)
    }

    @Test func addingExclusionRemovesEntries() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["hello there"]])
        let item = try rig.add("a.png", app: "Slack")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        #expect(try rig.entry(item.id) != nil)
        await rig.indexer.update(options: RecallOptions(enabled: true, previews: false, excludedApps: ["Slack"]))
        await rig.indexer.drain()
        #expect(try rig.entry(item.id) == nil)
    }

    @Test func editRereadsCurrentImage() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["first"], "a (edited).png": ["second"]])
        let item = try rig.add("a.png")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        _ = try rig.history.saveEdited(id: item.id, pngData: IndexerRig.png)
        await rig.indexer.enqueue(item.id, force: true)
        await rig.indexer.drain()
        #expect(rig.recognizer.calls.last?.lastPathComponent == "a (edited).png")
        #expect(try rig.text(item.id) == ["second"])
    }

    @Test func latestEditWins() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["first"], "a (edited).png": ["second"]], delay: .milliseconds(150))
        let item = try rig.add("a.png")
        await rig.indexer.enqueue(item.id)
        await rig.waitForCalls(1)
        _ = try rig.history.saveEdited(id: item.id, pngData: IndexerRig.png)
        await rig.indexer.enqueue(item.id, force: true)
        await rig.indexer.drain()
        #expect(try rig.text(item.id) == ["second"])
    }

    @Test func removeDuringOCRWritesNothing() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["text"]], delay: .milliseconds(150))
        let item = try rig.add("a.png")
        await rig.indexer.enqueue(item.id)
        await rig.waitForCalls(1)
        await rig.indexer.remove([item.id])
        await rig.indexer.drain()
        #expect(try rig.entry(item.id) == nil)
        #expect(try rig.writer.storedIDs().isEmpty)
    }

    @Test func textlessScreenshotGetsEmptyEntry() async throws {
        let rig = try await IndexerRig()
        let item = try rig.add("photo.png")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        #expect(try rig.text(item.id) == [])
        #expect(rig.ocr.load(id: item.id) != nil)
        await rig.indexer.reconcile()
        await rig.indexer.drain()
        #expect(rig.recognizer.calls.count == 1)
    }

    @Test func reconcileUsesCachedOCR() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["one"], "b.png": ["two"]])
        let a = try rig.add("a.png", daysAgo: 1)
        let b = try rig.add("b.png")
        await rig.indexer.reconcile()
        await rig.indexer.drain()
        #expect(rig.recognizer.calls.count == 2)
        try FileManager.default.removeItem(at: rig.writer.directory)
        await rig.indexer.reconcile()
        await rig.indexer.drain()
        #expect(rig.recognizer.calls.count == 2)
        #expect(try rig.text(a.id) == ["one"])
        #expect(try rig.text(b.id) == ["two"])
    }

    @Test func reconcileRemovesOrphans() async throws {
        let rig = try await IndexerRig()
        try rig.writer.write(RecallTestSupport.entry("20200101-000000-deadbeef"), previewFrom: nil)
        await rig.indexer.reconcile()
        await rig.indexer.drain()
        #expect(try rig.writer.storedIDs().isEmpty)
    }

    @Test func turningOffDeletesEverything() async throws {
        let rig = try await IndexerRig(results: ["a.png": ["x"]])
        let item = try rig.add("a.png")
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        await rig.indexer.update(options: RecallOptions(enabled: false, previews: false, excludedApps: []))
        await rig.indexer.drain()
        #expect(try rig.writer.storedIDs().isEmpty)
        #expect(rig.ocr.load(id: item.id) != nil)
        await rig.indexer.enqueue(item.id)
        await rig.indexer.drain()
        #expect(try rig.writer.storedIDs().isEmpty)
    }

    @Test func backfillIsNewestFirst() async throws {
        let rig = try await IndexerRig()
        _ = try rig.add("old.png", daysAgo: 3)
        _ = try rig.add("new.png", daysAgo: 0)
        _ = try rig.add("mid.png", daysAgo: 1)
        await rig.indexer.reconcile()
        await rig.indexer.drain()
        #expect(rig.recognizer.calls.map(\.lastPathComponent) == ["new.png", "mid.png", "old.png"])
    }

    @Test func pendingCountReported() async throws {
        let rig = try await IndexerRig(delay: .milliseconds(20))
        let first = try rig.add("a.png")
        let second = try rig.add("b.png")
        await rig.indexer.enqueue(first.id)
        await rig.indexer.enqueue(second.id)
        await rig.indexer.drain()
        let seen = rig.pendingSeen.values.withLock { $0 }
        #expect(seen.contains(2))
        #expect(seen.last == 0)
        #expect(await rig.indexer.pending == 0)
    }
}
