import CoreGraphics
import CoreImage
import Foundation

/// The "Blurred capture" background (design 20.9): the capture aspect-filled to the canvas, blurred
/// with a radius of 6% of the canvas's long side, then darkened a little and made more saturated so
/// the card stands out.
public enum BlurredCaptureBackground {
    /// Blur radius as a fraction of the canvas long side.
    public static let radiusFraction = 0.06
    public static let brightness = -0.06
    public static let saturation = 1.15
    /// The blur works on a copy no larger than this sigma in pixels, then scales up: a blur this
    /// wide has no detail left to lose.
    static let workingSigma = 6.0

    /// The blur radius in canvas pixels. The Gaussian sigma is half of it, as for the image blur.
    public static func radius(width: Int, height: Int) -> Double {
        Double(max(width, height)) * radiusFraction
    }

    /// An opaque image of `width` x `height` pixels built from `capture`, or nil when a context cannot be made.
    public static func image(from capture: CGImage, width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard width > 0, height > 0, capture.width > 0, capture.height > 0 else { return nil }
        let sigma = radius(width: width, height: height) / 2
        let shrink = min(1, workingSigma / max(sigma, 0.001))
        let smallWidth = max(Int((Double(width) * shrink).rounded()), 1)
        let smallHeight = max(Int((Double(height) * shrink).rounded()), 1)
        guard let small = filled(capture, width: smallWidth, height: smallHeight, space: space) else { return nil }

        let input = CIImage(cgImage: small)
        let extent = input.extent
        var output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma * Double(smallWidth) / Double(width))
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(saturation, forKey: kCIInputSaturationKey)
            controls.setValue(1.0, forKey: kCIInputContrastKey)
            output = controls.outputImage ?? output
        }
        output = output.cropped(to: extent)
        if smallWidth != width || smallHeight != height {
            output = output.clampedToExtent()
                .transformed(by: CGAffineTransform(
                    scaleX: Double(width) / Double(smallWidth), y: Double(height) / Double(smallHeight)
                ))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let context = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: space])
        return context.createCGImage(
            output, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: space
        )
    }

    /// Draws the background into `context` over `bounds` (bottom-left origin).
    public static func draw(
        _ capture: CGImage, in context: CGContext, bounds: CGRect, space: CGColorSpace
    ) {
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        guard let image = image(from: capture, width: width, height: height, space: space) else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    /// The capture aspect-filled onto an opaque bitmap. Transparent capture corners show the
    /// capture's mean colour instead of nothing.
    private static func filled(_ capture: CGImage, width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(meanColor(of: capture, space: space))
        context.fill(bounds)
        let factor = max(Double(width) / Double(capture.width), Double(height) / Double(capture.height))
        let size = CGSize(width: Double(capture.width) * factor, height: Double(capture.height) * factor)
        context.draw(capture, in: CGRect(
            x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2,
            width: size.width, height: size.height
        ))
        return context.makeImage()
    }

    private static func meanColor(of image: CGImage, space: CGColorSpace) -> CGColor {
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return CGColor(gray: 0.5, alpha: 1) }
        context.interpolationQuality = .medium
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        let components: [CGFloat] = [CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255, 1]
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
