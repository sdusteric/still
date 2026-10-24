import AppKit
import SnapCore

/// The loupe of the area overlay (design 7, 17.4, 17.6): a 120 pt circle showing 15 x 15 physical
/// pixels of the frozen image at 8 pt each, nearest neighbour, with an accent square on the centre
/// pixel and a caption chip under it. It is a drawing layer of `SelectionOverlayView`, drawn in
/// `draw(_:)` so `cacheDisplay` captures it. Coordinates are the overlay view's: display-local
/// points with a top-left origin.
public enum MagnifierLayer {
    public static var diameter: Double { Theme.Overlay.magnifierDiameter }
    public static var pixelsAcross: Int { Theme.Overlay.magnifierPixels }
    public static var pixelSize: Double { Theme.Overlay.magnifierPixelSize }
    /// Glass plus the gap plus the caption chip.
    public static var unitHeight: Double {
        diameter + Theme.Overlay.magnifierCaptionGap + Theme.Overlay.chipHeight
    }

    /// The glass circle's frame. Before the drag (`selection == nil`) it sits 24 pt down and right of
    /// the pointer. During the drag it sits on the side of the pointer away from the selection's
    /// centre. Either way it flips 8 pt before the screen edges so the whole unit stays on screen.
    public static func glassFrame(pointer: CGPoint, selection: CGRect?, bounds: CGRect) -> CGRect {
        let offset = Theme.Overlay.magnifierOffset
        var right = true
        var below = true
        if let selection {
            right = pointer.x >= selection.midX
            below = pointer.y >= selection.midY
        }
        func x(_ right: Bool) -> Double { right ? pointer.x + offset : pointer.x - offset - diameter }
        func y(_ below: Bool) -> Double { below ? pointer.y + offset : pointer.y - offset - unitHeight }
        // The unit keeps a margin from the screen edges, so the caption never touches them.
        let room = bounds.insetBy(dx: Theme.Overlay.magnifierEdgeMargin, dy: Theme.Overlay.magnifierEdgeMargin)
        var originX = x(right)
        if originX + diameter > room.maxX || originX < room.minX { originX = x(!right) }
        var originY = y(below)
        if originY + unitHeight > room.maxY || originY < room.minY { originY = y(!below) }
        originX = min(max(originX, room.minX), max(room.maxX - diameter, room.minX))
        originY = min(max(originY, room.minY), max(room.maxY - unitHeight, room.minY))
        return CGRect(x: originX, y: originY, width: diameter, height: diameter)
    }

    /// The caption chip's frame for a glass frame and caption width.
    public static func captionFrame(glass: CGRect, captionWidth: Double) -> CGRect {
        CGRect(
            x: glass.midX - captionWidth / 2,
            y: glass.maxY + Theme.Overlay.magnifierCaptionGap,
            width: captionWidth,
            height: Theme.Overlay.chipHeight
        )
    }

    /// The pixel of `image` under a display-local point, for an image covering `bounds`.
    public static func sourcePixel(for point: CGPoint, imageSize: CGSize, bounds: CGRect) -> (x: Int, y: Int) {
        let ratioX = bounds.width > 0 ? imageSize.width / bounds.width : 1
        let ratioY = bounds.height > 0 ? imageSize.height / bounds.height : 1
        return (Int(((point.x - bounds.minX) * ratioX).rounded(.down)), Int(((point.y - bounds.minY) * ratioY).rounded(.down)))
    }

    /// The 15 x 15 pixel window of the image around `pixel`, before clamping to the image.
    public static func sourceRect(around pixel: (x: Int, y: Int)) -> CGRect {
        let half = pixelsAcross / 2
        return CGRect(x: pixel.x - half, y: pixel.y - half, width: pixelsAcross, height: pixelsAcross)
    }

    /// Where a display-local point lands inside the glass for the pixel window `wanted`.
    static func glassPoint(
        for point: CGPoint, wanted: CGRect, imageSize: CGSize, bounds: CGRect, glass: CGRect
    ) -> CGPoint {
        let ratioX = bounds.width > 0 ? imageSize.width / bounds.width : 1
        let ratioY = bounds.height > 0 ? imageSize.height / bounds.height : 1
        return CGPoint(
            x: glass.minX + ((point.x - bounds.minX) * ratioX - wanted.minX) * pixelSize,
            y: glass.minY + ((point.y - bounds.minY) * ratioY - wanted.minY) * pixelSize
        )
    }

    /// Draws the glass (rings, pixels, pixel grid, centre square) into the current flipped
    /// context. During a drag, `selection` (display-local points) is drawn as the overlay shows
    /// it, dim outside and a white edge, so the edge pixel can be placed exactly (mockup 1b).
    /// Without a frozen image there is nothing to magnify, so only the caption is drawn (design 7).
    static func draw(
        in context: CGContext,
        image: CGImage?,
        pointer: CGPoint,
        selection: CGRect? = nil,
        glass: CGRect,
        bounds: CGRect,
        accent: CGColor
    ) {
        guard let image else { return }
        let ring = Theme.Overlay.magnifierRingWidth
        let hairline = Theme.Overlay.magnifierHairlineWidth
        context.saveGState()
        context.setFillColor(Theme.Colors.crosshairHairline.cgColor(dark: false))
        context.fillEllipse(in: glass.insetBy(dx: -(ring + hairline), dy: -(ring + hairline)))
        context.setFillColor(Theme.Colors.selectionBorder.cgColor(dark: false))
        context.fillEllipse(in: glass.insetBy(dx: -ring, dy: -ring))
        context.addEllipse(in: glass)
        context.clip()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(glass)

        let pixel = sourcePixel(for: pointer, imageSize: CGSize(width: image.width, height: image.height), bounds: bounds)
        let wanted = sourceRect(around: pixel)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !available.isNull, !available.isEmpty, let crop = image.cropping(to: available) {
            let destination = CGRect(
                x: glass.minX + (available.minX - wanted.minX) * pixelSize,
                y: glass.minY + (available.minY - wanted.minY) * pixelSize,
                width: available.width * pixelSize,
                height: available.height * pixelSize
            )
            context.interpolationQuality = .none
            OverlayDrawing.drawImage(crop, in: destination, context: context)
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        if let selection {
            let topLeft = glassPoint(
                for: CGPoint(x: selection.minX, y: selection.minY), wanted: wanted, imageSize: imageSize, bounds: bounds,
                glass: glass
            )
            let bottomRight = glassPoint(
                for: CGPoint(x: selection.maxX, y: selection.maxY), wanted: wanted, imageSize: imageSize, bounds: bounds,
                glass: glass
            )
            let cut = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            context.setFillColor(Theme.Colors.dim.cgColor(dark: false))
            context.addRect(glass)
            context.addRect(cut)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(Theme.Colors.selectionBorder.cgColor(dark: false))
            context.setLineWidth(Theme.Overlay.selectionBorderWidth)
            context.stroke(cut.insetBy(dx: -0.5, dy: -0.5))
        }

        // The pixel grid, so single pixels read as cells (mockup 1a).
        context.setStrokeColor(Theme.Colors.magnifierGrid.cgColor(dark: false))
        context.setLineWidth(Theme.Overlay.magnifierGridWidth)
        for step in 1..<pixelsAcross {
            let offset = Double(step) * pixelSize
            context.move(to: CGPoint(x: glass.minX + offset, y: glass.minY))
            context.addLine(to: CGPoint(x: glass.minX + offset, y: glass.maxY))
            context.move(to: CGPoint(x: glass.minX, y: glass.minY + offset))
            context.addLine(to: CGPoint(x: glass.maxX, y: glass.minY + offset))
        }
        context.strokePath()

        let half = Double(pixelsAcross / 2)
        let center = CGRect(
            x: glass.minX + half * pixelSize, y: glass.minY + half * pixelSize, width: pixelSize, height: pixelSize
        )
        let stroke = Theme.Overlay.magnifierCenterStroke
        // A white inner line keeps the accent square visible on blue content.
        context.setStrokeColor(Theme.Colors.selectionBorder.cgColor(dark: false))
        context.setLineWidth(1)
        context.stroke(center.insetBy(dx: stroke + 0.5, dy: stroke + 0.5))
        context.setStrokeColor(accent)
        context.setLineWidth(stroke)
        context.stroke(center.insetBy(dx: stroke / 2, dy: stroke / 2))
        context.restoreGState()
    }
}
