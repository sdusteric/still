import CoreGraphics
import Foundation
import SnapCore
import Testing

/// 400 x 300 points of noise at 2x (800 x 600 px).
private func noiseDocument() throws -> AnnotationDocument {
    let image = try #require(SyntheticImages.noise(width: 800, height: 600, seed: 11))
    return AnnotationDocument(image: image, scale: 2)
}

/// A white 2x capture of 400 x 300 points with a red block, like the `block-2x` fixture.
private func blockDocument() throws -> AnnotationDocument {
    let image = try #require(SyntheticImages.block(
        width: 800, height: 600, block: CGRect(x: 100, y: 100, width: 400, height: 300)
    ))
    return AnnotationDocument(image: image, scale: 2)
}

private func lumaStats(_ image: CGImage, region: CGRect) throws -> (mean: Double, deviation: Double) {
    let bytes = try #require(SyntheticImages.rgbaBytes(of: image))
    var values: [Double] = []
    for y in Int(region.minY)..<Int(region.maxY) {
        for x in Int(region.minX)..<Int(region.maxX) {
            let base = (y * image.width + x) * 4
            values.append(SyntheticImages.Pixel(red: bytes[base], green: bytes[base + 1], blue: bytes[base + 2]).luminance)
        }
    }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return (mean, variance.squareRoot())
}

private func color(_ hex: String) throws -> RGBAColor {
    try #require(RGBAColor(hex: hex))
}

@Suite struct AnnotationM2Tests {
    // MARK: Highlight

    @Test func highlightIsDrawnAtThirtyEightPercentOverTheImage() throws {
        var document = try blockDocument()
        document.add(.highlight(CGRect(x: 20, y: 20, width: 100, height: 40)))
        document.add(.highlight(CGRect(x: 120, y: 120, width: 100, height: 40)))
        let flat = try Flattener.flatten(document)
        // #FFD60A at 38% over white: 255, 255 - 0.38 * 41, 255 - 0.38 * 245.
        let overWhite = try #require(SyntheticImages.pixel(of: flat, x: 80, y: 80))
        #expect(overWhite.red == 255)
        #expect(abs(Int(overWhite.green) - 239) <= 2, "green \(overWhite.green)")
        #expect(abs(Int(overWhite.blue) - 162) <= 2, "blue \(overWhite.blue)")
        // Over the red block the green and blue channels stay low: the image shows through.
        let overRed = try #require(SyntheticImages.pixel(of: flat, x: 300, y: 300))
        #expect(overRed.red == 255)
        #expect(abs(Int(overRed.green) - 81) <= 3, "green \(overRed.green)")
        #expect(overRed.blue < 10)
    }

    @Test func highlightHasItsOwnDefaultColorAndRoundedCorners() throws {
        #expect(AnnotationItem.highlight(CGRect(x: 0, y: 0, width: 10, height: 10)).color.hex == "#FFD60A")
        #expect(AnnotationItem.highlightOpacity == 0.38)
        var document = try blockDocument()
        document.add(.highlight(CGRect(x: 40, y: 40, width: 100, height: 60), color: try color("#000000")))
        let flat = try Flattener.flatten(document)
        // The corner pixel of a radius 2 pt (4 px) rounded rectangle is not covered.
        let corner = try #require(SyntheticImages.pixel(of: flat, x: 80, y: 80))
        let inside = try #require(SyntheticImages.pixel(of: flat, x: 120, y: 120))
        #expect(corner.red == 255)
        #expect(inside.red < 200)
    }

    @Test func shiftMakesAWideHighlightDragAOneLineBand() {
        let press = CGPoint(x: 100, y: 100)
        let band = AnnotationItem.highlightCorners(press: press, to: CGPoint(x: 400, y: 104), constrain: true)
        #expect(band.0 == CGPoint(x: 100, y: 89) && band.1 == CGPoint(x: 400, y: 111))
        let tall = AnnotationItem.highlightCorners(press: press, to: CGPoint(x: 150, y: 140), constrain: true)
        #expect(tall.0 == press && tall.1 == CGPoint(x: 150, y: 140), "not wider than 3 times its height")
        let free = AnnotationItem.highlightCorners(press: press, to: CGPoint(x: 400, y: 104), constrain: false)
        #expect(free.1 == CGPoint(x: 400, y: 104))
    }

    // MARK: Redact styles

    @Test func blackoutIsExactlyBlackOverTheWholeRegion() throws {
        var document = try blockDocument()
        // Points 120...220 by 120...200, inside the block at points 50...250 by 50...200.
        document.add(.redact(CGRect(x: 120, y: 120, width: 100, height: 60), style: .blackout))
        let flat = try Flattener.flatten(document)
        let bytes = try #require(SyntheticImages.rgbaBytes(of: flat))
        for y in 240..<360 {
            for x in 240..<440 {
                let base = (y * 800 + x) * 4
                #expect(bytes[base] == 0 && bytes[base + 1] == 0 && bytes[base + 2] == 0 && bytes[base + 3] == 255)
            }
        }
        let outside = try #require(SyntheticImages.pixel(of: flat, x: 239, y: 300))
        #expect(outside.red == 255 && outside.green == 0)
    }

    @Test func blurRemovesTheOriginalPixelsAndTheDetail() throws {
        var document = try noiseDocument()
        // 100 x 100 points is 200 x 200 px.
        document.add(.redact(CGRect(x: 100, y: 100, width: 100, height: 100), style: .blur))
        let flat = try Flattener.flatten(document)
        let region = CGRect(x: 200, y: 200, width: 200, height: 200)
        let before = try lumaStats(document.image, region: region)
        let after = try lumaStats(flat, region: region)
        #expect(after.deviation <= before.deviation * 0.25, "stddev \(before.deviation) to \(after.deviation)")

        let source = try #require(SyntheticImages.rgbaBytes(of: document.image))
        let output = try #require(SyntheticImages.rgbaBytes(of: flat))
        var same = 0
        for y in 200..<400 {
            for x in 200..<400 where (0..<4).allSatisfy({ source[(y * 800 + x) * 4 + $0] == output[(y * 800 + x) * 4 + $0] }) {
                same += 1
            }
        }
        #expect(Double(same) / 40000 < 0.02, "\(same) pixels kept their value")
        // Outside the region nothing changed, and the blur does not bleed over its edge.
        for (x, y) in [(199, 300), (400, 300), (300, 199), (300, 400), (10, 10)] {
            let a = try #require(SyntheticImages.pixel(of: document.image, x: x, y: y))
            let b = try #require(SyntheticImages.pixel(of: flat, x: x, y: y))
            #expect(a == b, "pixel \(x), \(y)")
        }
    }

    @Test func blurRadiusIsAnEighthOfTheShorterSideWithAFloorOfEightPixels() {
        #expect(Flattener.blurRadius(forPixelWidth: 200, height: 200) == 25)
        #expect(Flattener.blurRadius(forPixelWidth: 800, height: 400) == 50)
        #expect(Flattener.blurRadius(forPixelWidth: 40, height: 30) == 8)
    }

    @Test func blurKeepsItsEdgesInsteadOfFadingToTransparent() throws {
        var document = try blockDocument()
        document.add(.redact(CGRect(x: 120, y: 120, width: 100, height: 60), style: .blur))
        let flat = try Flattener.flatten(document)
        // Entirely inside the red block: a blur of a flat color stays that color, opaque, to the edge.
        for (x, y) in [(240, 240), (439, 239), (240, 359), (439, 359), (340, 300)] {
            let pixel = try #require(SyntheticImages.pixel(of: flat, x: x, y: y))
            #expect(pixel.alpha == 255 && pixel.red >= 250 && pixel.green <= 6, "pixel \(x), \(y): \(pixel)")
        }
    }

    @Test func redactionsAreAppliedBeforeAnnotationsAreDrawnAbove() throws {
        var document = try noiseDocument()
        document.add(.rectangle(CGRect(x: 100, y: 100, width: 100, height: 100), color: try color("#00FF00"), width: 7))
        document.add(.redact(CGRect(x: 60, y: 60, width: 200, height: 200), style: .blackout))
        let flat = try Flattener.flatten(document)
        // The rectangle was added first but it is drawn over the black-out, crisp and green.
        let stroke = try #require(SyntheticImages.pixel(of: flat, x: 200, y: 300))
        #expect(stroke.green == 255 && stroke.red == 0)
        let fill = try #require(SyntheticImages.pixel(of: flat, x: 300, y: 300))
        #expect(fill.red == 0 && fill.green == 0 && fill.blue == 0)
    }

    @Test func everyRedactStyleLeavesNoOriginalPixelsAndM1PixelateStillWorks() throws {
        for style in RedactStyle.allCases {
            var document = try noiseDocument()
            document.add(.redact(CGRect(x: 40, y: 60, width: 192, height: 96), style: style))
            #expect(document.items[0].kind == style.kind)
            let flat = try Flattener.flatten(document)
            let source = try #require(SyntheticImages.rgbaBytes(of: document.image))
            let output = try #require(SyntheticImages.rgbaBytes(of: flat))
            var same = 0
            for y in 120..<312 {
                for x in 80..<464 where (0..<4).allSatisfy({ source[(y * 800 + x) * 4 + $0] == output[(y * 800 + x) * 4 + $0] }) {
                    same += 1
                }
            }
            #expect(Double(same) / Double(192 * 384) < 0.02, "\(style): \(same) pixels kept their value")
        }
        #expect(AnnotationItem.pixelate(.zero).kind == RedactStyle.pixelate.kind)
        #expect(RedactStyle.allCases.map(\.title) == ["Pixelate", "Blur", "Black-out"])
    }

    // MARK: Steps

    @Test func stepNumbersAreTheirOrderAndRenumberOnDelete() throws {
        var document = try noiseDocument()
        let first = document.add(.step(at: CGPoint(x: 50, y: 50)))
        document.add(.rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let second = document.add(.step(at: CGPoint(x: 100, y: 50)))
        let third = document.add(.step(at: CGPoint(x: 150, y: 50)))
        #expect(document.stepNumber(of: first) == 1)
        #expect(document.stepNumber(of: second) == 2)
        #expect(document.stepNumber(of: third) == 3)
        #expect(document.stepNumber(of: document.items[1].id) == nil)
        document.delete(second)
        #expect(document.stepNumber(of: first) == 1)
        #expect(document.stepNumber(of: third) == 2, "deleting step 2 renumbers 3 to 2")
        #expect(document.stepNumbers.count == 2)
    }

    @Test func stepDiameterFollowsTheStrokeWidth() {
        #expect([2.0, 4.0, 7.0].map { AnnotationItem.stepDiameter(forWidth: $0) } == [24, 28, 36])
        #expect(AnnotationItem.stepNumberFontSize(forDiameter: 28) == 15)
        #expect(AnnotationItem.step(at: .zero, width: 7).box == CGRect(x: -18, y: -18, width: 36, height: 36))
    }

    @Test func aStepIsAFilledCircleWithAWhiteNumber() throws {
        var document = try noiseDocument()
        let red = try color("#FF3B30")
        document.add(.step(at: CGPoint(x: 100, y: 100), color: red, width: 4))
        document.add(.step(at: CGPoint(x: 200, y: 100), color: red, width: 4))
        let flat = try Flattener.flatten(document)
        for centerX in [200, 400] {
            // A pixel inside the circle clear of the digit, one outside it, and the digit's white.
            let fill = try #require(SyntheticImages.pixel(of: flat, x: centerX + 20, y: 200))
            #expect(fill.red == 255 && fill.green == 59 && fill.blue == 48, "circle fill \(fill)")
            let outside = try #require(SyntheticImages.pixel(of: flat, x: centerX + 40, y: 200))
            #expect(outside != fill)
            var whites = 0
            for y in 188..<213 {
                for x in (centerX - 10)..<(centerX + 10) {
                    let pixel = try #require(SyntheticImages.pixel(of: flat, x: x, y: y))
                    if pixel.red > 240 && pixel.green > 240 && pixel.blue > 240 { whites += 1 }
                }
            }
            #expect(whites > 15, "the number is drawn in white: \(whites) pixels")
        }
    }

    @Test func stepsHitTestInsideTheirCircleAndOnlyMove() throws {
        var document = try noiseDocument()
        let id = document.add(.step(at: CGPoint(x: 100, y: 100)))
        #expect(document.hitTest(CGPoint(x: 108, y: 100)) == id)
        #expect(document.hitTest(CGPoint(x: 130, y: 100)) == nil)
        #expect(document.item(id)?.handles.isEmpty == true)
        document.move(id, by: 10, 20)
        #expect(document.item(id)?.start == CGPoint(x: 110, y: 120))
        document.resize(id, handle: .bottomRight, to: CGPoint(x: 300, y: 300))
        #expect(document.item(id)?.start == CGPoint(x: 110, y: 120))
    }

    // MARK: Freehand

    @Test func freehandDropsPointsCloserThanOneAndAHalfPoints() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1.4, y: 0.5), CGPoint(x: 1.6, y: 0),
            CGPoint(x: 3, y: 0), CGPoint(x: 3.5, y: 0.2), CGPoint(x: 6, y: 0),
        ]
        let kept = FreehandPath.decimated(points)
        #expect(kept == [CGPoint(x: 0, y: 0), CGPoint(x: 1.6, y: 0), CGPoint(x: 3.5, y: 0.2), CGPoint(x: 6, y: 0)])
        for (a, b) in zip(kept, kept.dropFirst()) {
            #expect(hypot(b.x - a.x, b.y - a.y) >= 1.5)
        }
        #expect(FreehandPath.appending(CGPoint(x: 0.5, y: 0), to: [.zero]) == [.zero])
        #expect(FreehandPath.appending(CGPoint(x: 2, y: 0), to: [.zero]).count == 2)
    }

    @Test func freehandSplineIsCubicBeziersThroughEveryPoint() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 10)]
        let segments = FreehandPath.segments(for: points)
        #expect(segments.count == 3)
        for (index, segment) in segments.enumerated() {
            #expect(segment.start == points[index] && segment.end == points[index + 1])
            #expect(segment.point(at: 0) == points[index])
            #expect(segment.point(at: 1) == points[index + 1])
        }
        // Catmull-Rom: the first control point is the point plus a sixth of the neighbors' chord.
        #expect(segments[1].control1 == CGPoint(x: 10 + 20.0 / 6, y: 10 + (0 - 0) / 6.0))
        #expect(FreehandPath.segments(for: [CGPoint.zero]).isEmpty)
    }

    @Test func freehandHitTestIsWithinHalfTheWidthPlusFourPoints() throws {
        var document = try noiseDocument()
        let id = document.add(.freehand(
            [CGPoint(x: 20, y: 100), CGPoint(x: 80, y: 100), CGPoint(x: 140, y: 100)], width: 4
        ))
        #expect(document.hitTest(CGPoint(x: 80, y: 105)) == id)
        #expect(document.hitTest(CGPoint(x: 80, y: 106)) == id, "2 + 4 points away")
        #expect(document.hitTest(CGPoint(x: 80, y: 108)) == nil)
        #expect(document.hitTest(CGPoint(x: 200, y: 100)) == nil)
        document.move(id, by: 5, -10)
        #expect(document.item(id)?.points.first == CGPoint(x: 25, y: 90))
        #expect(document.item(id)?.handles.isEmpty == true)
    }

    @Test func freehandIsDrawnInTheStrokeColorThroughItsMidpoint() throws {
        var document = try blockDocument()
        let stroke = try color("#0000FF")
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 40), CGPoint(x: 100, y: 30), CGPoint(x: 140, y: 60)]
        let id = document.add(.freehand(points, color: stroke, width: 4))
        let flat = try Flattener.flatten(document)
        let stored = try #require(document.item(id)?.points)
        let midpoint = try #require(FreehandPath.midpoint(of: stored))
        let pixel = try #require(SyntheticImages.pixel(of: flat, x: Int(midpoint.x * 2), y: Int(midpoint.y * 2)))
        #expect(pixel.red == 0 && pixel.green == 0 && pixel.blue == 255, "midpoint pixel \(pixel)")
        for point in points {
            let at = try #require(SyntheticImages.pixel(of: flat, x: Int(point.x * 2), y: Int(point.y * 2)))
            #expect(at.blue == 255 && at.red < 10, "the curve passes through \(point)")
        }
    }

    // MARK: Documents

    @Test func m1ItemsWithoutPointsDecodeAndRender() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"pixelate","start":[10,20],"end":[110,80],
         "color":"#FF3B30","width":4,"filled":false,"text":"","fontSize":30,"pill":false}
        """
        let item = try JSONDecoder().decode(AnnotationItem.self, from: Data(json.utf8))
        #expect(item.kind == .pixelate && item.points.isEmpty)
        #expect(item.box == CGRect(x: 10, y: 20, width: 100, height: 60))
        var document = try noiseDocument()
        document.add(item)
        let flat = try Flattener.flatten(document)
        #expect(flat.width == 800 && flat.height == 600)
        let before = try lumaStats(document.image, region: CGRect(x: 20, y: 40, width: 200, height: 120))
        let after = try lumaStats(flat, region: CGRect(x: 20, y: 40, width: 200, height: 120))
        #expect(after.deviation < before.deviation)
    }

    @Test func newKindsRoundTripThroughJSON() throws {
        let items: [AnnotationItem] = [
            .highlight(CGRect(x: 1, y: 2, width: 30, height: 10)),
            .redact(CGRect(x: 5, y: 5, width: 20, height: 20), style: .blur),
            .step(at: CGPoint(x: 40, y: 50), width: 7),
            .freehand([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0)]),
        ]
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([AnnotationItem].self, from: data)
        #expect(decoded == items)
        #expect(AnnotationKind.allCases.count == 9)
        #expect(AnnotationKind.allCases.filter(\.isRedact) == [.pixelate, .blur, .blackout])
    }

    @Test func croppedExportKeepsStepNumbersAndRegionsInOutputPixels() throws {
        var document = try noiseDocument()
        let region = AnnotationItem.redact(CGRect(x: 120, y: 120, width: 60, height: 40), style: .blackout)
        document.add(region)
        document.crop(to: CGRect(x: 100, y: 100, width: 200, height: 150))
        let size = document.outputPixelSize
        let pixels = Flattener.pixelRegion(region, document: document, size: size)
        #expect(pixels == CGRect(x: 40, y: 40, width: 120, height: 80))
        let flat = try Flattener.flatten(document)
        let black = try #require(SyntheticImages.pixel(of: flat, x: 100, y: 80))
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
    }
}
