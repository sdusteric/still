import CoreGraphics
import Foundation
import SnapCore
import Testing

private struct PNGChunk {
    let type: String
    let data: Data
}

/// Splits PNG bytes into chunks after the 8-byte signature.
private func chunks(of png: Data) -> [PNGChunk] {
    var result: [PNGChunk] = []
    var offset = 8
    while offset + 12 <= png.count {
        let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
        guard offset + 12 + length <= png.count else { break }
        result.append(PNGChunk(type: type, data: png[offset + 8..<offset + 8 + length]))
        offset += 12 + length
    }
    return result
}

private func bigEndianInt(_ data: Data, at start: Int) -> Int {
    data[data.startIndex + start..<data.startIndex + start + 4].reduce(0) { $0 << 8 | Int($1) }
}

private final class PNGScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "png-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A leftover scratch dir inside a temp dir is harmless.
        }
    }
}

@Suite struct PNGWriterTests {
    @Test func scaleTwoWritesPhysicalSizeOf5669PixelsPerMetre() throws {
        let image = try #require(SyntheticImages.solid(width: 40, height: 20, color: .red))
        let png = try PNGWriter.data(for: image, scale: 2)
        let physical = try #require(chunks(of: png).first { $0.type == "pHYs" })
        #expect(bigEndianInt(physical.data, at: 0) == 5669)
        #expect(bigEndianInt(physical.data, at: 4) == 5669)
        #expect(physical.data[physical.data.startIndex + 8] == 1)
    }

    @Test func scaleOneWritesAbout2835PixelsPerMetre() throws {
        let image = try #require(SyntheticImages.solid(width: 40, height: 20, color: .red))
        let png = try PNGWriter.data(for: image, scale: 1)
        let physical = try #require(chunks(of: png).first { $0.type == "pHYs" })
        #expect(bigEndianInt(physical.data, at: 0) == 2835)
    }

    @Test func colourProfileIsEmbedded() throws {
        let image = try #require(SyntheticImages.solid(width: 40, height: 20, color: .red))
        let png = try PNGWriter.data(for: image, scale: 2)
        let all = chunks(of: png)
        let profile = try #require(all.first { $0.type == "iCCP" })
        #expect(!all.contains { $0.type == "sRGB" })

        // name, NUL, method 0, then a zlib stream: 2-byte header, raw deflate, Adler-32.
        let body = profile.data
        let nameEnd = try #require(body.firstIndex(of: 0))
        #expect(body[nameEnd + 1] == 0)
        let stream = body[(nameEnd + 2)...]
        #expect(stream.first == 0x78)
        let deflate = Data(stream.dropFirst(2).dropLast(4))
        let inflated = try (deflate as NSData).decompressed(using: .zlib) as Data
        let expected = try #require(image.colorSpace?.copyICCData() as Data?)
        #expect(inflated == expected)

        // ImageIO reads it back as a usable RGB profile and the pixels are intact.
        let decoded = try PNGReader.read(png).cgImage
        #expect(decoded.colorSpace?.model == .rgb)
        #expect(SyntheticImages.pixel(of: decoded, x: 3, y: 3) == .red)
    }

    @Test func wideGamutImagesKeepTheirOwnProfile() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let png = try PNGWriter.data(for: image, scale: 2)
        #expect(chunks(of: png).filter { $0.type == "iCCP" }.count == 1)
        let decoded = try PNGReader.read(png).cgImage
        #expect(decoded.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    @Test func readerDerivesScaleFromDPI() throws {
        let image = try #require(SyntheticImages.solid(width: 40, height: 20, color: .red))
        let twice = try PNGReader.read(try PNGWriter.data(for: image, scale: 2))
        #expect(twice.scale == 2)
        #expect(twice.pixelWidth == 40)
        #expect(twice.pointSize == CGSize(width: 20, height: 10))
        let once = try PNGReader.read(try PNGWriter.data(for: image, scale: 1))
        #expect(once.scale == 1)
        #expect(PNGReader.scale(forDPI: nil) == 1)
        #expect(PNGReader.scale(forDPI: 144) == 2)
    }

    @Test func pixelsSurviveTheRoundTrip() throws {
        let image = try #require(SyntheticFixture.block1x.makeImage())
        let decoded = try PNGReader.read(try PNGWriter.data(for: image, scale: 1)).cgImage
        #expect(SyntheticImages.pixel(of: decoded, x: 100, y: 100) == .red)
        #expect(SyntheticImages.pixel(of: decoded, x: 10, y: 10) == .white)
    }

    @Test func fileWriteIsAtomicAndLeavesNoTempFile() throws {
        let scratch = try PNGScratch()
        let target = scratch.url.appending(path: "nested/out.png", directoryHint: .notDirectory)
        let image = try #require(SyntheticImages.solid(width: 8, height: 8, color: .black))
        try PNGWriter.write(image, scale: 2, to: target)
        try PNGWriter.write(image, scale: 2, to: target)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path(percentEncoded: false))
        #expect(names == ["out.png"])
        let read = try PNGReader.read(target)
        #expect(read.scale == 2)
    }
}
