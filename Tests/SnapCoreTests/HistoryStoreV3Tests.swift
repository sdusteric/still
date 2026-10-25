import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (or the temp dir), removed by its exact path when done.
private final class V3Scratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "history-v3-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
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

    func store() -> HistoryStore {
        HistoryStore(directory: history, clock: FakeClock(), trasher: FakeTrasher(directory: url.appending(path: "trash")))
    }

    func writeItemJSON(_ json: String, id: String) throws -> URL {
        let folder = history.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: HistoryStore.itemFileName))
        return folder
    }
}

@Suite struct HistoryStoreV3Tests {
    /// 400 x 300 px at 2x: 200 x 150 points of gradient and grid.
    private func capture() throws -> CGImage {
        try #require(SyntheticImages.gradientGrid(width: 400, height: 300, scale: 2))
    }

    /// One of every kind the editor keeps: shapes, text, steps, redactions, a highlight, freehand.
    private func annotatedDocument(_ image: CGImage) -> AnnotationDocument {
        var document = AnnotationDocument(image: image, scale: 2)
        document.add(.rectangle(CGRect(x: 10, y: 10, width: 60, height: 30)))
        document.add(.arrow(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 80, y: 40)))
        document.add(.text("this one", at: CGPoint(x: 90, y: 100)))
        document.add(.highlight(CGRect(x: 20, y: 60, width: 100, height: 14)))
        document.add(.redact(CGRect(x: 130, y: 10, width: 40, height: 20), style: .pixelate))
        document.add(.redact(CGRect(x: 130, y: 40, width: 40, height: 20), style: .blur))
        document.add(.redact(CGRect(x: 130, y: 70, width: 40, height: 20), style: .blackout))
        document.add(.step(at: CGPoint(x: 30, y: 120)))
        document.add(.step(at: CGPoint(x: 60, y: 120)))
        document.add(.freehand(FreehandPath.decimated([
            CGPoint(x: 10, y: 140), CGPoint(x: 40, y: 130), CGPoint(x: 70, y: 142), CGPoint(x: 100, y: 128),
        ])))
        document.crop(to: CGRect(x: 4, y: 4, width: 190, height: 140))
        return document
    }

    private var preset: BackgroundPreset {
        var preset = BackgroundPreset.factoryDefault
        preset.padding = 40
        preset.shadow = 10
        return preset
    }

    @Test func anEditKeepsItsAnnotationsNextToTheItemAndReadsThemBack() throws {
        let scratch = try V3Scratch()
        let store = scratch.store()
        let image = try capture()
        let item = try store.add(pngData: try PNGWriter.data(for: image, scale: 2), fileName: "shot.png", mode: .area, scale: 2)
        #expect(item.annotationsURL == nil)
        #expect(try store.annotations(id: item.id) == nil)

        let document = annotatedDocument(image)
        let file = AnnotationFile(document: document, background: preset)
        let flattened = try file.render(original: image, scale: 2)
        let edited = try store.saveEdited(
            id: item.id, pngData: try PNGWriter.data(for: flattened.image, scale: flattened.scale), annotations: file
        )
        #expect(edited.annotationsURL?.lastPathComponent == "annotations.json")
        #expect(edited.isEdited)

        let read = try #require(try store.annotations(id: item.id))
        #expect(read == file)
        #expect(read.items.map(\.kind) == [
            .rectangle, .arrow, .text, .highlight, .pixelate, .blur, .blackout, .step, .step, .freehand,
        ])
        #expect(read.background == preset)
        #expect(read.cropRect == document.cropRect)

        // Reopening rebuilds the editor's document on the original: every item editable, not flattened.
        let original = try PNGReader.read(item.originalURL)
        let reopened = read.document(image: original.cgImage, scale: original.scale)
        #expect(reopened.items == document.items)
        #expect(reopened.cropRect == document.cropRect)
        #expect(reopened.stepNumber(of: reopened.items[8].id) == 2)
        var moved = reopened
        let didMove = moved.move(reopened.items[0].id, by: 5, 5)
        #expect(didMove)
        #expect(moved.items[0].start == CGPoint(x: 15, y: 15))
    }

    @Test func itemJSONIsVersionThreeAndNamesTheAnnotationFile() throws {
        let scratch = try V3Scratch()
        let store = scratch.store()
        let image = try capture()
        let item = try store.add(pngData: try PNGWriter.data(for: image, scale: 2), fileName: "shot.png", mode: .window, scale: 2)
        _ = try store.saveEdited(id: item.id, pngData: try PNGWriter.data(for: image, scale: 2),
                                 annotations: AnnotationFile(items: [.rectangle(CGRect(x: 1, y: 1, width: 20, height: 20))]))
        let data = try Data(contentsOf: store.folder(for: item.id).appending(path: HistoryStore.itemFileName))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(HistoryStore.currentVersion == 3)
        #expect(json["version"] as? Int == 3)
        #expect(json["annotationsName"] as? String == "annotations.json")
        let annotations = try Data(contentsOf: store.folder(for: item.id).appending(path: "annotations.json"))
        let file = try #require(try JSONSerialization.jsonObject(with: annotations) as? [String: Any])
        #expect(file["version"] as? Int == 1)
        #expect((file["items"] as? [Any])?.count == 1)
    }

    @Test func anEditWithoutAnnotationsLeavesTheEarlierFileInPlace() throws {
        let scratch = try V3Scratch()
        let store = scratch.store()
        let image = try capture()
        let png = try PNGWriter.data(for: image, scale: 2)
        let item = try store.add(pngData: png, fileName: "shot.png", mode: .area, scale: 2)
        let file = AnnotationFile(items: [.step(at: CGPoint(x: 20, y: 20))])
        _ = try store.saveEdited(id: item.id, pngData: png, annotations: file)
        let again = try store.saveEdited(id: item.id, pngData: png)
        #expect(again.annotationsURL != nil)
        #expect(try store.annotations(id: item.id) == file)
    }

    @Test func theRenderIsTheFlattenedDocumentWithTheBackgroundAround() throws {
        let image = try capture()
        let document = annotatedDocument(image)
        let plain = try AnnotationFile(document: document).render(original: image, scale: 2)
        let flattened = try Flattener.flatten(document)
        #expect(plain.image.width == flattened.width && plain.image.height == flattened.height)
        #expect(plain.scale == 2)
        let framed = try AnnotationFile(document: document, background: preset).render(original: image, scale: 2)
        #expect(framed.image.width > flattened.width, "the Background adds padding around the annotated image")
        let backgroundOnly = try AnnotationFile(background: preset).render(original: image, scale: 2)
        #expect(!AnnotationFile(background: preset).hasAnnotations)
        #expect(backgroundOnly.image.width > image.width)
    }

    @Test func versionOneAndTwoItemsReadWithoutAnnotationsOrAudioCheck() throws {
        let scratch = try V3Scratch()
        let store = scratch.store()
        _ = try scratch.writeItemJSON("""
            {"version": 1, "id": "20261024-140322-3f9a1c2e", "createdAt": "2026-10-24T14:03:22Z", "mode": "window",
             "scale": 2, "originalName": "a.png", "editedName": "a (edited).png", "sourceApp": "Notes"}
            """, id: "20261024-140322-3f9a1c2e")
        _ = try scratch.writeItemJSON("""
            {"version": 2, "id": "20261024-150000-aaaaaaaa", "createdAt": "2026-10-24T15:00:00Z", "mode": "area",
             "scale": 2, "originalName": "b.png", "editedName": "b (edited).png", "kind": "image", "state": "complete",
             "screenRect": [10, 20, 300, 200], "pixelSize": [600, 400]}
            """, id: "20261024-150000-aaaaaaaa")
        _ = try scratch.writeItemJSON("""
            {"version": 2, "id": "20261024-160000-bbbbbbbb", "createdAt": "2026-10-24T16:00:00Z", "mode": "area",
             "scale": 2, "originalName": "c.mp4", "kind": "video", "state": "complete", "durationSeconds": 4.2,
             "audio": ["microphone"]}
            """, id: "20261024-160000-bbbbbbbb")

        let first = try #require(try store.item(id: "20261024-140322-3f9a1c2e"))
        #expect(first.isEdited)
        #expect(first.annotationsURL == nil)
        #expect(try store.annotations(id: first.id) == nil, "an edit from version 1 has nothing to rebuild")
        let second = try #require(try store.item(id: "20261024-150000-aaaaaaaa"))
        #expect(second.isEdited)
        #expect(second.annotationsURL == nil)
        #expect(second.screenRect == CGRect(x: 10, y: 20, width: 300, height: 200))
        let video = try #require(try store.item(id: "20261024-160000-bbbbbbbb"))
        #expect(video.audio == [.microphone])
        #expect(video.audioCheck == nil)
        #expect(try store.allItems().count == 3)
    }

    @Test func anAnnotationFileFromAnOlderOrPartialWriterStillDecodes() throws {
        let json = #"{"items": [], "cropRect": [1, 2, 30, 40]}"#
        let file = try JSONDecoder().decode(AnnotationFile.self, from: Data(json.utf8))
        #expect(file.version == AnnotationFile.currentVersion)
        #expect(file.cropRect == CGRect(x: 1, y: 2, width: 30, height: 40))
        #expect(file.background == nil)
        #expect(file.hasAnnotations)
    }

    @Test func aVideoItemNeverCarriesAnnotations() throws {
        let scratch = try V3Scratch()
        let store = scratch.store()
        let video = try store.add(video: NewVideo(fileName: "r.mp4", mode: .area, scale: 2, audio: [.system]))
        let finished = try store.finishVideo(id: video.id, FinishedVideo(durationSeconds: 1, audioCheck: .systemSilent))
        #expect(finished.audioCheck == .systemSilent)
        #expect(finished.annotationsURL == nil)
    }
}
