import CoreGraphics
import Foundation

/// `CGWindowID`.
public typealias WindowID = UInt32

/// One entry of the on-screen window list, as `CGWindowListCopyWindowInfo` reports it (design 6.5).
public struct WindowInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: WindowID
    public var ownerPID: Int32
    /// Owner name ("Notes", "Finder"); CGWindowList may leave it out.
    public var ownerName: String?
    public var bundleID: String?
    /// Window title. Not needed for hit-testing and often missing without Screen Recording permission.
    public var name: String?
    /// Frame in points with a global top-left origin.
    public var frame: CGRect
    /// `kCGWindowLayer`: 0 for normal windows, 24 for the menu bar, 20 for the Dock, and so on.
    public var layer: Int
    public var alpha: Double
    /// Position in the front-to-back list, 0 is frontmost.
    public var order: Int

    public init(
        id: WindowID,
        ownerPID: Int32,
        ownerName: String? = nil,
        bundleID: String? = nil,
        name: String? = nil,
        frame: CGRect,
        layer: Int = 0,
        alpha: Double = 1,
        order: Int
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.name = name
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.order = order
    }
}

/// Window layers that matter to Snap. Values are `CGWindowLevelForKey` results on macOS 27.
public enum WindowLayer {
    public static let normal = 0
    public static let dock = 20
    public static let mainMenu = 24
    public static let statusItems = 25
    /// Finder's desktop-icon window, verified through CGWindowList on this Mac (design 6.3).
    public static let desktopIcons = -2_147_483_603
}
