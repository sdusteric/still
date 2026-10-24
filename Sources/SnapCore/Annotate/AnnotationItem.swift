import CoreGraphics
import Foundation

/// The annotation kinds of M1 (design section 11).
public enum AnnotationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case rectangle, arrow, text, pixelate
}

/// A resize handle. Boxes (rectangle, pixelate) use the eight compass handles; an arrow uses
/// `start` and `end`. Text has none: it is moved, not resized.
public enum AnnotationHandle: String, Codable, Sendable, Hashable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end

    public static let boxHandles: [AnnotationHandle] = [
        .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
    ]

    /// Where the handle sits on `rect` (top-left origin).
    public func point(on rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft, .start: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight, .end: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

/// One annotation. Geometry is in points of the original (uncropped) image with a top-left
/// origin, so it does not move when the crop changes. `start` and `end` are the two corners of a
/// box, the tail and tip of an arrow, or the top-left corner of a text item (`end` unused).
public struct AnnotationItem: Codable, Sendable, Hashable, Identifiable {
    public static let defaultColor = RGBAColor(hex: "#FF3B30") ?? .black
    public static let defaultWidth = 4.0
    public static let strokeWidths: [Double] = [2, 4, 7]
    /// `annotateLastTextSize = 30`.
    public static let defaultFontSize = 30.0
    /// Rectangle corner radius in points.
    public static let rectangleRadius = 4.0
    /// Opacity of the Option fill on a rectangle.
    public static let fillOpacity = 0.2
    /// Arrow head length as a multiple of the stroke width.
    public static let arrowHeadFactor = 4.5
    /// Smallest box a drag creates, in points; anything smaller is dropped as a click.
    public static let minimumSize = 2.0

    public var id: UUID
    public var kind: AnnotationKind
    public var start: CGPoint
    public var end: CGPoint
    public var color: RGBAColor
    /// Stroke width in points (2, 4 or 7).
    public var width: Double
    /// Rectangle only: fill at 0.2 opacity (Option while drawing).
    public var filled: Bool
    public var text: String
    public var fontSize: Double
    /// Text only: drawn on a pill of `color` with white text.
    public var pill: Bool

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint,
        color: RGBAColor = AnnotationItem.defaultColor,
        width: Double = AnnotationItem.defaultWidth,
        filled: Bool = false,
        text: String = "",
        fontSize: Double = AnnotationItem.defaultFontSize,
        pill: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.width = width
        self.filled = filled
        self.text = text
        self.fontSize = fontSize
        self.pill = pill
    }

    public static func rectangle(_ rect: CGRect, color: RGBAColor = defaultColor, width: Double = defaultWidth,
                                 filled: Bool = false) -> AnnotationItem {
        AnnotationItem(
            kind: .rectangle, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY),
            color: color, width: width, filled: filled
        )
    }

    public static func arrow(from start: CGPoint, to end: CGPoint, color: RGBAColor = defaultColor,
                             width: Double = defaultWidth) -> AnnotationItem {
        AnnotationItem(kind: .arrow, start: start, end: end, color: color, width: width)
    }

    public static func text(_ text: String, at origin: CGPoint, color: RGBAColor = defaultColor,
                            fontSize: Double = defaultFontSize, pill: Bool = false) -> AnnotationItem {
        AnnotationItem(kind: .text, start: origin, end: origin, color: color, text: text, fontSize: fontSize, pill: pill)
    }

    public static func pixelate(_ rect: CGRect) -> AnnotationItem {
        AnnotationItem(
            kind: .pixelate, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY)
        )
    }

    /// The normalized box of `start` and `end` (rectangle, pixelate, arrow).
    public var box: CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    /// What the item covers on the image, including stroke, arrow head and text pill.
    public var bounds: CGRect {
        switch kind {
        case .rectangle:
            return box.insetBy(dx: -width / 2, dy: -width / 2)
        case .arrow:
            let pad = width * AnnotationItem.arrowHeadFactor / 2
            return box.insetBy(dx: -pad, dy: -pad)
        case .pixelate:
            return box
        case .text:
            return TextLayout.frame(for: self)
        }
    }

    /// The handles this item offers when selected.
    public var handles: [AnnotationHandle] {
        switch kind {
        case .rectangle, .pixelate: AnnotationHandle.boxHandles
        case .arrow: [.start, .end]
        case .text: []
        }
    }

    public func handlePoint(_ handle: AnnotationHandle) -> CGPoint {
        switch handle {
        case .start: start
        case .end: end
        default: handle.point(on: box)
        }
    }

    /// Whether a drag produced something worth keeping.
    public var isMeaningful: Bool {
        switch kind {
        case .text:
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .arrow:
            hypot(end.x - start.x, end.y - start.y) >= AnnotationItem.minimumSize * 2
        case .rectangle, .pixelate:
            box.width >= AnnotationItem.minimumSize && box.height >= AnnotationItem.minimumSize
        }
    }

    /// Hit-test in image points. `tolerance` widens thin strokes so they are easy to grab.
    public func contains(_ point: CGPoint, tolerance: Double) -> Bool {
        switch kind {
        case .rectangle:
            let reach = width / 2 + tolerance
            let outer = box.insetBy(dx: -reach, dy: -reach)
            guard outer.contains(point) else { return false }
            if filled { return true }
            let inner = box.insetBy(dx: reach, dy: reach)
            return inner.isNull || inner.isEmpty || !inner.contains(point)
        case .arrow:
            return AnnotationItem.distance(from: point, toSegment: start, end) <= width / 2 + tolerance
                || AnnotationItem.distance(from: point, toSegment: end, end) <= width * AnnotationItem.arrowHeadFactor / 2
        case .pixelate, .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Moved by a vector.
    public func offset(by dx: Double, _ dy: Double) -> AnnotationItem {
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return copy
    }

    /// `handle` dragged to `point`. `constrain` is Shift: a square box, or an arrow snapped to 45 degrees.
    public func resized(_ handle: AnnotationHandle, to point: CGPoint, constrain: Bool = false) -> AnnotationItem {
        var copy = self
        switch kind {
        case .text:
            return self
        case .arrow:
            if handle == .start {
                copy.start = constrain ? AnnotationItem.snap45(point, from: end) : point
            } else if handle == .end {
                copy.end = constrain ? AnnotationItem.snap45(point, from: start) : point
            }
            return copy
        case .rectangle, .pixelate:
            guard handle != .start, handle != .end else { return self }
            var minX = box.minX
            var minY = box.minY
            var maxX = box.maxX
            var maxY = box.maxY
            switch handle {
            case .topLeft: (minX, minY) = (point.x, point.y)
            case .top: minY = point.y
            case .topRight: (maxX, minY) = (point.x, point.y)
            case .right: maxX = point.x
            case .bottomRight: (maxX, maxY) = (point.x, point.y)
            case .bottom: maxY = point.y
            case .bottomLeft: (minX, maxY) = (point.x, point.y)
            case .left: minX = point.x
            case .start, .end: break
            }
            var rect = CGRect(
                x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)
            )
            if constrain {
                rect = AnnotationItem.squared(rect, anchoredOppositeTo: handle, original: box)
            }
            copy.start = CGPoint(x: rect.minX, y: rect.minY)
            copy.end = CGPoint(x: rect.maxX, y: rect.maxY)
            return copy
        }
    }

    /// Snaps `point` so the line from `origin` is at a multiple of 45 degrees.
    public static func snap45(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// A square of the larger side, kept on the corner opposite the dragged handle.
    static func squared(_ rect: CGRect, anchoredOppositeTo handle: AnnotationHandle, original: CGRect) -> CGRect {
        let side = max(rect.width, rect.height)
        let anchorLeft = [.topRight, .right, .bottomRight].contains(handle) || handle == .top || handle == .bottom
        let anchorTop = [.bottomLeft, .bottom, .bottomRight].contains(handle) || handle == .left || handle == .right
        let x = anchorLeft ? original.minX : rect.maxX - side
        let y = anchorTop ? original.minY : rect.maxY - side
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
