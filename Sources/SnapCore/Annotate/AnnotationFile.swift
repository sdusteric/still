import CoreGraphics
import Foundation

/// The editable side of an edited capture (design 20.4, `item.json` version 3): the annotations,
/// the crop and the Background preset that was applied on top, kept as `annotations.json` next to
/// the original PNG. Reopening the capture rebuilds the `AnnotationDocument` from the original and
/// this file, so every item stays editable instead of being flattened into the edited PNG.
public struct AnnotationFile: Codable, Sendable, Equatable {
    public static let fileName = "annotations.json"
    public static let currentVersion = 1

    public var version: Int
    /// The crop in points of the original image, nil for the whole image.
    public var cropRect: CGRect?
    /// Back to front, in points of the original (uncropped) image.
    public var items: [AnnotationItem]
    /// The Background preset drawn around the annotated image, nil when none is applied.
    public var background: BackgroundPreset?

    public init(cropRect: CGRect? = nil, items: [AnnotationItem] = [], background: BackgroundPreset? = nil) {
        version = Self.currentVersion
        self.cropRect = cropRect
        self.items = items
        self.background = background
    }

    /// The annotations and crop of `document`, with `background` on top.
    public init(document: AnnotationDocument, background: BackgroundPreset? = nil) {
        self.init(cropRect: document.cropRect, items: document.items, background: background)
    }

    /// No annotations and no crop: the edit is the Background alone.
    public var hasAnnotations: Bool { !items.isEmpty || cropRect != nil }

    /// The editor's document on the original capture, with every item editable.
    public func document(image: CGImage, scale: Double) -> AnnotationDocument {
        AnnotationDocument(image: image, scale: scale, cropRect: cropRect, items: items)
    }

    /// The edited image: the annotations burned into the original, then the Background preset
    /// around it when one is set.
    public func render(original image: CGImage, scale: Double) throws -> (image: CGImage, scale: Double) {
        var output = image
        if hasAnnotations { output = try Flattener.flatten(document(image: image, scale: scale)) }
        guard let background else { return (output, scale) }
        let rendered = try BeautifyRenderer.render(output, scale: scale, preset: background)
        return (rendered.image, rendered.geometry.outputScale)
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case version, cropRect, items, background
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        // `[x, y, w, h]` like `item.json`'s screen rect, so the file reads plainly.
        let crop = try container.decodeIfPresent([Double].self, forKey: .cropRect)
        cropRect = crop.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        items = try container.decodeIfPresent([AnnotationItem].self, forKey: .items) ?? []
        background = try container.decodeIfPresent(BackgroundPreset.self, forKey: .background)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(cropRect.map { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: .cropRect)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(background, forKey: .background)
    }
}
