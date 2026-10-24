import CoreGraphics
import Foundation

/// Converts between `NSScreen` coordinates (global, origin at the bottom-left of the primary
/// display) and the global top-left space CGWindowList and `SCDisplay.frame` use (design 6.1).
///
/// The flip is `y_cg = primaryHeight - (y_ns + h)`. Only the primary display's height matters,
/// whatever the other displays' heights, scales or positions are.
public struct CoordinateSpace: Sendable, Hashable {
    public let primaryHeight: Double

    public init(primaryHeight: Double) {
        self.primaryHeight = primaryHeight
    }

    /// Uses the display at the global origin as primary, or the first one when none is there.
    public init(displays: [DisplayInfo]) {
        let primary = displays.first { $0.frameTopLeft.origin == .zero } ?? displays.first
        self.init(primaryHeight: Double(primary?.frameTopLeft.height ?? 0))
    }

    // MARK: Global flips

    public func topLeft(fromBottomLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public func bottomLeft(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public func topLeft(fromBottomLeft rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - (rect.minY + rect.height), width: rect.width, height: rect.height)
    }

    public func bottomLeft(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - (rect.minY + rect.height), width: rect.width, height: rect.height)
    }

    /// The `NSScreen.frame` a display has in this layout.
    public func screenFrame(of display: DisplayInfo) -> CGRect {
        bottomLeft(fromTopLeft: display.frameTopLeft)
    }

    // MARK: Display lookup

    /// The display whose frame contains `point` (global top-left). Frames are half-open, so a point
    /// on a shared edge belongs to the display on its right or below.
    public static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frameTopLeft.contains(point) }
    }

    /// The display containing `point`, else the one with the nearest edge. Nil only for an empty list.
    public static func nearestDisplay(to point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let inside = display(containing: point, in: displays) { return inside }
        return displays.min { distance(from: point, to: $0.frameTopLeft) < distance(from: point, to: $1.frameTopLeft) }
    }

    /// The display where most of `rect` (global top-left) lies; ties go to the earlier display.
    public static func display(mostlyContaining rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (display: DisplayInfo, area: Double)?
        for display in displays {
            let overlap = display.frameTopLeft.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        return best?.display
    }

    // MARK: Display-local flips

    /// A global top-left rect as display-local top-left points (origin at the display's corner).
    public static func localRect(_ rect: CGRect, in display: DisplayInfo) -> CGRect {
        rect.offsetBy(dx: -display.frameTopLeft.minX, dy: -display.frameTopLeft.minY)
    }

    public static func globalRect(fromLocal rect: CGRect, in display: DisplayInfo) -> CGRect {
        rect.offsetBy(dx: display.frameTopLeft.minX, dy: display.frameTopLeft.minY)
    }

    /// A global top-left rect as view coordinates inside that display's overlay view (origin at the
    /// bottom-left of the screen, y up), which is where the overlay draws.
    public static func viewRect(fromGlobal rect: CGRect, in display: DisplayInfo) -> CGRect {
        let local = localRect(rect, in: display)
        return CGRect(
            x: local.minX,
            y: display.frameTopLeft.height - (local.minY + local.height),
            width: local.width,
            height: local.height
        )
    }

    public static func globalRect(fromView rect: CGRect, in display: DisplayInfo) -> CGRect {
        let local = CGRect(
            x: rect.minX,
            y: display.frameTopLeft.height - (rect.minY + rect.height),
            width: rect.width,
            height: rect.height
        )
        return globalRect(fromLocal: local, in: display)
    }

    public static func viewPoint(fromGlobal point: CGPoint, in display: DisplayInfo) -> CGPoint {
        CGPoint(
            x: point.x - display.frameTopLeft.minX,
            y: display.frameTopLeft.height - (point.y - display.frameTopLeft.minY)
        )
    }

    public static func globalPoint(fromView point: CGPoint, in display: DisplayInfo) -> CGPoint {
        CGPoint(
            x: point.x + display.frameTopLeft.minX,
            y: display.frameTopLeft.minY + display.frameTopLeft.height - point.y
        )
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
