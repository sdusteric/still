import CoreGraphics
import Foundation

/// Picks the window under the pointer in window mode (design 6.5). Pure: it works on the window
/// list snapshot taken when the overlay appeared.
public struct WindowHitTester: Sendable, Hashable {
    /// Smallest normal window that can be selected, in points.
    public static let minimumSide = 40.0
    /// Thickest the menu bar or Dock can be and still be selected, in points. On macOS 27 the
    /// Dock's window covers the whole display in front of every app window, so it never is.
    public static let maximumBarThickness = 200.0

    public let ownPID: Int32

    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    /// Layer 0 windows, plus the menu bar and the Dock, which are selectable as in CleanShot.
    public static func isSelectableLayer(_ layer: Int) -> Bool {
        layer == WindowLayer.normal || layer == WindowLayer.mainMenu || layer == WindowLayer.dock
    }

    /// Whether `window` can be selected at all: a selectable layer, visible, not Snap's own and
    /// big enough. The menu bar is under 40 points tall, so the size rule only applies to normal
    /// windows; the bars need a non-empty frame no thicker than `maximumBarThickness`.
    public func isSelectable(_ window: WindowInfo) -> Bool {
        guard window.ownerPID != ownPID, window.alpha > 0, WindowHitTester.isSelectableLayer(window.layer) else {
            return false
        }
        let frame = window.frame
        if window.layer == WindowLayer.normal {
            return frame.width >= WindowHitTester.minimumSide && frame.height >= WindowHitTester.minimumSide
        }
        return frame.width > 0 && frame.height > 0
            && min(frame.width, frame.height) <= WindowHitTester.maximumBarThickness
    }

    /// The selectable windows, front to back.
    public func candidates(in windows: [WindowInfo]) -> [WindowInfo] {
        windows.filter(isSelectable).sorted { $0.order < $1.order }
    }

    /// The topmost selectable window containing `point` (global top-left points), if any.
    public func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        candidates(in: windows).first { $0.frame.contains(point) }
    }
}
