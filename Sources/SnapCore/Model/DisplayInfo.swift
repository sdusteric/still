import CoreGraphics
import Foundation

/// `CGDirectDisplayID`, the value both `NSScreen` ("NSScreenNumber") and `SCDisplay.displayID` report.
public typealias DisplayID = UInt32

/// One display as the capture pipeline sees it (design section 6.1).
public struct DisplayInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: DisplayID
    /// Frame in points with a global top-left origin, the space CGWindowList and SCDisplay use.
    public var frameTopLeft: CGRect
    /// Backing scale factor: 2 on the 5K panel, usually 1 on a 3440x1440 ultrawide.
    public var scale: Double
    /// The display color space name (for example "kCGColorSpaceDisplayP3"), nil when unknown.
    public var colorSpaceName: String?

    public init(id: DisplayID, frameTopLeft: CGRect, scale: Double, colorSpaceName: String? = nil) {
        self.id = id
        self.frameTopLeft = frameTopLeft
        self.scale = scale
        self.colorSpaceName = colorSpaceName
    }

    public var pointSize: CGSize { frameTopLeft.size }
    public var pixelWidth: Int { Int((frameTopLeft.width * scale).rounded()) }
    public var pixelHeight: Int { Int((frameTopLeft.height * scale).rounded()) }

    /// Parses `WxH@S` in pixels (for example `5120x2880@2`), the form `snapctl --display` takes.
    /// The display is placed at the origin.
    public init?(spec: String, id: DisplayID = 1) {
        let parts = spec.lowercased().split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let size = parts[0].split(separator: "x", omittingEmptySubsequences: false)
        guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 else {
            return nil
        }
        var scale = 1.0
        if parts.count == 2 {
            guard let parsed = Double(parts[1]), parsed > 0 else { return nil }
            scale = parsed
        }
        self.init(
            id: id,
            frameTopLeft: CGRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale),
            scale: scale,
            colorSpaceName: nil
        )
    }
}

extension DisplayInfo {
    /// The 5K panel on this Mac: 2560x1440 points at scale 2 (5120x2880 pixels).
    public static let fake5K = DisplayInfo(
        id: 1,
        frameTopLeft: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        scale: 2,
        colorSpaceName: CGColorSpace.displayP3 as String
    )

    /// An ultrawide at 3440x1440 points, scale 1.
    public static let fakeUltrawide = DisplayInfo(
        id: 2,
        frameTopLeft: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        scale: 1,
        colorSpaceName: CGColorSpace.sRGB as String
    )

    /// The two displays side by side: the 5K panel as primary, the ultrawide to its right.
    public static let fakeSideBySide: [DisplayInfo] = [
        fake5K,
        DisplayInfo(
            id: 2,
            frameTopLeft: CGRect(x: 2560, y: 0, width: 3440, height: 1440),
            scale: 1,
            colorSpaceName: CGColorSpace.sRGB as String
        ),
    ]
}
