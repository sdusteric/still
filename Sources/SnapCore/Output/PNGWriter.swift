import CoreGraphics
import Foundation
import ImageIO

/// PNG encoding with ImageIO (design section 9): pHYs at 72 DPI times the scale, the image's own
/// colour profile embedded, and atomic file writes.
public enum PNGWriter {
    public enum WriteError: Error, CustomStringConvertible {
        case cannotCreateDestination
        case encodingFailed

        public var description: String {
            switch self {
            case .cannotCreateDestination: "cannot create a PNG encoder"
            case .encodingFailed: "PNG encoding failed"
            }
        }
    }

    /// The PNG bytes of `image`. `scale` is pixels per point: 2 writes 144 DPI (a 5669 px/m pHYs chunk).
    public static func data(for image: CGImage, scale: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw WriteError.cannotCreateDestination
        }
        let dpi = 72 * (scale > 0 ? scale : 1)
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.encodingFailed }
        return embedProfile(of: image, in: output as Data)
    }

    /// ImageIO marks sRGB images with the short `sRGB` chunk instead of carrying the profile. Swap it
    /// for an `iCCP` chunk with the full ICC profile, so every reader sees the profile (design section 9).
    /// Other colour spaces already get an `iCCP` chunk and are returned unchanged.
    static func embedProfile(of image: CGImage, in png: Data) -> Data {
        guard let profile = image.colorSpace?.copyICCData() as Data?, !profile.isEmpty,
              let compressed = try? (profile as NSData).compressed(using: .zlib) as Data else { return png }
        var output = Data(png.prefix(8))
        var offset = 8
        var replaced = false
        while offset + 12 <= png.count {
            let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = offset + 12 + length
            guard end <= png.count else { return png }
            let type = png[offset + 4..<offset + 8]
            if type.elementsEqual("iCCP".utf8) { return png }
            if type.elementsEqual("sRGB".utf8) {
                var body = Data("ICC Profile".utf8)
                body.append(contentsOf: [0, 0, 0x78, 0x9C])
                body.append(compressed)
                body.append(bigEndian: PNGChecksum.adler32(profile))
                output.append(chunk: "iCCP", body: body)
                replaced = true
            } else {
                output.append(png[offset..<end])
            }
            offset = end
        }
        return replaced ? output : png
    }

    /// Encodes and writes to `url` through a temp file and rename, creating the folder if needed.
    public static func write(_ image: CGImage, scale: Double, to url: URL) throws {
        try AtomicFile.write(try data(for: image, scale: scale), to: url)
    }
}

/// Reads a PNG (or any ImageIO format) and derives the scale from its DPI: 144 gives 2, none or 72 gives 1.
public enum PNGReader {
    public enum ReadError: Error, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case .unreadable(let what): "cannot read an image from \(what)"
            }
        }
    }

    public static func read(_ url: URL) throws -> CapturedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReadError.unreadable(url.path(percentEncoded: false))
        }
        return try image(from: source, description: url.path(percentEncoded: false))
    }

    public static func read(_ data: Data) throws -> CapturedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ReadError.unreadable("data")
        }
        return try image(from: source, description: "data")
    }

    /// Pixels per point from a DPI value: at least 1, rounded to two decimals.
    public static func scale(forDPI dpi: Double?) -> Double {
        guard let dpi, dpi.isFinite, dpi > 0 else { return 1 }
        return max((dpi / 72 * 100).rounded() / 100, 1)
    }

    private static func image(from source: CGImageSource, description: String) throws -> CapturedImage {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReadError.unreadable(description)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        return CapturedImage(cgImage: cgImage, scale: scale(forDPI: dpi))
    }
}

/// CRC-32 (PNG chunks) and Adler-32 (zlib streams).
enum PNGChecksum {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ data: some Sequence<UInt8>) -> UInt32 {
        ~data.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    static func adler32(_ data: Data) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in data {
            low = (low + UInt32(byte)) % 65_521
            high = (high + low) % 65_521
        }
        return high << 16 | low
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func append(chunk type: String, body: Data) {
        append(bigEndian: UInt32(body.count))
        let typeBytes = Data(type.utf8)
        append(typeBytes)
        append(body)
        append(bigEndian: PNGChecksum.crc32(typeBytes + body))
    }
}
