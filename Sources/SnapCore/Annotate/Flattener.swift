import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Text measurement for annotation text: 30 pt semibold system font by default, one or more lines.
public enum TextLayout {
    /// `NSFont.Weight.semibold`.
    static let semiboldWeight = 0.3

    public static func font(size: Double) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: semiboldWeight] as CFDictionary
        let attributes = [kCTFontTraitsAttribute: traits] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Padding around text drawn on a pill, in points.
    public static func pillPadding(fontSize: Double) -> CGSize {
        CGSize(width: (fontSize * 0.4).rounded(), height: (fontSize * 0.15).rounded())
    }

    static func lines(_ text: String) -> [String] {
        let parts = text.components(separatedBy: "\n")
        return parts.isEmpty ? [""] : parts
    }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        let string = CFAttributedStringCreate(nil, text as CFString, attributes)
        return CTLineCreateWithAttributedString(string ?? CFAttributedStringCreate(nil, "" as CFString, nil))
    }

    static func lineHeight(_ font: CTFont) -> Double {
        (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
    }

    /// The text's own size without the pill.
    public static func textSize(_ text: String, fontSize: Double) -> CGSize {
        let font = font(size: fontSize)
        let lines = lines(text)
        let width = lines.map { CTLineGetTypographicBounds(line($0, font: font, color: CGColor(gray: 0, alpha: 1)), nil, nil, nil) }
            .max() ?? 0
        return CGSize(width: max(width.rounded(.up), fontSize * 0.3), height: lineHeight(font) * Double(lines.count))
    }

    /// The item's frame in image points: top-left at `start`, including the pill.
    public static func frame(for item: AnnotationItem) -> CGRect {
        let size = textSize(item.text, fontSize: item.fontSize)
        let pad = item.pill ? pillPadding(fontSize: item.fontSize) : .zero
        return CGRect(x: item.start.x, y: item.start.y, width: size.width + 2 * pad.width, height: size.height + 2 * pad.height)
    }
}

/// Draws annotations with Core Graphics. The context's coordinate space must be image points
/// with a top-left origin (y down). Pixelate items are not drawn here: they need the pixels
/// beneath them (see `Flattener.pixelated`).
public enum AnnotationPainter {
    public static func draw(_ item: AnnotationItem, in context: CGContext) {
        switch item.kind {
        case .rectangle: drawRectangle(item, in: context)
        case .arrow: drawArrow(item, in: context)
        case .text: drawText(item, in: context)
        case .pixelate: break
        }
    }

    static func drawRectangle(_ item: AnnotationItem, in context: CGContext) {
        let rect = item.box
        let radius = min(AnnotationItem.rectangleRadius, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        if item.filled {
            var fill = item.color
            fill.alpha *= AnnotationItem.fillOpacity
            context.setFillColor(fill.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.setStrokeColor(item.color.cgColor)
        context.setLineWidth(item.width)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Arrow geometry: the shaft end and the three head corners.
    public static func arrowHead(_ item: AnnotationItem) -> (shaftEnd: CGPoint, tip: CGPoint, left: CGPoint, right: CGPoint)? {
        let dx = item.end.x - item.start.x
        let dy = item.end.y - item.start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let unit = CGPoint(x: dx / length, y: dy / length)
        let headLength = min(item.width * AnnotationItem.arrowHeadFactor, length)
        let halfWidth = headLength * 0.5
        let base = CGPoint(x: item.end.x - unit.x * headLength, y: item.end.y - unit.y * headLength)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        // The shaft stops inside the head so its round cap never shows past the tip.
        let shaftEnd = CGPoint(x: item.end.x - unit.x * headLength * 0.6, y: item.end.y - unit.y * headLength * 0.6)
        return (
            shaftEnd, item.end,
            CGPoint(x: base.x + normal.x * halfWidth, y: base.y + normal.y * halfWidth),
            CGPoint(x: base.x - normal.x * halfWidth, y: base.y - normal.y * halfWidth)
        )
    }

    static func drawArrow(_ item: AnnotationItem, in context: CGContext) {
        guard let head = arrowHead(item) else { return }
        context.saveGState()
        context.setStrokeColor(item.color.cgColor)
        context.setFillColor(item.color.cgColor)
        context.setLineWidth(item.width)
        context.setLineCap(.round)
        context.move(to: item.start)
        context.addLine(to: head.shaftEnd)
        context.strokePath()
        context.setLineJoin(.round)
        context.move(to: head.tip)
        context.addLine(to: head.left)
        context.addLine(to: head.right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    static func drawText(_ item: AnnotationItem, in context: CGContext) {
        let font = TextLayout.font(size: item.fontSize)
        let frame = TextLayout.frame(for: item)
        let pad = item.pill ? TextLayout.pillPadding(fontSize: item.fontSize) : .zero
        context.saveGState()
        if item.pill {
            let radius = min(frame.height / 2, item.fontSize * 0.5)
            context.setFillColor(item.color.cgColor)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let textColor = item.pill ? CGColor(gray: 1, alpha: 1) : item.color.cgColor
        let lineHeight = TextLayout.lineHeight(font)
        let ascent = CTFontGetAscent(font)
        // CoreText draws y-up; flip the text matrix for the y-down context.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, text) in TextLayout.lines(item.text).enumerated() {
            let line = TextLayout.line(text, font: font, color: textColor)
            context.textPosition = CGPoint(
                x: frame.minX + pad.width, y: frame.minY + pad.height + Double(index) * lineHeight + ascent
            )
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

/// Export of an `AnnotationDocument`: the crop applied and every item burned in, in order.
/// Pixelate regions are replaced by a `CIPixellate` mosaic of what is under them, so the
/// original pixels there are not in the file (design section 11).
public enum Flattener {
    public enum FlattenError: Error, CustomStringConvertible {
        case contextFailed

        public var description: String { "cannot create a drawing context" }
    }

    /// Pixelate cell size in pixels: about a twelfth of the region's shorter side, at least 8.
    public static func cellSize(forPixelWidth width: Int, height: Int) -> Int {
        max(8, Int((Double(min(width, height)) / 12).rounded()))
    }

    public static func flatten(_ document: AnnotationDocument) throws -> CGImage {
        let size = document.outputPixelSize
        let space = outputColorSpace(for: document.image)
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FlattenError.contextFailed }
        let scale = document.scale
        let output = document.outputRect

        // The original, in device pixels (bottom-left origin), offset by the crop.
        context.interpolationQuality = .none
        let imageRect = CGRect(
            x: -output.minX * scale,
            y: Double(size.height) + output.minY * scale - Double(document.image.height),
            width: Double(document.image.width), height: Double(document.image.height)
        )
        context.draw(document.image, in: imageRect)

        // Image points, top-left origin.
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: Double(size.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -output.minX, y: -output.minY)

        for item in document.items {
            if item.kind == .pixelate {
                pixelateInPlace(item, context: context, document: document, size: size)
            } else {
                AnnotationPainter.draw(item, in: context)
            }
        }
        guard let image = context.makeImage() else { throw FlattenError.contextFailed }
        return image
    }

    /// The item's region in output pixels (top-left origin), clipped to the output.
    static func pixelRegion(_ item: AnnotationItem, document: AnnotationDocument, size: (width: Int, height: Int)) -> CGRect {
        let output = document.outputRect
        let box = item.box
        let rect = CGRect(
            x: (box.minX - output.minX) * document.scale, y: (box.minY - output.minY) * document.scale,
            width: box.width * document.scale, height: box.height * document.scale
        ).integral
        return rect.intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    private static func pixelateInPlace(
        _ item: AnnotationItem, context: CGContext, document: AnnotationDocument, size: (width: Int, height: Int)
    ) {
        let region = pixelRegion(item, document: document, size: size)
        guard !region.isNull, region.width >= 1, region.height >= 1,
              let current = context.makeImage(), let mosaic = pixelated(current, region: region) else { return }
        context.saveGState()
        // Back to device pixels with a bottom-left origin.
        context.concatenate(context.ctm.inverted())
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(mosaic, in: CGRect(
            x: region.minX, y: Double(size.height) - region.maxY, width: region.width, height: region.height
        ))
        context.restoreGState()
    }

    /// A mosaic of `region` (pixels, top-left origin) of `source`, the size of the region. Each
    /// cell is one flat colour from `CIPixellate`; cells start at the region's top-left corner.
    public static func pixelated(_ source: CGImage, region: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let clipped = region.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let cropped = source.cropping(to: clipped) else { return nil }
        let width = cropped.width
        let height = cropped.height
        let cell = cellSize(forPixelWidth: width, height: height)
        let input = CIImage(cgImage: cropped)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(Double(cell), forKey: kCIInputScaleKey)
        // The center is a cell corner. Core Image is y-up, so (0, height) is the region's top-left.
        filter.setValue(CIVector(x: 0, y: Double(height)), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        let space = cropped.colorSpace ?? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space)
    }

    /// The input's own RGB space keeps wide-gamut captures intact; anything else exports in sRGB.
    static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}
