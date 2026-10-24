import CoreGraphics
import Foundation

/// Generated test images: no fixture files, no screen. Used by the fakes, `snapctl gen-fixture`
/// and the renderer tests (design section 16). All images are 8-bit sRGB RGBA, premultiplied.
public enum SyntheticImages {
    /// One 8-bit RGBA pixel, straight (not premultiplied) alpha.
    public struct Pixel: Sendable, Hashable, CustomStringConvertible {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        public var alpha: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        public static let white = Pixel(red: 255, green: 255, blue: 255)
        public static let black = Pixel(red: 0, green: 0, blue: 0)
        public static let red = Pixel(red: 255, green: 0, blue: 0)
        public static let clear = Pixel(red: 0, green: 0, blue: 0, alpha: 0)

        /// Rec. 709 luminance, 0 to 255, ignoring alpha.
        public var luminance: Double {
            0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        }

        public var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }

        var cgColor: CGColor {
            CGColor(
                srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255,
                alpha: Double(alpha) / 255
            )
        }
    }

    public static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// A blank sRGB RGBA context with a top-left origin for drawing in pixel coordinates.
    public static func makeContext(width: Int, height: Int, flipped: Bool = true) -> CGContext? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: bitmapInfo
              ) else { return nil }
        if flipped {
            context.translateBy(x: 0, y: Double(height))
            context.scaleBy(x: 1, y: -1)
        }
        return context
    }

    /// A solid image.
    public static func solid(width: Int, height: Int, color: Pixel) -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The fake desktop: a diagonal blue-to-violet gradient with a light grid every 64 points and
    /// a darker line every 256, so crops and offsets are visible. `scale` is pixels per point.
    public static func gradientGrid(width: Int, height: Int, scale: Double = 1) -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        let colors = [
            CGColor(srgbRed: 0.24, green: 0.36, blue: 0.86, alpha: 1),
            CGColor(srgbRed: 0.62, green: 0.38, blue: 0.90, alpha: 1),
            CGColor(srgbRed: 0.96, green: 0.70, blue: 0.62, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: width, y: height), options: [.drawsAfterEndLocation]
            )
        }
        let step = max(64 * scale, 4)
        let lineWidth = max(scale, 1)
        var position = 0.0
        var index = 0
        while position <= Double(max(width, height)) {
            let major = index % 4 == 0
            context.setFillColor(CGColor(gray: major ? 0 : 1, alpha: major ? 0.22 : 0.18))
            if position <= Double(width) {
                context.fill(CGRect(x: position, y: 0, width: lineWidth, height: Double(height)))
            }
            if position <= Double(height) {
                context.fill(CGRect(x: 0, y: position, width: Double(width), height: lineWidth))
            }
            position += step
            index += 1
        }
        return context.makeImage()
    }

    /// Diagonal noise: every pixel differs, so there is no uniform border (beautify example A).
    public static func noise(width: Int, height: Int, seed: UInt64 = 1) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        for y in 0..<height {
            for x in 0..<width {
                // xorshift64*, plus a diagonal ramp so the image has visible structure.
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                let random = state &* 0x2545_F491_4F6C_DD1D
                let ramp = UInt8(truncatingIfNeeded: (x + y) * 255 / max(width + height - 2, 1))
                let base = (y * width + x) * 4
                bytes[base] = UInt8(truncatingIfNeeded: random) / 2 &+ ramp / 2
                bytes[base + 1] = UInt8(truncatingIfNeeded: random >> 8)
                bytes[base + 2] = UInt8(truncatingIfNeeded: random >> 16) / 2 &+ (255 - ramp) / 2
            }
        }
        return image(fromRGBA: bytes, width: width, height: height)
    }

    /// A background with one rectangular block, `block` in pixels with a top-left origin
    /// (beautify example B: white with a red block).
    public static func block(
        width: Int,
        height: Int,
        block: CGRect,
        background: Pixel = .white,
        color: Pixel = .red
    ) -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color.cgColor)
        context.fill(block)
        return context.makeImage()
    }

    /// A window capture with transparent rounded corners: a gray title bar and a white body.
    public static func transparentCornerWindow(width: Int, height: Int, cornerRadius: Double, scale: Double = 1)
        -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = min(cornerRadius, Double(min(width, height)) / 2)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.setFillColor(Pixel.white.cgColor)
        context.fill(bounds)
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(width), height: min(52 * scale, Double(height))))
        context.setFillColor(CGColor(srgbRed: 0.24, green: 0.36, blue: 0.86, alpha: 1))
        let line = max(scale, 1)
        var y = 80 * scale
        while y + 12 * scale < Double(height) - 20 * scale {
            context.fill(CGRect(x: 24 * scale, y: y, width: Double(width) * 0.6, height: 6 * line))
            y += 28 * scale
        }
        return context.makeImage()
    }

    /// Wraps straight-alpha RGBA bytes (row-major, top-left origin) in a CGImage.
    public static func image(fromRGBA bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard bytes.count == width * height * 4, let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The pixels of `image` as straight-alpha sRGB RGBA bytes, row-major from the top-left.
    public static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Un-premultiply so callers compare straight colors.
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return bytes
    }

    /// One pixel of `image`, `x` and `y` from the top-left. Nil when out of bounds.
    public static func pixel(of image: CGImage, x: Int, y: Int) -> Pixel? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let bytes = rgbaBytes(of: cropped) else { return nil }
        return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }
}

/// The named inputs `snapctl gen-fixture` writes and the acceptance checks use (design 10.2, 15).
public enum SyntheticFixture: String, Sendable, CaseIterable {
    case noise1x = "noise-1x"
    case noise2x = "noise-2x"
    case block1x = "block-1x"
    case block2x = "block-2x"
    case window1x = "window-1x"
    case window2x = "window-2x"

    /// Pixels per point; the PNG is written at 72 times this DPI.
    public var scale: Double {
        switch self {
        case .noise1x, .block1x, .window1x: 1
        case .noise2x, .block2x, .window2x: 2
        }
    }

    /// 600x400 points for every fixture, so the 2x variants are the 1200x800 px inputs of 10.2.
    public var pixelSize: (width: Int, height: Int) {
        (Int(600 * scale), Int(400 * scale))
    }

    /// The red block in pixels: points (50, 50) to (350, 250), margins 50/250/50/150 pt.
    public var blockRect: CGRect {
        CGRect(x: 50 * scale, y: 50 * scale, width: 300 * scale, height: 200 * scale)
    }

    public func makeImage() -> CGImage? {
        let size = pixelSize
        switch self {
        case .noise1x, .noise2x:
            return SyntheticImages.noise(width: size.width, height: size.height, seed: 7)
        case .block1x, .block2x:
            return SyntheticImages.block(width: size.width, height: size.height, block: blockRect)
        case .window1x, .window2x:
            return SyntheticImages.transparentCornerWindow(
                width: size.width, height: size.height, cornerRadius: 16 * scale, scale: scale
            )
        }
    }
}
