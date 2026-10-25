import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (or the temp dir), removed by its exact path when done.
private final class V2Scratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "history-v2-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
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
    var trash: URL { url.appending(path: "fake-trash", directoryHint: .isDirectory) }

    func itemJSON(_ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: history.appending(path: "\(id)/item.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

@Suite struct HistoryStoreV2Tests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 4, 5, 6])

    private func makeStore(_ scratch: V2Scratch, clock: FakeClock = FakeClock()) -> (HistoryStore, FakeTrasher) {
        let trasher = FakeTrasher(directory: scratch.trash)
        return (HistoryStore(directory: scratch.history, clock: clock, trasher: trasher), trasher)
    }

    @Test func aVersion1ItemJSONReadsAsACompleteImage() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let folder = scratch.history.appending(path: "20261024-140322-3f9a1c2e", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
            {"version": 1, "id": "20261024-140322-3f9a1c2e", "createdAt": "2026-10-24T14:03:22Z", "mode": "window",
             "scale": 2, "originalName": "Snap 2026-10-24 at 14.03.22.png",
             "editedName": "Snap 2026-10-24 at 14.03.22 (edited).png", "sourceApp": "Notes"}
            """
        try Data(json.utf8).write(to: folder.appending(path: "item.json"))
        let item = try #require(try store.item(id: "20261024-140322-3f9a1c2e"))
        #expect(item.kind == .image)
        #expect(item.state == .complete)
        #expect(item.mode == .window)
        #expect(item.sourceApp == "Notes")
        #expect(item.isEdited)
        #expect(item.screenRect == nil)
        #expect(item.pixelSize == nil)
        #expect(item.durationSeconds == nil)
        #expect(item.posterURL == nil)
        #expect(item.audio.isEmpty)
        #expect(try store.allItems().map(\.id) == ["20261024-140322-3f9a1c2e"])
    }

    @Test func aVersion2ImageRoundTripsWithItsScreenRectAndPixelSize() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let rect = CGRect(x: 330, y: 150, width: 640, height: 400)
        let added = try store.add(
            pngData: png, fileName: "a.png", mode: .area, scale: 2, sourceApp: "Xcode",
            createdAt: Date(timeIntervalSince1970: 1_792_850_000), id: "20261024-160000-aaaaaaaa",
            screenRect: rect, pixelSize: PixelSize(width: 1280, height: 800)
        )
        let loaded = try #require(try store.item(id: added.id))
        #expect(loaded == added)
        #expect(loaded.screenRect == rect)
        #expect(loaded.pixelSize == PixelSize(width: 1280, height: 800))
        #expect(loaded.kind == .image)
        let json = try scratch.itemJSON(added.id)
        #expect(json["version"] as? Int == HistoryStore.currentVersion)
        #expect(json["kind"] as? String == "image")
        #expect(json["screenRect"] as? [Double] == [330, 150, 640, 400])
        #expect(json["pixelSize"] as? [Int] == [1280, 800])

        let edited = try store.saveEdited(id: added.id, pngData: png)
        #expect(edited.screenRect == rect, "an edit keeps the version 2 fields")
    }

    @Test func aRecordingIsWrittenHistoryFirstThenFinished() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let video = NewVideo(
            fileName: "Snap 2026-10-24 at 14.03.22.mp4", mode: .area, scale: 2, sourceApp: "Safari",
            screenRect: CGRect(x: 330, y: 150, width: 640, height: 400), pixelSize: PixelSize(width: 1280, height: 800),
            codec: "avc1", fps: 30, audio: [.system, .microphone]
        )
        let started = try store.add(video: video, id: "20261024-140322-bbbbbbbb")
        #expect(started.kind == .video)
        #expect(started.state == .recording)
        #expect(started.originalURL.lastPathComponent == "Snap 2026-10-24 at 14.03.22.mp4")
        #expect(FileManager.default.fileExists(atPath: started.originalURL.path(percentEncoded: false)) == false)
        #expect(try scratch.itemJSON(started.id)["state"] as? String == "recording")
        #expect(started.audio == [.system, .microphone])

        try Data([1, 2, 3]).write(to: started.originalURL)
        let finished = try store.finishVideo(
            id: started.id,
            FinishedVideo(durationSeconds: 3, pixelSize: PixelSize(width: 1280, height: 800), codec: "hvc1", posterPNGData: png)
        )
        #expect(finished.state == .complete)
        #expect(finished.durationSeconds == 3)
        #expect(finished.codec == "hvc1")
        #expect(finished.fps == 30)
        #expect(finished.posterURL?.lastPathComponent == "Snap 2026-10-24 at 14.03.22 poster.png")
        #expect(finished.thumbnailURL == finished.posterURL)
        #expect(try finished.posterURL.map { try Data(contentsOf: $0) } == png)
        let json = try scratch.itemJSON(started.id)
        #expect(json["state"] as? String == "complete")
        #expect(json["posterName"] as? String == "Snap 2026-10-24 at 14.03.22 poster.png")
        #expect(json["audio"] as? [String] == ["system", "microphone"])
        #expect(try store.item(id: started.id) == finished)
    }

    @Test func finishingSomethingThatIsNotARecordingThrows() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let image = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        #expect(throws: HistoryError.notAVideo(image.id)) {
            try store.finishVideo(id: image.id, FinishedVideo(durationSeconds: 1))
        }
        #expect(throws: HistoryError.itemNotFound("missing")) {
            try store.finishVideo(id: "missing", FinishedVideo(durationSeconds: 1))
        }
    }

    @Test func markInterruptedTurnsOnlyRecordingItemsIntoInterrupted() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let image = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2, id: "20261024-100000-00000001")
        let live = try store.add(video: NewVideo(fileName: "b.mp4", mode: .fullscreen, scale: 2), id: "20261024-100000-00000002")
        let done = try store.add(video: NewVideo(fileName: "c.mp4", mode: .window, scale: 1), id: "20261024-100000-00000003")
        try store.finishVideo(id: done.id, FinishedVideo(durationSeconds: 2))

        #expect(try store.markInterrupted() == [live.id])
        #expect(try store.item(id: live.id)?.state == .interrupted)
        #expect(try store.item(id: done.id)?.state == .complete)
        #expect(try store.item(id: image.id)?.state == .complete)
        #expect(try store.markInterrupted().isEmpty, "a second launch changes nothing")
    }

    @Test func aFinishedFileThatDoesNotPlayIsStoredInterrupted() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let started = try store.add(video: NewVideo(fileName: "v.mp4", mode: .area, scale: 2))
        let finished = try store.finishVideo(id: started.id, FinishedVideo(durationSeconds: 0.4, state: .interrupted))
        #expect(finished.state == .interrupted)
        #expect(finished.posterURL == nil)
    }

    @Test func sweepSkipsInUseItemsUntilTheyAreFree() throws {
        let scratch = try V2Scratch()
        let clock = FakeClock()
        let (store, _) = makeStore(scratch, clock: clock)
        let pinned = try store.add(pngData: png, fileName: "pinned.png", mode: .area, scale: 2)
        let card = try store.add(pngData: png, fileName: "card.png", mode: .area, scale: 2)
        let plain = try store.add(pngData: png, fileName: "plain.png", mode: .area, scale: 2)
        clock.advance(by: HistoryStore.retention + 60)

        let first = try store.sweep(skipping: [pinned.id, card.id])
        #expect(first == [plain.id])
        #expect(try store.item(id: pinned.id) != nil)
        #expect(try store.item(id: card.id) != nil)

        #expect(try store.sweep(skipping: [pinned.id]) == [card.id])
        #expect(try store.sweep() == [pinned.id])
    }

    @Test func sweepJudgesByAnExplicitNow() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let created = Date(timeIntervalSince1970: 1_792_843_200)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2, createdAt: created)
        #expect(try store.sweep(now: created.addingTimeInterval(HistoryStore.retention - 1)).isEmpty)
        #expect(try store.sweep(now: created.addingTimeInterval(HistoryStore.retention + 1)) == [item.id])
    }

    @Test func trashMovesTheFolderThroughTheInjectedTrasher() throws {
        let scratch = try V2Scratch()
        let (store, trasher) = makeStore(scratch)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        #expect(try store.trash(id: item.id))
        #expect(try store.item(id: item.id) == nil)
        #expect(trasher.trashed == [store.folder(for: item.id)])
        let moved = try FileManager.default.contentsOfDirectory(atPath: scratch.trash.path(percentEncoded: false))
        #expect(moved.count == 1)
        #expect(try store.trash(id: "missing") == false)
        #expect(trasher.trashed.count == 1)
    }

    @Test func totalBytesCountsEveryFileInTheHistory() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        #expect(try store.totalBytes() == 0)
        let item = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2)
        try store.saveEdited(id: item.id, pngData: Data(count: 1000))
        let json = try Data(contentsOf: store.folder(for: item.id).appending(path: "item.json"))
        #expect(try store.totalBytes() == Int64(png.count + 1000 + json.count))
    }

    @Test func theFixtureListsVersion1ItemsAsCompleteImagesAndMatchesItsManifest() throws {
        let scratch = try V2Scratch()
        let (store, _) = makeStore(scratch)
        let now = Date(timeIntervalSince1970: 1_792_850_000)
        let manifest = try HistoryFixture.generate(
            into: store, options: .init(items: 60, days: 5, seed: 7, now: now, timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        )
        let items = try store.allItems()
        #expect(items.map(\.id) == manifest.ids)
        #expect(!manifest.version1IDs.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for id in manifest.version1IDs {
            #expect(byID[id]?.kind == .image)
            #expect(byID[id]?.state == .complete)
        }
        #expect(Set(items.filter(\.isVideo).map(\.id)) == Set(manifest.videoIDs))
        let removed = try store.sweep(skipping: Set([manifest.skipID].compactMap { $0 }), now: now)
        #expect(removed == manifest.expectedSweptIDs)
        #expect(try store.allItems().map(\.id) == manifest.remainingIDs)

        let second = try V2Scratch()
        let (secondStore, _) = makeStore(second)
        let repeated = try HistoryFixture.generate(
            into: secondStore, options: .init(items: 60, days: 5, seed: 7, now: now, timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        )
        #expect(repeated == manifest, "the same seed and now give the same fixture")
    }
}
