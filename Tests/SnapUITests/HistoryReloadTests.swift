import Foundation
import SnapCore
@testable import SnapUI
import Synchronization
import Testing

/// A loader whose calls wait until the test hands each one a snapshot.
actor GatedHistoryLoader {
    private var waiting: [CheckedContinuation<HistorySnapshot, Never>] = []
    private(set) var calls = 0

    func load() async -> HistorySnapshot {
        calls += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    var pending: Int { waiting.count }

    func release(_ snapshot: HistorySnapshot) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: snapshot)
    }
}

@MainActor
final class StampBox {
    var date = Date(timeIntervalSince1970: 1)
}

/// Waits up to two seconds on the calling thread; false on a timeout.
nonisolated func waitBlocking(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now() + 2) == .success
}

/// Polls `condition` for up to two seconds.
@MainActor
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

extension HistoryWindowModelTests {
    func snapshot(_ ids: [String]) -> HistorySnapshot {
        HistorySnapshot(items: ids.enumerated().map { item($1, hoursAgo: Double($0)) }, totalBytes: 1024)
    }

    func makeModel(load: @escaping @Sendable () async throws -> HistorySnapshot, stamp: @escaping @MainActor () -> Date? = { nil }) -> HistoryWindowModel {
        let now = now
        let utc = utc
        return HistoryWindowModel(
            load: load,
            context: { HistoryDateContext(now: now, calendar: Calendar(identifier: .gregorian), timeZone: utc) },
            changeStamp: stamp
        )
    }

    @Test func reloadReadsTheFolderOffTheMainThread() async {
        // The loader waits for a signal the test sends only after reload() returns, so a loader
        // run on the main thread inside reload() would time out instead of loading.
        let signal = DispatchSemaphore(value: 0)
        let timedOut = Mutex(false)
        let ready = snapshot(["a", "b"])
        let model = makeModel(load: {
            if !waitBlocking(signal) { timedOut.withLock { $0 = true } }
            return ready
        })
        let task = model.reload()
        #expect(model.isLoading)
        signal.signal()
        await task.value
        #expect(!timedOut.withLock { $0 })
        #expect(model.orderedIDs == ["a", "b"])
        #expect(!model.isLoading)
    }

    @Test func thePreviousItemsStayWhileAReloadRuns() async {
        let gate = GatedHistoryLoader()
        let model = makeModel(load: { await gate.load() })
        let first = model.reload()
        #expect(await eventually { await gate.pending == 1 })
        await gate.release(snapshot(["a", "b"]))
        await first.value

        let second = model.reload()
        #expect(await eventually { await gate.pending == 1 })
        #expect(model.orderedIDs == ["a", "b"])
        #expect(model.content == .grid)
        await gate.release(snapshot(["c", "a", "b"]))
        await second.value
        #expect(model.orderedIDs == ["c", "a", "b"])
    }

    @Test func overlappingReloadsCoalesceAndTheLatestWins() async {
        let gate = GatedHistoryLoader()
        let model = makeModel(load: { await gate.load() })
        let task = model.reload()
        #expect(await eventually { await gate.pending == 1 })
        model.reload()
        model.reload()
        model.reload()
        // The first load finishes after newer reloads asked: its result is dropped.
        await gate.release(snapshot(["old"]))
        #expect(await eventually { await gate.pending == 1 })
        #expect(model.items.isEmpty)
        await gate.release(snapshot(["new", "old"]))
        await task.value
        #expect(model.orderedIDs == ["new", "old"])
        #expect(await gate.calls == 2)
    }

    @Test func becomingKeyWithNothingChangedSkipsTheReload() async {
        let calls = Mutex(0)
        let ready = snapshot(["a"])
        let stamp = StampBox()
        let model = makeModel(load: {
            calls.withLock { $0 += 1 }
            return ready
        }, stamp: { stamp.date })

        await model.reloadIfNeeded()?.value
        #expect(calls.withLock { $0 } == 1)
        #expect(model.reloadIfNeeded() == nil)
        #expect(model.reloadIfNeeded() == nil)
        #expect(calls.withLock { $0 } == 1)

        model.markStale()
        await model.reloadIfNeeded()?.value
        #expect(calls.withLock { $0 } == 2)

        stamp.date = Date(timeIntervalSince1970: 2)
        await model.reloadIfNeeded()?.value
        #expect(calls.withLock { $0 } == 3)
        #expect(model.reloadIfNeeded() == nil)
    }

    @Test func nothingShowsUntilTheFirstLoadArrives() async {
        let gate = GatedHistoryLoader()
        let model = makeModel(load: { await gate.load() })
        #expect(model.content == .loading)
        #expect(model.footerParts.isEmpty)
        let task = model.reload()
        #expect(await eventually { await gate.pending == 1 })
        #expect(model.content == .loading)
        await gate.release(HistorySnapshot(items: [], totalBytes: 0))
        await task.value
        #expect(model.content == .empty)
        #expect(model.footerParts.first == "0 captures")
    }

    @Test func revealDuringALoadSelectsTheCaptureWhenItArrives() async {
        let gate = GatedHistoryLoader()
        let model = makeModel(load: { await gate.load() })
        let task = model.reload()
        model.reveal("b")
        #expect(await eventually { await gate.pending == 1 })
        await gate.release(snapshot(["a", "b"]))
        await task.value
        #expect(model.selection == ["b"])
        #expect(model.scrollTarget == "b")
    }

    @Test func searchFindsTheTextInACapture() async {
        let items = [item("a", hoursAgo: 1), item("b", hoursAgo: 2, app: "Safari")]
        let texts = ["b": HistoryQuery.foldText("Order confirmation 88213")]
        let model = makeModel(load: { HistorySnapshot(items: items, totalBytes: 0, texts: texts) })
        await model.reload().value
        model.searchText = "confirmation"
        #expect(model.orderedIDs == ["b"])
        model.searchText = "88213 safari"
        #expect(model.orderedIDs == ["b"])
    }

    @Test func copyTextIsForScreenshotsAndCopiesTheSelection() async {
        let model = await makeModel()
        model.select("a")
        model.select("b", mode: .toggle)
        #expect(model.isEnabled(.copyText))
        model.perform(.copyText)
        #expect(log.calls == ["copy text a,b"])
        model.select("c")
        #expect(!model.isEnabled(.copyText), "a recording has no text")
    }

    @Test func sectionsAreBuiltOncePerChange() async {
        let model = await makeModel()
        let builds = model.derivedBuilds
        for _ in 0..<5 {
            _ = model.content
            _ = model.sections
            _ = model.orderedIDs
            _ = model.canPin
            _ = model.canCopy
            _ = model.canShowInQuickAccess
        }
        #expect(model.derivedBuilds == builds)
        model.searchText = "safari"
        _ = model.sections
        _ = model.orderedIDs
        #expect(model.derivedBuilds == builds + 1)
        #expect(model.orderedIDs == ["b", "f"])
    }
}

@MainActor
@Suite struct ThumbnailCacheTests {
    func writePNG(width: Int, to url: URL) throws {
        let image = try #require(SyntheticImages.solid(width: width, height: 20, color: .init(red: 200, green: 40, blue: 40)))
        try PNGWriter.write(image, scale: 1, to: url)
    }

    @Test func aCachedThumbnailIsAnsweredFromMemoryAndAnEditMakesANewOne() async throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: "snap-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "Snap.png")
        try writePNG(width: 40, to: url)

        let cache = ThumbnailCache(maxPixelSize: 400)
        #expect(cache.cachedThumbnail(for: url) == nil)
        let first = try #require(await cache.thumbnail(for: url))
        #expect(first.width == 40)
        #expect(cache.cachedThumbnail(for: url)?.width == 40)

        // The tile body asks on every pass; that lookup must not touch the file.
        try FileManager.default.removeItem(at: url)
        #expect(cache.cachedThumbnail(for: url)?.width == 40)
        #expect(await cache.thumbnail(for: url) == nil)

        try writePNG(width: 60, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path(percentEncoded: false))
        let edited = try #require(await cache.thumbnail(for: url))
        #expect(edited.width == 60)
        #expect(cache.cachedThumbnail(for: url)?.width == 60)
    }
}
