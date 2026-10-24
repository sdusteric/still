import CoreGraphics
import Foundation

/// Modifier keys held during a selection drag.
public struct DragModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Shift: constrain to a square.
    public static let square = DragModifiers(rawValue: 1 << 0)
    /// Option: the anchor is the centre and the pointer sets the half size.
    public static let fromCenter = DragModifiers(rawValue: 1 << 1)
}

public enum ArrowDirection: Sendable, Hashable, CaseIterable {
    case left, right, up, down
}

/// Selection maths for the area overlay (design section 7). All rects are in global top-left
/// points, as `OverlaySelection.area` carries them, and stay inside the display the drag started on.
public struct SelectionGeometry: Sendable, Hashable {
    /// A selection under this size in either direction counts as a click on mouse-up.
    public static let minimumSide = 4.0
    public static let nudgeStep = 1.0
    public static let largeNudgeStep = 10.0

    public let display: DisplayInfo

    public init(display: DisplayInfo) {
        self.display = display
    }

    public var bounds: CGRect { display.frameTopLeft }
    public var scale: Double { display.scale > 0 ? display.scale : 1 }
    /// One physical pixel in points.
    public var pixel: Double { 1 / scale }

    // MARK: Normalize, clamp, snap

    /// The rect spanned by two corners, whichever way the drag went.
    public static func normalize(_ first: CGPoint, _ second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    public static func normalize(_ rect: CGRect) -> CGRect { rect.standardized }

    /// Moves `point` into the display (edges included).
    public func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// Fits `rect` into the display: shrinks it when it is larger, else shifts it back inside.
    public func clamp(_ rect: CGRect) -> CGRect {
        let standard = rect.standardized
        let width = min(standard.width, bounds.width)
        let height = min(standard.height, bounds.height)
        let x = min(max(standard.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(standard.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Rounds a coordinate to the pixel grid of the display (multiples of 1/scale from its corner).
    public func snapX(_ value: Double) -> Double { snap(value, origin: bounds.minX) }
    public func snapY(_ value: Double) -> Double { snap(value, origin: bounds.minY) }

    public func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snapX(point.x), y: snapY(point.y))
    }

    /// Snaps each edge, so the size is the difference of two grid lines.
    public func snap(_ rect: CGRect) -> CGRect {
        let standard = rect.standardized
        let minX = snapX(standard.minX)
        let minY = snapY(standard.minY)
        return CGRect(x: minX, y: minY, width: snapX(standard.maxX) - minX, height: snapY(standard.maxY) - minY)
    }

    private func snap(_ value: Double, origin: Double) -> Double {
        origin + ((value - origin) * scale).rounded() / scale
    }

    // MARK: Dragging

    /// The selection for a drag from `anchor` to `pointer`. Both are clamped to the display and
    /// snapped. Shift makes it a square (as large as fits), Option makes `anchor` the centre.
    public func dragRect(anchor: CGPoint, pointer: CGPoint, modifiers: DragModifiers = []) -> CGRect {
        let start = snap(clamp(anchor))
        let end = snap(clamp(pointer))
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let room = (
            left: start.x - bounds.minX, right: bounds.maxX - start.x,
            up: start.y - bounds.minY, down: bounds.maxY - start.y
        )

        if modifiers.contains(.fromCenter) {
            var halfWidth = min(abs(deltaX), room.left, room.right)
            var halfHeight = min(abs(deltaY), room.up, room.down)
            if modifiers.contains(.square) {
                let side = min(max(abs(deltaX), abs(deltaY)), room.left, room.right, room.up, room.down)
                halfWidth = side
                halfHeight = side
            }
            return snap(CGRect(
                x: start.x - halfWidth, y: start.y - halfHeight,
                width: halfWidth * 2, height: halfHeight * 2
            ))
        }

        var width = abs(deltaX)
        var height = abs(deltaY)
        let signX: Double = deltaX < 0 ? -1 : 1
        let signY: Double = deltaY < 0 ? -1 : 1
        if modifiers.contains(.square) {
            let limitX = signX > 0 ? room.right : room.left
            let limitY = signY > 0 ? room.down : room.up
            let side = min(max(width, height), limitX, limitY)
            width = side
            height = side
        }
        return snap(SelectionGeometry.normalize(start, CGPoint(x: start.x + signX * width, y: start.y + signY * height)))
    }

    // MARK: Keyboard

    /// Arrow keys: moves the selection by 1 point (10 with Shift), staying inside the display.
    public func nudged(_ rect: CGRect, _ direction: ArrowDirection, large: Bool = false) -> CGRect {
        let step = large ? SelectionGeometry.largeNudgeStep : SelectionGeometry.nudgeStep
        switch direction {
        case .left: return translated(rect, dx: -step, dy: 0)
        case .right: return translated(rect, dx: step, dy: 0)
        case .up: return translated(rect, dx: 0, dy: -step)
        case .down: return translated(rect, dx: 0, dy: step)
        }
    }

    /// Cmd+arrow: right and down grow the selection by 1 point (10 with Shift), left and up shrink
    /// it. The top-left corner stays put. It never goes below one pixel or past the display.
    public func resized(_ rect: CGRect, _ direction: ArrowDirection, large: Bool = false) -> CGRect {
        let step = large ? SelectionGeometry.largeNudgeStep : SelectionGeometry.nudgeStep
        let base = clamp(snap(rect))
        var width = base.width
        var height = base.height
        switch direction {
        case .left: width -= step
        case .right: width += step
        case .up: height -= step
        case .down: height += step
        }
        width = min(max(width, pixel), bounds.maxX - base.minX)
        height = min(max(height, pixel), bounds.maxY - base.minY)
        return snap(CGRect(x: base.minX, y: base.minY, width: width, height: height))
    }

    /// Moves `rect` by a delta without resizing it, stopping at the display edges. Space-drag and
    /// the arrow keys use it.
    public func translated(_ rect: CGRect, dx: Double, dy: Double) -> CGRect {
        let standard = rect.standardized
        let moveX = clampDelta(snapDelta(dx), lower: bounds.minX - standard.minX, upper: bounds.maxX - standard.maxX)
        let moveY = clampDelta(snapDelta(dy), lower: bounds.minY - standard.minY, upper: bounds.maxY - standard.maxY)
        return snap(standard.offsetBy(dx: moveX, dy: moveY))
    }

    private func snapDelta(_ value: Double) -> Double { (value * scale).rounded() / scale }

    // A rect larger than the display has lower > upper; pin it to its low edge.
    private func clampDelta(_ value: Double, lower: Double, upper: Double) -> Double {
        lower > upper ? lower : min(max(value, lower), upper)
    }

    // MARK: Click rule and crop

    /// True when the finished selection is too small to be a deliberate area (design section 7).
    public func isClick(_ rect: CGRect) -> Bool {
        let standard = rect.standardized
        return standard.width < SelectionGeometry.minimumSide || standard.height < SelectionGeometry.minimumSide
    }

    /// The crop of the display's frozen image for a selection: display-local pixels, whole numbers,
    /// clamped to the image. Each edge rounds on its own so neighbouring selections tile.
    public func cropRect(for rect: CGRect) -> CGRect {
        let standard = rect.standardized
        let pixelWidth = Double(display.pixelWidth)
        let pixelHeight = Double(display.pixelHeight)
        let minX = min(max(((standard.minX - bounds.minX) * scale).rounded(), 0), pixelWidth)
        let maxX = min(max(((standard.maxX - bounds.minX) * scale).rounded(), 0), pixelWidth)
        let minY = min(max(((standard.minY - bounds.minY) * scale).rounded(), 0), pixelHeight)
        let maxY = min(max(((standard.maxY - bounds.minY) * scale).rounded(), 0), pixelHeight)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// One drag in progress: the anchor, the pointer and the modifiers decide the rect. Holding Space
/// moves the whole selection instead of resizing it, and the anchor moves with it, so letting go
/// of Space carries on from the new place.
public struct SelectionDrag: Sendable, Hashable {
    public let geometry: SelectionGeometry
    public private(set) var anchor: CGPoint
    public private(set) var pointer: CGPoint
    public private(set) var modifiers: DragModifiers
    public private(set) var rect: CGRect
    private var lastRawPointer: CGPoint

    public init(start: CGPoint, geometry: SelectionGeometry, modifiers: DragModifiers = []) {
        let anchor = geometry.snap(geometry.clamp(start))
        self.geometry = geometry
        self.anchor = anchor
        self.pointer = anchor
        self.modifiers = modifiers
        self.lastRawPointer = start
        self.rect = geometry.dragRect(anchor: anchor, pointer: anchor, modifiers: modifiers)
    }

    /// Feeds a pointer position. With `moving` (Space held) the selection translates by the pointer's
    /// travel since the last event; otherwise the rect is resized from the anchor.
    @discardableResult
    public mutating func update(pointer location: CGPoint, modifiers: DragModifiers = [], moving: Bool = false) -> CGRect {
        self.modifiers = modifiers
        defer { lastRawPointer = location }
        if moving {
            let moved = geometry.translated(
                rect, dx: location.x - lastRawPointer.x, dy: location.y - lastRawPointer.y
            )
            let shift = CGPoint(x: moved.minX - rect.minX, y: moved.minY - rect.minY)
            anchor = CGPoint(x: anchor.x + shift.x, y: anchor.y + shift.y)
            pointer = CGPoint(x: pointer.x + shift.x, y: pointer.y + shift.y)
            rect = moved
        } else {
            pointer = geometry.snap(geometry.clamp(location))
            rect = geometry.dragRect(anchor: anchor, pointer: pointer, modifiers: modifiers)
        }
        return rect
    }
}
