import CoreGraphics
import Foundation

/// The border of a capture and where its content sits (design 10.2 step 2).
public struct EdgeAnalysis: Sendable, Equatable {
    /// Per channel tolerance, out of 255, when comparing two pixels.
    public static let tolerance = 6
    /// The border is uniform when at least this share of the outermost pixels match its colour.
    public static let uniformThreshold = 0.9
    /// How many of the most frequent border colours are tried as the mode.
    private static let candidateLimit = 32

    /// The most common colour among the outermost pixels.
    public var borderColor: SyntheticImages.Pixel
    /// Share of the outermost pixels that match `borderColor`, 0 to 1.
    public var matchFraction: Double
    public var isUniform: Bool
    /// The smallest rectangle holding every pixel that does not match the border colour, in image
    /// pixels from the top-left. The whole image when every pixel matches.
    public var contentBounds: CGRect
    /// False when every pixel matches the border colour.
    public var hasContent: Bool

    /// Analyzes `image`. Nil when its pixels cannot be read.
    public static func analyze(_ image: CGImage) -> EdgeAnalysis? {
        guard let bytes = SyntheticImages.rgbaBytes(of: image) else { return nil }
        return analyze(rgba: bytes, width: image.width, height: image.height)
    }

    /// Analyzes straight-alpha RGBA bytes, row-major from the top-left.
    public static func analyze(rgba bytes: [UInt8], width: Int, height: Int) -> EdgeAnalysis? {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        return bytes.withUnsafeBufferPointer { analyze(pixels: $0, width: width, height: height) }
    }

    private static func analyze(pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> EdgeAnalysis {
        let border = borderColor(pixels: pixels, width: width, height: height)
        let bounds = contentBounds(pixels: pixels, width: width, height: height, border: border.color)
        return EdgeAnalysis(
            borderColor: border.color,
            matchFraction: border.fraction,
            isUniform: border.fraction >= uniformThreshold,
            contentBounds: bounds ?? CGRect(x: 0, y: 0, width: width, height: height),
            hasContent: bounds != nil
        )
    }

    /// True when two pixels are within the tolerance on every channel. Two (nearly) transparent
    /// pixels match whatever their colour.
    static func matches(_ lhs: SyntheticImages.Pixel, _ rhs: SyntheticImages.Pixel) -> Bool {
        matches(lhs, red: rhs.red, green: rhs.green, blue: rhs.blue, alpha: rhs.alpha)
    }

    @inline(__always)
    private static func matches(_ lhs: SyntheticImages.Pixel, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Bool {
        let limit = tolerance
        guard abs(Int(lhs.alpha) - Int(alpha)) <= limit else { return false }
        if Int(lhs.alpha) <= limit && Int(alpha) <= limit { return true }
        return abs(Int(lhs.red) - Int(red)) <= limit
            && abs(Int(lhs.green) - Int(green)) <= limit
            && abs(Int(lhs.blue) - Int(blue)) <= limit
    }

    private static func pixel(_ pixels: UnsafeBufferPointer<UInt8>, _ x: Int, _ y: Int, width: Int) -> SyntheticImages.Pixel {
        let base = (y * width + x) * 4
        return SyntheticImages.Pixel(red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2], alpha: pixels[base + 3])
    }

    private static func borderColor(
        pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int
    ) -> (color: SyntheticImages.Pixel, fraction: Double) {
        var counts: [UInt32: Int] = [:]
        var total = 0
        func add(_ x: Int, _ y: Int) {
            let value = pixel(pixels, x, y, width: width)
            let key = UInt32(value.red) << 24 | UInt32(value.green) << 16 | UInt32(value.blue) << 8 | UInt32(value.alpha)
            counts[key, default: 0] += 1
            total += 1
        }
        for x in 0..<width { add(x, 0) }
        if height > 1 {
            for x in 0..<width { add(x, height - 1) }
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                add(0, y)
                if width > 1 { add(width - 1, y) }
            }
        }
        func unpack(_ key: UInt32) -> SyntheticImages.Pixel {
            SyntheticImages.Pixel(
                red: UInt8(key >> 24), green: UInt8((key >> 16) & 0xFF), blue: UInt8((key >> 8) & 0xFF), alpha: UInt8(key & 0xFF)
            )
        }
        let distinct = counts.map { (color: unpack($0.key), count: $0.value, key: $0.key) }
        let candidates = distinct.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
            .prefix(candidateLimit)
        var best = (color: SyntheticImages.Pixel.white, matched: -1)
        for candidate in candidates {
            var matched = 0
            for other in distinct where matches(candidate.color, other.color) { matched += other.count }
            if matched > best.matched { best = (candidate.color, matched) }
        }
        return (best.color, total > 0 ? Double(best.matched) / Double(total) : 0)
    }

    private static func contentBounds(
        pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int, border: SyntheticImages.Pixel
    ) -> CGRect? {
        func differs(_ x: Int, _ y: Int) -> Bool {
            let base = (y * width + x) * 4
            return !matches(border, red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2], alpha: pixels[base + 3])
        }
        func rowHasContent(_ y: Int) -> Bool {
            for x in 0..<width where differs(x, y) { return true }
            return false
        }
        guard let top = (0..<height).first(where: rowHasContent),
              let bottom = (0..<height).reversed().first(where: rowHasContent) else { return nil }
        var left = width
        var right = -1
        for y in top...bottom {
            for x in 0..<left where differs(x, y) {
                left = x
                break
            }
            for x in stride(from: width - 1, to: right, by: -1) where differs(x, y) {
                right = x
                break
            }
        }
        guard right >= left else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
