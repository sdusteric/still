import AppKit
import Foundation
import ImageIO
import SnapCore
import SnapSystem
import Testing

// Every test writes to its own uniquely named pasteboard and releases it; never `.general`.
@MainActor
@Suite struct PasteboardWriterTests {
    func withPrivatePasteboard(_ body: (NSPasteboard, PasteboardWriter) throws -> Void) rethrows {
        let name = NSPasteboard.Name("dev.sdusteric.snap.tests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard, PasteboardWriter(pasteboardName: name))
    }

    func sampleImage() throws -> CGImage {
        try #require(SyntheticImages.block(
            width: 400, height: 200, block: CGRect(x: 40, y: 40, width: 100, height: 60)
        ))
    }

    @Test func writesPNGEagerlyWithItsDPI() throws {
        try withPrivatePasteboard { pasteboard, writer in
            let image = try sampleImage()
            let png = try PNGWriter.data(for: image, scale: 2)
            try writer.writeImage(pngData: png, image: image, scale: 2)

            let item = try #require(pasteboard.pasteboardItems?.first)
            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(item.types.contains(.png))
            #expect(item.types.contains(.tiff))
            #expect(item.data(forType: .png) == png)
            // 400x200 pixels at 144 DPI read back as 200x100 points.
            let pastedData = try #require(item.data(forType: .png))
            let pasted = try #require(NSImage(data: pastedData))
            #expect(pasted.size == CGSize(width: 200, height: 100))
        }
    }

    @Test func suppliesTIFFOnlyWhenAsked() throws {
        try withPrivatePasteboard { pasteboard, writer in
            let image = try sampleImage()
            try writer.writeImage(pngData: try PNGWriter.data(for: image, scale: 2), image: image, scale: 2)

            let tiff = try #require(pasteboard.data(forType: .tiff))
            let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == 400)
            #expect(decoded.height == 200)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            #expect((properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue == 144)
        }
    }

    @Test func tiffEncodingKeepsSizeAndDPI() throws {
        let image = try sampleImage()
        let tiff = try #require(PasteboardWriter.tiffData(for: image, scale: 1))
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 400)
        #expect((properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue == 72)
    }

    @Test func copyFileWritesOnlyTheURL() throws {
        try withPrivatePasteboard { pasteboard, writer in
            let url = URL(filePath: "/tmp/snap-tests/Snap 2026-10-24 at 14.03.22.png")
            try writer.writeFileURL(url)
            let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            #expect(urls == [url])
            #expect(pasteboard.data(forType: .png) == nil)
        }
    }

    @Test func aNewCaptureReplacesTheOldOne() throws {
        try withPrivatePasteboard { pasteboard, writer in
            let image = try sampleImage()
            try writer.writeFileURL(URL(filePath: "/tmp/snap-tests/old.png"))
            let png = try PNGWriter.data(for: image, scale: 1)
            try writer.writeImage(pngData: png, image: image, scale: 1)
            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(pasteboard.data(forType: .png) == png)
            #expect(pasteboard.readObjects(forClasses: [NSURL.self])?.isEmpty ?? true)
        }
    }
}
