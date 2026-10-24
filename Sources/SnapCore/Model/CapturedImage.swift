import CoreGraphics
import Foundation

/// A captured bitmap and the scale it was captured at (pixels per point).
public struct CapturedImage: Sendable {
    public var cgImage: CGImage
    public var scale: Double
    /// The display it came from; nil for a single-window capture.
    public var displayID: DisplayID?

    public init(cgImage: CGImage, scale: Double, displayID: DisplayID? = nil) {
        self.cgImage = cgImage
        self.scale = scale
        self.displayID = displayID
    }

    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }
    public var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    /// Size in points: pixels divided by the scale.
    public var pointSize: CGSize {
        let divisor = scale > 0 ? scale : 1
        return CGSize(width: Double(cgImage.width) / divisor, height: Double(cgImage.height) / divisor)
    }

    /// PNG pHYs density for this scale: 72 DPI times the scale (design D6).
    public var dpi: Double { 72 * (scale > 0 ? scale : 1) }
}
