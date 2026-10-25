import CoreGraphics
import Foundation

/// The geometry of a freehand stroke (design 20.8): points kept at least 1.5 pt apart, drawn as
/// a Catmull-Rom spline converted to cubic Beziers. Pure, so it is tested without a context.
public enum FreehandPath {
    /// Points closer than this to the last kept point are dropped.
    public static let minimumDistance = 1.5
    /// Line segments per Bezier when the curve is flattened for hit tests and the midpoint.
    static let flatteningSteps = 12

    /// One cubic Bezier from `start` to `end`.
    public struct Segment: Equatable, Sendable {
        public var start: CGPoint
        public var control1: CGPoint
        public var control2: CGPoint
        public var end: CGPoint

        public func point(at t: Double) -> CGPoint {
            let u = 1 - t
            let a = u * u * u
            let b = 3 * u * u * t
            let c = 3 * u * t * t
            let d = t * t * t
            return CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
        }
    }

    /// Keeps the first point and every later point at least `minimumDistance` from the last kept one.
    public static func decimated(_ points: [CGPoint], minimumDistance: Double = FreehandPath.minimumDistance)
        -> [CGPoint] {
        var kept: [CGPoint] = []
        for point in points {
            guard let last = kept.last else {
                kept.append(point)
                continue
            }
            if hypot(point.x - last.x, point.y - last.y) >= minimumDistance { kept.append(point) }
        }
        return kept
    }

    /// `points` with `point` appended unless it is too close to the last one (the live drag).
    public static func appending(_ point: CGPoint, to points: [CGPoint]) -> [CGPoint] {
        guard let last = points.last else { return [point] }
        return hypot(point.x - last.x, point.y - last.y) >= minimumDistance ? points + [point] : points
    }

    /// The spline through `points` as cubic Beziers. The first and last points repeat as their own
    /// neighbors, so the curve starts and ends exactly on them.
    public static func segments(for points: [CGPoint]) -> [Segment] {
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).map { index in
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            return Segment(
                start: p1,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                end: p2
            )
        }
    }

    /// The stroke as a path: a dot for one point, the spline for more.
    public static func cgPath(for points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for segment in segments(for: points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        return path
    }

    /// The spline as a polyline of `flatteningSteps` lines per segment.
    public static func flattened(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var line = [points[0]]
        for segment in segments(for: points) {
            for step in 1...flatteningSteps {
                line.append(segment.point(at: Double(step) / Double(flatteningSteps)))
            }
        }
        return line
    }

    /// The extent of the points (the curve stays within a hair of it).
    public static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The shortest distance from `point` to the curve through `points`.
    public static func distance(from point: CGPoint, to points: [CGPoint]) -> Double {
        let line = flattened(points)
        guard line.count >= 2 else {
            return line.first.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .infinity
        }
        var best = Double.infinity
        for index in 0..<(line.count - 1) {
            best = min(best, AnnotationItem.distance(from: point, toSegment: line[index], line[index + 1]))
        }
        return best
    }

    /// The point halfway along the curve by length.
    public static func midpoint(of points: [CGPoint]) -> CGPoint? {
        let line = flattened(points)
        guard line.count >= 2 else { return line.first }
        let lengths = zip(line, line.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let half = lengths.reduce(0, +) / 2
        var travelled = 0.0
        for (index, length) in lengths.enumerated() {
            if travelled + length >= half, length > 0 {
                let t = (half - travelled) / length
                return CGPoint(
                    x: line[index].x + (line[index + 1].x - line[index].x) * t,
                    y: line[index].y + (line[index + 1].y - line[index].y) * t
                )
            }
            travelled += length
        }
        return line.last
    }
}
