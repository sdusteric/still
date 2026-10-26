import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SnapCore

@Suite struct ShelfStatusTests {
    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "snap-shelf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(_ name: String, in home: URL, width: Int = 900, height: Int = 600) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for stripe in 0..<20 {
            context.setFillColor(CGColor(red: Double(stripe) / 20, green: 0.4, blue: 1 - Double(stripe) / 20, alpha: 1))
            context.fill(CGRect(x: stripe * width / 20, y: 0, width: width / 20 + 1, height: height))
        }
        let url = home.appending(path: name, directoryHint: .notDirectory)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func captures(_ count: Int, in home: URL) throws -> [ShelfCapture] {
        try (0..<count).map { index in
            ShelfCapture(takenAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index) * 60), imageURL: try writePNG("c\(index).png", in: home))
        }
    }

    private func writer(_ home: URL) -> ShelfStatusWriter {
        ShelfStatusWriter(directory: home.appending(path: "status", directoryHint: .isDirectory), appVersion: "1.2.3")
    }

    private func json(_ writer: ShelfStatusWriter) throws -> [String: Any] {
        let data = try Data(contentsOf: writer.statusFile)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func jsonShapeHasCommonFieldsAndCaptures() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        try writer.write(captures: try captures(2, in: home), showPreviews: false, now: Date(timeIntervalSince1970: 1_800_000_100))

        let object = try json(writer)
        #expect(Set(object.keys) == ["schema", "app", "app_version", "updated_at", "captures"])
        #expect(object["schema"] as? Int == 1)
        #expect(object["app"] as? String == "snap")
        #expect(object["app_version"] as? String == "1.2.3")
        #expect(object["updated_at"] as? String == "2027-01-15T08:01:40Z")
        let entries = try #require(object["captures"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["taken_at"] as? String == "2027-01-15T08:00:00Z")
        #expect(entries.allSatisfy { Set($0.keys) == ["taken_at"] })
    }

    @Test func fileHasModeZeroSixHundredAndStaysSmall() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        try writer.write(captures: try captures(3, in: home), showPreviews: true)

        let attributes = try FileManager.default.attributesOfItem(atPath: writer.statusFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? .max < ShelfStatusWriter.maxFileBytes)
    }

    @Test func neverContainsPathsOrFileNames() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        try writer.write(captures: try captures(3, in: home), showPreviews: true)

        let text = try String(contentsOf: writer.statusFile, encoding: .utf8)
        #expect(!text.contains(home.lastPathComponent))
        #expect(!text.contains(".png"))
        #expect(!text.contains("/Users"))
    }

    @Test func keepsOnlyTheNewestThreeCaptures() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        try writer.write(captures: try captures(5, in: home), showPreviews: false)

        let entries = try #require(json(writer)["captures"] as? [[String: Any]])
        #expect(entries.count == 3)
        #expect(entries.last?["taken_at"] as? String == "2027-01-15T07:58:00Z")
    }

    @Test func noCapturesWritesAnEmptyList() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        try writer.write(captures: [], showPreviews: true)
        #expect((try json(writer)["captures"] as? [Any])?.isEmpty == true)
    }

    @Test func rewriteReplacesTheFileAndLeavesNoTemp() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        let items = try captures(3, in: home)
        try writer.write(captures: Array(items.prefix(1)), showPreviews: false)
        try writer.write(captures: items, showPreviews: false)

        #expect((try json(writer)["captures"] as? [Any])?.count == 3)
        let names = try FileManager.default.contentsOfDirectory(atPath: writer.directory.path(percentEncoded: false))
        #expect(names.sorted() == ["snap.json"])
    }

    @Test func staleTempFileDoesNotBlockTheWrite() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        try FileManager.default.createDirectory(at: writer.directory, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: writer.directory.appending(path: ".snap.json.tmp"))
        try writer.write(captures: [], showPreviews: false)
        #expect(try json(writer)["schema"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: writer.directory.appending(path: ".snap.json.tmp").path(percentEncoded: false)))
    }

    @Test func previewsAreWrittenOnlyWhileTheToggleIsOn() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        let items = try captures(3, in: home)

        try writer.write(captures: items, showPreviews: false)
        #expect(!FileManager.default.fileExists(atPath: writer.previewDirectory.path(percentEncoded: false)))
        var entries = try #require(json(writer)["captures"] as? [[String: Any]])
        #expect(entries.allSatisfy { $0["preview"] == nil })

        try writer.write(captures: items, showPreviews: true)
        entries = try #require(json(writer)["captures"] as? [[String: Any]])
        #expect(entries.compactMap { $0["preview"] as? String } == ["1.jpg", "2.jpg", "3.jpg"])
        for name in ["1.jpg", "2.jpg", "3.jpg"] {
            let url = writer.previewDirectory.appending(path: name)
            let data = try Data(contentsOf: url)
            #expect(data.count <= ShelfStatusWriter.maxPreviewBytes)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? .max) <= ShelfStatusWriter.maxPreviewWidth)
            #expect(CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }

        try writer.write(captures: items, showPreviews: false)
        #expect(!FileManager.default.fileExists(atPath: writer.previewDirectory.path(percentEncoded: false)))
        entries = try #require(json(writer)["captures"] as? [[String: Any]])
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0["preview"] == nil })
    }

    @Test func fewerCapturesRemoveTheExtraPreviews() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        let items = try captures(3, in: home)
        try writer.write(captures: items, showPreviews: true)
        try writer.write(captures: Array(items.prefix(1)), showPreviews: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: writer.previewDirectory.path(percentEncoded: false))
        #expect(names.sorted() == ["1.jpg"])
    }

    @Test func unreadableImageGetsNoPreview() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let writer = writer(home)
        let missing = ShelfCapture(takenAt: Date(timeIntervalSince1970: 1_800_000_000), imageURL: home.appending(path: "gone.png"))
        try writer.write(captures: [missing], showPreviews: true)
        let entries = try #require(json(writer)["captures"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["preview"] == nil)
    }

    @Test func statusFolderFollowsSnapHome() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "snap-shelf-paths", directoryHint: .isDirectory)
        let custom = SnapPaths(home: temp)
        #expect(SnapPaths.isInside(custom.shelfStatusDirectory, temp))
        let fakeUser = URL(filePath: "/tmp/fake-user", directoryHint: .isDirectory)
        let standard = SnapPaths(environment: ["HOME": fakeUser.path(percentEncoded: false)])
        #expect(standard.shelfStatusDirectory.path(percentEncoded: false).contains("fake-user/Library/Application Support/Shelf/status"))
    }

    @Test func showInShelfDefaultsOffAndRoundTrips() throws {
        #expect(Settings().general.showInShelf == false)
        var settings = Settings()
        settings.general.showInShelf = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).general.showInShelf)
        let old = Data(#"{"version":2,"general":{"playSound":true}}"#.utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).general.showInShelf == false)
    }
}
