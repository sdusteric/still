import Foundation
import SnapCore
import Testing

private final class HistoryScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "history-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A leftover scratch dir inside a temp dir is harmless.
        }
    }

    var history: URL { url.appending(path: "history", directoryHint: .isDirectory) }
}

@Suite struct HistoryStoreTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private func makeStore(_ scratch: HistoryScratch, clock: FakeClock = FakeClock()) -> HistoryStore {
        HistoryStore(directory: scratch.history, clock: clock)
    }

    @Test func addWritesThePNGAndItemJSONIntoTheItemFolder() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let item = try store.add(
            pngData: png, fileName: "Snap 2026-10-24 at 14.03.22.png", mode: .area, scale: 2, sourceApp: "Notes"
        )
        let folder = scratch.history.appending(path: item.id, directoryHint: .isDirectory)
        #expect(item.originalURL == folder.appending(path: "Snap 2026-10-24 at 14.03.22.png", directoryHint: .notDirectory))
        #expect(try Data(contentsOf: item.originalURL) == png)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "item.json").path(percentEncoded: false)))
        #expect(item.editedURL == nil)
        #expect(item.currentURL == item.originalURL)
        #expect(item.sourceApp == "Notes")
        #expect(item.scale == 2)
    }

    @Test func itemRoundTripsThroughItemJSON() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let created = Date(timeIntervalSince1970: 1_792_850_000)
        let added = try store.add(
            pngData: png, fileName: "a.png", mode: .window, scale: 1, createdAt: created, id: "20261024-140322-aaaaaaaa"
        )
        let loaded = try store.item(id: added.id)
        #expect(loaded == added)
        #expect(loaded?.mode == .window)
        #expect(loaded?.createdAt == created)
        #expect(try store.item(id: "missing") == nil)
    }

    @Test func noTempFilesRemainAfterWrites() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        _ = try store.saveEdited(id: item.id, pngData: png)
        let folder = scratch.history.appending(path: item.id, directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(names == ["a (edited).png", "a.png", "item.json"])
    }

    @Test func editedVersionSitsNextToTheOriginalAndBecomesCurrent() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let item = try store.add(pngData: png, fileName: "Shot.png", mode: .area, scale: 2)
        let edited = Data([9, 9, 9])
        let updated = try store.saveEdited(id: item.id, pngData: edited)
        #expect(updated.editedURL?.lastPathComponent == "Shot (edited).png")
        #expect(updated.currentURL == updated.editedURL)
        #expect(try Data(contentsOf: item.originalURL) == png)
        #expect(try updated.editedURL.map { try Data(contentsOf: $0) } == edited)

        let again = try store.saveEdited(id: item.id, pngData: Data([7]))
        #expect(try again.editedURL.map { try Data(contentsOf: $0) } == Data([7]))
        #expect(try store.item(id: item.id)?.editedURL == again.editedURL)
    }

    @Test func savingAnEditForAnUnknownItemThrows() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        #expect(throws: HistoryError.itemNotFound("nope")) {
            try store.saveEdited(id: "nope", pngData: png)
        }
    }

    @Test func fileNamesWithPathCharactersAreRejected() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        for name in ["", "a/b.png", "a:b.png", ".hidden.png", "item.json"] {
            #expect(throws: HistoryError.invalidFileName(name)) {
                try store.add(pngData: png, fileName: name, mode: .area, scale: 1)
            }
        }
    }

    @Test func recentListsTheNewestFirstAndHonoursTheLimit() throws {
        let scratch = try HistoryScratch()
        let clock = FakeClock()
        let store = makeStore(scratch, clock: clock)
        var ids: [String] = []
        for index in 0..<5 {
            let item = try store.add(pngData: png, fileName: "s\(index).png", mode: .fullscreen, scale: 2)
            ids.append(item.id)
            clock.advance(by: 60)
        }
        let last3 = try store.recent(limit: 3)
        #expect(last3.map(\.id) == [ids[4], ids[3], ids[2]])
        #expect(try store.recent(limit: 0).isEmpty)
        #expect(try store.allItems().count == 5)
    }

    @Test func recentOnAMissingHistoryFolderIsEmpty() throws {
        let scratch = try HistoryScratch()
        #expect(try makeStore(scratch).recent(limit: 3).isEmpty)
    }

    @Test func aCorruptItemJSONIsSkippedNotFatal() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let good = try store.add(pngData: png, fileName: "good.png", mode: .area, scale: 2)
        let badFolder = scratch.history.appending(path: "bad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: badFolder.appending(path: "item.json"))
        #expect(try store.recent(limit: 10).map(\.id) == [good.id])
    }

    @Test func sweepRemovesItemsOlderThanThreeDaysOnly() throws {
        let scratch = try HistoryScratch()
        let clock = FakeClock()
        let store = makeStore(scratch, clock: clock)
        let day: TimeInterval = 86_400

        let old = try store.add(pngData: png, fileName: "old.png", mode: .area, scale: 2)
        clock.advance(by: 2 * day)
        let middle = try store.add(pngData: png, fileName: "middle.png", mode: .area, scale: 2)
        clock.advance(by: 1.5 * day)
        let fresh = try store.add(pngData: png, fileName: "fresh.png", mode: .area, scale: 2)

        // old is now 3.5 days old, middle 1.5 days, fresh 0.
        let removed = try store.sweep()
        #expect(removed == [old.id])
        #expect(try store.recent(limit: 10).map(\.id).sorted() == [middle.id, fresh.id].sorted())
        #expect(FileManager.default.fileExists(atPath: old.originalURL.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: middle.originalURL.path(percentEncoded: false)))
    }

    @Test func sweepKeepsAnItemJustInsideTheRetention() throws {
        let scratch = try HistoryScratch()
        let clock = FakeClock()
        let store = makeStore(scratch, clock: clock)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 1)
        clock.advance(by: HistoryStore.retention - 1)
        #expect(try store.sweep().isEmpty)
        clock.advance(by: 2)
        #expect(try store.sweep() == [item.id])
    }

    @Test func sweepOnAMissingFolderDoesNothing() throws {
        let scratch = try HistoryScratch()
        #expect(try makeStore(scratch).sweep().isEmpty)
    }

    @Test func sweepJudgesAFolderWithoutItemJSONByItsModificationDate() throws {
        let scratch = try HistoryScratch()
        let clock = FakeClock(startDate: Date())
        let store = makeStore(scratch, clock: clock)
        let orphan = scratch.history.appending(path: "orphan", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(try store.sweep().isEmpty)
        clock.advance(by: HistoryStore.retention + 60)
        #expect(try store.sweep() == ["orphan"])
    }

    @Test func removeDeletesOneItemAndIgnoresUnknownOnes() throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        try store.remove(id: "nothing")
        try store.remove(id: item.id)
        #expect(try store.item(id: item.id) == nil)
    }

    @Test func conveniencePathsUseTheHistoryFolderOfSnapHome() throws {
        let scratch = try HistoryScratch()
        let paths = SnapPaths(home: scratch.url)
        let store = HistoryStore(paths: paths)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        #expect(item.originalURL.path(percentEncoded: false).hasPrefix(paths.historyDirectory.path(percentEncoded: false)))
    }
}
