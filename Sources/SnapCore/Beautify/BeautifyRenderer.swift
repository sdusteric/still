import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// What `BeautifyRenderer` decided for one render (design 10.2). Lengths named in points are in
/// the input's point space, rects and sizes named in pixels are in the output image.
public struct BeautifyGeometry: Codable, Sendable, Equatable {
    public struct PixelSize: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct PixelRect: Codable, Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct PointSize: Codable, Sendable, Equatable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// `u`: the preset scale for this image size.
    public var unit: Double
    /// Pixels per point of the input.
    public var scale: Double
    /// Pixels per point of the output.
    public var outputScale: Double
    /// Padding `P` in points.
    public var padding: Double
    /// Inset `I` in points; 0 when the border is not uniform.
    public var inset: Double
    /// Corner radius `R` in points.
    public var radius: Double
    public var uniformBorder: Bool
    /// The part of the input placed on the card, in input pixels from the top-left.
    public var contentRect: PixelRect
    /// Card size in points (content plus 2I).
    public var cardPoints: PointSize
    /// Canvas size in points, after growing to the ratio.
    public var canvasPoints: PointSize
    /// The card in output pixels from the top-left.
    public var cardRect: PixelRect
    /// The output image size in pixels: `round(points * outputScale)`.
    public var canvasSize: PixelSize
    /// The corner radius in output pixels.
    public var radiusPixels: Double
}

/// The Background beautifier (design section 10). Core Graphics only, so it runs headless.
public enum BeautifyRenderer {
    public struct Output: @unchecked Sendable {
        public var image: CGImage
        public var geometry: BeautifyGeometry
    }

    public enum RenderError: Error, CustomStringConvertible {
        case unreadableImage
        case canvasTooLarge(width: Int, height: Int)
        case contextFailed

        public var description: String {
            switch self {
            case .unreadableImage: "the image pixels cannot be read"
            case .canvasTooLarge(let width, let height): "the canvas would be \(width)x\(height) pixels"
            case .contextFailed: "cannot create a drawing context"
            }
        }
    }

    static let maxCanvasPixels = 32_768
    static let strokeOpacity = 0.08

    /// Renders `image` (captured at `scale` pixels per point) with `preset`. `outputScale` defaults to
    /// `scale`; a smaller value renders a preview whose layout matches the full render.
    public static func render(
        _ image: CGImage,
        scale: Double,
        preset: BackgroundPreset,
        outputScale: Double? = nil
    ) throws -> Output {
        guard let analysis = EdgeAnalysis.analyze(image) else { throw RenderError.unreadableImage }
        return try render(image, scale: scale, preset: preset, outputScale: outputScale, analysis: analysis)
    }

    /// As above, with an edge analysis computed earlier (a live preview analyzes once per capture).
    public static func render(
        _ image: CGImage,
        scale: Double,
        preset: BackgroundPreset,
        outputScale: Double? = nil,
        analysis: EdgeAnalysis
    ) throws -> Output {
        let preset = preset.clamped()
        let geometry = geometry(
            width: image.width, height: image.height, scale: scale, preset: preset, outputScale: outputScale,
            analysis: analysis
        )
        guard geometry.canvasSize.width <= maxCanvasPixels, geometry.canvasSize.height <= maxCanvasPixels else {
            throw RenderError.canvasTooLarge(width: geometry.canvasSize.width, height: geometry.canvasSize.height)
        }
        let space = outputColorSpace(for: image)
        guard let card = makeCard(image, geometry: geometry, analysis: analysis, space: space),
              let canvas = makeContext(width: geometry.canvasSize.width, height: geometry.canvasSize.height, space: space)
        else { throw RenderError.contextFailed }

        canvas.interpolationQuality = .high
        drawBackground(preset.background, in: canvas, geometry: geometry, space: space)
        drawCard(card, in: canvas, geometry: geometry, shadow: preset.shadow)
        guard let result = canvas.makeImage() else { throw RenderError.contextFailed }
        return Output(image: result, geometry: geometry)
    }

    /// The geometry for an image of the given pixel size (design 10.2 steps 1 to 8), without drawing.
    public static func geometry(
        width: Int,
        height: Int,
        scale: Double,
        preset: BackgroundPreset,
        outputScale: Double? = nil,
        analysis: EdgeAnalysis
    ) -> BeautifyGeometry {
        let preset = preset.clamped()
        let sourceScale = scale > 0 ? scale : 1
        let target = outputScale.flatMap { $0 > 0 ? $0 : nil } ?? sourceScale
        let widthPoints = Double(width) / sourceScale
        let heightPoints = Double(height) / sourceScale

        let unit = min(max(min(widthPoints, heightPoints) / 600, 0.5), 3.0)
        let padding = preset.padding * unit
        let uniform = analysis.isUniform
        let inset = uniform ? preset.inset * unit : 0

        let content = uniform && preset.autoBalance && analysis.hasContent
            ? analysis.contentBounds
            : CGRect(x: 0, y: 0, width: width, height: height)
        let cardWidth = Double(content.width) / sourceScale + 2 * inset
        let cardHeight = Double(content.height) / sourceScale + 2 * inset
        let radius = min(preset.cornerRadius * 100 * unit, min(cardWidth, cardHeight) / 2)

        let paddedWidth = cardWidth + 2 * padding
        let paddedHeight = cardHeight + 2 * padding
        var canvasWidth = paddedWidth
        var canvasHeight = paddedHeight
        if let ratio = preset.ratio {
            if paddedWidth / paddedHeight < ratio.value {
                canvasWidth = paddedHeight * ratio.value
            } else {
                canvasHeight = paddedWidth / ratio.value
            }
        }

        let canvasPixelsWide = max(Int((canvasWidth * target).rounded()), 1)
        let canvasPixelsHigh = max(Int((canvasHeight * target).rounded()), 1)
        let insetPixels = Int((inset * target).rounded())
        let contentWide = max(Int((Double(content.width) * target / sourceScale).rounded()), 1)
        let contentHigh = max(Int((Double(content.height) * target / sourceScale).rounded()), 1)
        let cardPixelsWide = contentWide + 2 * insetPixels
        let cardPixelsHigh = contentHigh + 2 * insetPixels

        // The padded card sits in the canvas; extra space from the ratio is split by the alignment.
        let paddingPixels = Int((padding * target).rounded())
        let extraWide = max(canvasPixelsWide - Int((paddedWidth * target).rounded()), 0)
        let extraHigh = max(canvasPixelsHigh - Int((paddedHeight * target).rounded()), 0)
        let column = Double(preset.alignment % 3) / 2
        let row = Double(preset.alignment / 3) / 2
        let cardX = min(paddingPixels + Int((Double(extraWide) * column).rounded()), max(canvasPixelsWide - cardPixelsWide, 0))
        let cardY = min(paddingPixels + Int((Double(extraHigh) * row).rounded()), max(canvasPixelsHigh - cardPixelsHigh, 0))

        return BeautifyGeometry(
            unit: unit,
            scale: sourceScale,
            outputScale: target,
            padding: padding,
            inset: inset,
            radius: radius,
            uniformBorder: uniform,
            contentRect: .init(
                x: Int(content.minX), y: Int(content.minY), width: Int(content.width), height: Int(content.height)
            ),
            cardPoints: .init(width: cardWidth, height: cardHeight),
            canvasPoints: .init(width: canvasWidth, height: canvasHeight),
            cardRect: .init(x: cardX, y: cardY, width: cardPixelsWide, height: cardPixelsHigh),
            canvasSize: .init(width: canvasPixelsWide, height: canvasPixelsHigh),
            radiusPixels: min(radius * target, Double(min(cardPixelsWide, cardPixelsHigh)) / 2)
        )
    }

    // MARK: Drawing

    /// The input's own RGB space keeps wide-gamut captures intact; anything else renders in sRGB.
    private static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput,
           makeContext(width: 1, height: 1, space: space) != nil {
            return space
        }
        return SyntheticImages.colorSpace
    }

    private static func makeContext(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// The card as its own transparent bitmap: border colour fill, the content, a 1 px edge stroke,
    /// all clipped to the rounded rectangle. Alpha of the content survives, so window corners stay clear.
    private static func makeCard(
        _ image: CGImage, geometry: BeautifyGeometry, analysis: EdgeAnalysis, space: CGColorSpace
    ) -> CGImage? {
        let width = geometry.cardRect.width
        let height = geometry.cardRect.height
        guard let context = makeContext(width: width, height: height, space: space) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = geometry.radiusPixels
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()

        if geometry.uniformBorder {
            context.setFillColor(analysis.borderColor.cgColor)
            context.fill(bounds)
        }
        let insetPixels = Double(Int((geometry.inset * geometry.outputScale).rounded()))
        let destination = bounds.insetBy(dx: insetPixels, dy: insetPixels)
        let rect = geometry.contentRect
        let source = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if let cropped = source.size == CGSize(width: image.width, height: image.height) ? image : image.cropping(to: source) {
            context.draw(cropped, in: destination)
        }
        context.resetClip()

        // Edge stroke on top of existing card pixels only, so transparent corners stay transparent.
        context.setBlendMode(.sourceAtop)
        context.setStrokeColor(CGColor(gray: 0, alpha: strokeOpacity))
        context.setLineWidth(1)
        let strokeRadius = max(radius - 0.5, 0)
        context.addPath(CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: strokeRadius, cornerHeight: strokeRadius,
            transform: nil
        ))
        context.strokePath()
        return context.makeImage()
    }

    private static func drawBackground(
        _ fill: BackgroundFill, in context: CGContext, geometry: BeautifyGeometry, space: CGColorSpace
    ) {
        let bounds = CGRect(x: 0, y: 0, width: geometry.canvasSize.width, height: geometry.canvasSize.height)
        switch fill {
        case .none:
            break
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(bounds)
        case .gradient(let id):
            GradientPainter.draw(id, in: context, rect: bounds)
        case .image(let path, let blur):
            if let image = loadImage(path) {
                drawAspectFill(image, blur: blur * geometry.outputScale, in: context, bounds: bounds, space: space)
            } else {
                GradientPainter.draw(BackgroundFill.defaultGradient, in: context, rect: bounds)
            }
        }
    }

    private static func loadImage(_ path: String) -> CGImage? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let source = CGImageSourceCreateWithURL(URL(filePath: expanded) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func drawAspectFill(
        _ image: CGImage, blur: Double, in context: CGContext, bounds: CGRect, space: CGColorSpace
    ) {
        let factor = max(bounds.width / Double(image.width), bounds.height / Double(image.height))
        let size = CGSize(width: Double(image.width) * factor, height: Double(image.height) * factor)
        let rect = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
        guard blur > 0.5 else {
            context.draw(image, in: rect)
            return
        }
        // Blur the filled layer, then draw it; blurring the fitted size keeps the cost bounded.
        guard let layerContext = makeContext(width: Int(bounds.width), height: Int(bounds.height), space: space) else {
            context.draw(image, in: rect)
            return
        }
        layerContext.interpolationQuality = .high
        layerContext.draw(image, in: rect)
        if let layer = layerContext.makeImage() {
            context.draw(blurred(layer, sigma: blur / 2) ?? layer, in: bounds)
        }
    }

    private static func blurred(_ image: CGImage, sigma: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: image.colorSpace)
    }

    /// Shadow first, then the card (design 10.2 step 9). A contact shadow sits under the soft one.
    /// Shadow 0 draws none. Both shadows are cast by the card's alpha but drawn without the card,
    /// so the card is composited once and translucent pixels (a window's own shadow, antialiased
    /// corners) keep their alpha (step 6).
    private static func drawCard(_ card: CGImage, in context: CGContext, geometry: BeautifyGeometry, shadow: Double) {
        let destination = CGRect(
            x: Double(geometry.cardRect.x),
            y: Double(geometry.canvasSize.height - geometry.cardRect.y - geometry.cardRect.height),
            width: Double(geometry.cardRect.width), height: Double(geometry.cardRect.height)
        )
        let amount = shadow / 100
        let unit = geometry.unit * geometry.outputScale
        if amount > 0 {
            let shadows: [(offset: Double, blur: Double, alpha: Double)] = [
                (1 * unit, 3 * unit, 0.12),
                ((6 + 18 * amount) * unit, (12 + 36 * amount) * unit, 0.10 + 0.40 * amount),
            ]
            // The caster is drawn this far to the right, off the canvas; the shadow offset brings
            // only the shadow back under the card.
            let away = Double(geometry.canvasSize.width) + destination.width + 4 * (shadows.map(\.blur).max() ?? 0)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for shadow in shadows {
                context.saveGState()
                // Shadow offsets are in the unflipped base space, where down is negative.
                context.setShadow(
                    offset: CGSize(width: -away, height: -shadow.offset), blur: shadow.blur,
                    color: CGColor(gray: 0, alpha: shadow.alpha)
                )
                context.draw(card, in: destination.offsetBy(dx: away, dy: 0))
                context.restoreGState()
            }
            context.endTransparencyLayer()
        }
        context.draw(card, in: destination)
    }
}
