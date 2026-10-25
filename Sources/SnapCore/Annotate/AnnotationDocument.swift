import CoreGraphics
import Foundation

/// The annotate editor's document (design section 11): the original capture, a non-destructive
/// crop and the ordered annotations, with pure editing operations. It is a value, so the view
/// layer builds undo on snapshots of it. Geometry is in points of the original image, top-left
/// origin; `scale` converts to pixels.
public struct AnnotationDocument: Sendable, Equatable {
    /// Crop edges within this many pixels of an image edge snap to it.
    public static let cropSnapPixels = 6.0
    /// Smallest crop, in points.
    public static let minimumCrop = 8.0
    /// How far Duplicate offsets the copy, in points.
    public static let duplicateOffset = 12.0

    public let image: CGImage
    /// Pixels per point of `image`.
    public let scale: Double
    /// The crop in image points, nil for the whole image.
    public private(set) var cropRect: CGRect?
    /// Back to front.
    public private(set) var items: [AnnotationItem]

    public init(image: CGImage, scale: Double, cropRect: CGRect? = nil, items: [AnnotationItem] = []) {
        self.image = image
        self.scale = scale > 0 ? scale : 1
        self.items = items
        self.cropRect = nil
        if let cropRect { crop(to: cropRect) }
    }

    public static func == (lhs: AnnotationDocument, rhs: AnnotationDocument) -> Bool {
        lhs.image === rhs.image && lhs.scale == rhs.scale && lhs.cropRect == rhs.cropRect && lhs.items == rhs.items
    }

    /// The whole image in points.
    public var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: Double(image.width) / scale, height: Double(image.height) / scale)
    }

    /// What export produces, in points: the crop or the whole image.
    public var outputRect: CGRect { cropRect ?? imageBounds }

    /// The export size in pixels.
    public var outputPixelSize: (width: Int, height: Int) {
        let rect = outputRect
        return (max(Int((rect.width * scale).rounded()), 1), max(Int((rect.height * scale).rounded()), 1))
    }

    public func item(_ id: UUID) -> AnnotationItem? {
        items.first { $0.id == id }
    }

    public func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: Steps

    /// Each step's number: its order among the step items, so deleting step 2 renumbers 3 to 2.
    public var stepNumbers: [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        for item in items where item.kind == .step { numbers[item.id] = numbers.count + 1 }
        return numbers
    }

    /// The number shown on step `id`, nil when `id` is not a step.
    public func stepNumber(of id: UUID) -> Int? {
        stepNumbers[id]
    }

    // MARK: Hit-testing

    /// The topmost item under `point`, nil when none.
    public func hitTest(_ point: CGPoint, tolerance: Double = 4) -> UUID? {
        items.last { $0.contains(point, tolerance: tolerance) }?.id
    }

    /// The handle of item `id` within `radius` of `point`, nil when none.
    public func handle(of id: UUID, at point: CGPoint, radius: Double) -> AnnotationHandle? {
        guard let item = item(id) else { return nil }
        return item.handles
            .map { ($0, hypot(item.handlePoint($0).x - point.x, item.handlePoint($0).y - point.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: Editing

    /// Appends `item` on top and returns its id.
    @discardableResult
    public mutating func add(_ item: AnnotationItem) -> UUID {
        items.append(item)
        return item.id
    }

    /// Replaces the item with the same id. Returns false when there is none.
    @discardableResult
    public mutating func update(_ item: AnnotationItem) -> Bool {
        guard let index = index(of: item.id) else { return false }
        items[index] = item
        return true
    }

    @discardableResult
    public mutating func move(_ id: UUID, by dx: Double, _ dy: Double) -> Bool {
        guard let index = index(of: id) else { return false }
        items[index] = items[index].offset(by: dx, dy)
        return true
    }

    /// Arrow-key nudge: 1 point, or 10 with Shift.
    @discardableResult
    public mutating func nudge(_ id: UUID, dx: Int, dy: Int, large: Bool = false) -> Bool {
        let step = large ? 10.0 : 1.0
        return move(id, by: Double(dx) * step, Double(dy) * step)
    }

    @discardableResult
    public mutating func resize(_ id: UUID, handle: AnnotationHandle, to point: CGPoint, constrain: Bool = false)
        -> Bool {
        guard let index = index(of: id) else { return false }
        items[index] = items[index].resized(handle, to: point, constrain: constrain)
        return true
    }

    @discardableResult
    public mutating func delete(_ id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        items.remove(at: index)
        return true
    }

    /// A copy of item `id`, offset down and right, placed on top. Returns the new id.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let original = item(id) else { return nil }
        var copy = original.offset(by: Self.duplicateOffset, Self.duplicateOffset)
        copy.id = UUID()
        items.append(copy)
        return copy.id
    }

    // MARK: Crop

    /// Sets the crop: clamped to the image, edges within 6 px of an image edge snapped to it,
    /// at least 8 points. A crop equal to the whole image clears it.
    public mutating func crop(to rect: CGRect) {
        let bounds = imageBounds
        var clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width >= Self.minimumCrop, clipped.height >= Self.minimumCrop else { return }
        let snap = Self.cropSnapPixels / scale
        var minX = clipped.minX
        var minY = clipped.minY
        var maxX = clipped.maxX
        var maxY = clipped.maxY
        if minX - bounds.minX <= snap { minX = bounds.minX }
        if minY - bounds.minY <= snap { minY = bounds.minY }
        if bounds.maxX - maxX <= snap { maxX = bounds.maxX }
        if bounds.maxY - maxY <= snap { maxY = bounds.maxY }
        // Whole pixels, so the export has no half-covered edge.
        minX = (minX * scale).rounded() / scale
        minY = (minY * scale).rounded() / scale
        maxX = (maxX * scale).rounded() / scale
        maxY = (maxY * scale).rounded() / scale
        clipped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        cropRect = clipped == bounds ? nil : clipped
    }

    public mutating func resetCrop() {
        cropRect = nil
    }
}
