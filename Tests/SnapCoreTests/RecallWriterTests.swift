import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SnapCore

enum RecallTestSupport {
    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "snap-recall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        guard url.path(percentEncoded: false).contains("/snap-recall-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A noisy PNG, so JPEG compression has real work to do.
    static func writePNG(in folder: URL, name: String = "shot.png", width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        var seed: UInt64 = 7
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let value = Double(seed >> 56) / 255
                context.setFillColor(CGColor(red: value, green: 1 - value, blue: Double(x % 255) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func entry(_ id: String = "20261024-140322-3f9a1c2e", title: String = "Notes", lines: [String] = ["Stripe error 4402"]) -> RecallEntry {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return RecallEntry(
            id: id, title: title, createdAt: date, updatedAt: date, language: "en-US", context: ["source_app": title],
            segments: lines.map(RecallEntry.Segment.init(text:)))
    }
}

@Suite struct RecallWriterTests {
    private func writer(_ home: URL) -> RecallWriter {
        RecallWriter(directory: SnapPaths(home: home).recallDirectory)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func writesEntryWithSnakeCaseKeys() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        try writer.write(RecallTestSupport.entry(), previewFrom: nil)
        let url = writer.directory.appending(path: "20261024-140322-3f9a1c2e.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["app"] as? String == "snap")
        #expect(object["kind"] as? String == "screenshot")
        #expect(object["created_at"] as? String == "2027-01-15T08:00:00Z")
        #expect(object["updated_at"] != nil)
        #expect((object["context"] as? [String: String])?["source_app"] == "Notes")
        #expect((object["segments"] as? [[String: String]])?.first?["text"] == "Stripe error 4402")
        #expect(object["preview"] == nil)
    }

    @Test func filesAre0600AndFolder0700() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        let png = try RecallTestSupport.writePNG(in: home, width: 800, height: 500)
        try writer.write(RecallTestSupport.entry(), previewFrom: png)
        #expect(try permissions(writer.directory) == 0o700)
        #expect(try permissions(writer.directory.appending(path: "20261024-140322-3f9a1c2e.json")) == 0o600)
        #expect(try permissions(writer.directory.appending(path: "20261024-140322-3f9a1c2e.jpg")) == 0o600)
    }

    @Test func previewIsAtMost480And80KB() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        let png = try RecallTestSupport.writePNG(in: home, width: 5120, height: 2880)
        try writer.write(RecallTestSupport.entry(), previewFrom: png)
        let jpg = writer.directory.appending(path: "20261024-140322-3f9a1c2e.jpg")
        let data = try Data(contentsOf: jpg)
        #expect(data.count <= 80 * 1024)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        #expect(width <= 480 && width >= 240)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: writer.directory.appending(path: "20261024-140322-3f9a1c2e.json"))) as? [String: Any])
        #expect(object["preview"] as? String == "20261024-140322-3f9a1c2e.jpg")
    }

    @Test func cutsTitleAndContextTo120() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        try writer.write(RecallTestSupport.entry(title: String(repeating: "a", count: 300)), previewFrom: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: writer.directory.appending(path: "20261024-140322-3f9a1c2e.json"))) as? [String: Any])
        #expect((object["title"] as? String)?.count == 120)
        #expect(((object["context"] as? [String: String])?["source_app"])?.count == 120)
    }

    @Test func removeDeletesEntryAndPreview() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        let png = try RecallTestSupport.writePNG(in: home, width: 400, height: 300)
        try writer.write(RecallTestSupport.entry(), previewFrom: png)
        try writer.write(RecallTestSupport.entry("20261025-090000-0000abcd"), previewFrom: png)
        try writer.remove(id: "20261024-140322-3f9a1c2e")
        #expect(try writer.storedIDs() == ["20261025-090000-0000abcd"])
        #expect(!FileManager.default.fileExists(atPath: writer.directory.appending(path: "20261024-140322-3f9a1c2e.jpg").path(percentEncoded: false)))
        try writer.remove(id: "missing-id")
    }

    @Test func removePreviewsKeepsEntries() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        let png = try RecallTestSupport.writePNG(in: home, width: 400, height: 300)
        try writer.write(RecallTestSupport.entry(), previewFrom: png)
        try writer.removePreviews()
        #expect(try writer.storedIDs() == ["20261024-140322-3f9a1c2e"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: writer.directory.appending(path: "20261024-140322-3f9a1c2e.json"))) as? [String: Any])
        #expect(object["preview"] == nil)
    }

    @Test func removeAllEmptiesFolderOnly() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        try writer.write(RecallTestSupport.entry(), previewFrom: nil)
        let neighbor = writer.directory.deletingLastPathComponent().appending(path: "booth", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: neighbor.appending(path: "keep.json"))
        try writer.removeAll()
        #expect(try writer.storedIDs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: neighbor.appending(path: "keep.json").path(percentEncoded: false)))
    }

    @Test func refusesEntryOver4MB() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let writer = writer(home)
        let huge = (0..<50_000).map { "line \($0) " + String(repeating: "x", count: 80) }
        #expect(throws: RecallWriter.WriteError.tooLarge) {
            try writer.write(RecallTestSupport.entry(lines: huge), previewFrom: nil)
        }
        #expect(try writer.storedIDs().isEmpty)
    }

    @Test func recallDirectoryFollowsHome() {
        let home = URL(filePath: "/tmp/snap-recall-x", directoryHint: .isDirectory)
        #expect(SnapPaths(home: home).recallDirectory.path(percentEncoded: false).hasSuffix("/snap-recall-x/ShelfRecall/snap/"))
        let user = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let paths = SnapPaths(home: user.appending(path: "Library/Application Support/Snap", directoryHint: .isDirectory), userHome: user)
        #expect(paths.recallDirectory.path(percentEncoded: false) == "/Users/someone/Library/Application Support/Shelf/recall/snap/")
    }
}
