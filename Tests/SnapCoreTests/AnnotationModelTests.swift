import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A 2x capture of 400 x 300 points (800 x 600 px) of noise, so any original pixel is easy to spot.
private func noiseDocument(scale: Double = 2) throws -> AnnotationDocument {
    let image = try #require(SyntheticImages.noise(width: Int(400 * scale), height: Int(300 * scale), seed: 11))
    return AnnotationDocument(image: image, scale: scale)
}

private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
    let base = (y * width + x) * 4
    return Array(bytes[base..<(base + 4)])
}

@Suite struct AnnotationModelTests {
    // MARK: Add, hit-test, move, resize, delete, duplicate

    @Test func addPutsItemsOnTopAndHitTestFindsTheTopmost() throws {
        var document = try noiseDocument()
        let below = document.add(.rectangle(CGRect(x: 20, y: 20, width: 200, height: 100), filled: true))
        let above = document.add(.pixelate(CGRect(x: 100, y: 50, width: 60, height: 40)))
        #expect(document.items.map(\.id) == [below, above])
        #expect(document.hitTest(CGPoint(x: 120, y: 60)) == above)
        #expect(document.hitTest(CGPoint(x: 40, y: 100)) == below)
        #expect(document.hitTest(CGPoint(x: 380, y: 280)) == nil)
    }

    @Test func outlinedRectangleIsHitOnItsStrokeOnly() throws {
        var document = try noiseDocument()
        let id = document.add(.rectangle(CGRect(x: 50, y: 50, width: 200, height: 100)))
        #expect(document.hitTest(CGPoint(x: 50, y: 100)) == id, "on the left edge")
        #expect(document.hitTest(CGPoint(x: 52, y: 100), tolerance: 4) == id, "near the edge")
        #expect(document.hitTest(CGPoint(x: 150, y: 100)) == nil, "the inside of an outline is not the item")
    }

    @Test func arrowIsHitAlongItsShaft() throws {
        var document = try noiseDocument()
        let id = document.add(.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 110)))
        #expect(document.hitTest(CGPoint(x: 60, y: 61)) == id)
        #expect(document.hitTest(CGPoint(x: 60, y: 90)) == nil)
    }

    @Test func moveAndNudgeShiftTheGeometry() throws {
        var document = try noiseDocument()
        let id = document.add(.rectangle(CGRect(x: 10, y: 20, width: 30, height: 40)))
        let moved = document.move(id, by: 5, -3)
        #expect(moved)
        #expect(document.item(id)?.box == CGRect(x: 15, y: 17, width: 30, height: 40))
        let nudgedRight = document.nudge(id, dx: 1, dy: 0)
        let nudgedDown = document.nudge(id, dx: 0, dy: 1, large: true)
        #expect(nudgedRight && nudgedDown)
        #expect(document.item(id)?.box == CGRect(x: 16, y: 27, width: 30, height: 40))
        let movedUnknown = document.move(UUID(), by: 1, 1)
        #expect(!movedUnknown, "an unknown id changes nothing")
    }

    @Test func resizeByHandleKeepsTheOppositeCorner() throws {
        var document = try noiseDocument()
        let id = document.add(.rectangle(CGRect(x: 100, y: 100, width: 50, height: 40)))
        document.resize(id, handle: .bottomRight, to: CGPoint(x: 200, y: 180))
        #expect(document.item(id)?.box == CGRect(x: 100, y: 100, width: 100, height: 80))
        document.resize(id, handle: .left, to: CGPoint(x: 80, y: 0))
        #expect(document.item(id)?.box == CGRect(x: 80, y: 100, width: 120, height: 80))
        // Dragging a corner past the opposite one flips the box instead of making it negative.
        document.resize(id, handle: .topLeft, to: CGPoint(x: 250, y: 200))
        #expect(document.item(id)?.box == CGRect(x: 200, y: 180, width: 50, height: 20))
        // Shift makes a square of the larger side.
        document.resize(id, handle: .bottomRight, to: CGPoint(x: 260, y: 300), constrain: true)
        let square = try #require(document.item(id)?.box)
        #expect(square.width == square.height)
    }

    @Test func resizeAnArrowMovesOneEndAndShiftSnapsTo45Degrees() throws {
        var document = try noiseDocument()
        let id = document.add(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)))
        #expect(document.handle(of: id, at: CGPoint(x: 11, y: 1), radius: 4) == .end)
        document.resize(id, handle: .end, to: CGPoint(x: 100, y: 90), constrain: true)
        let end = try #require(document.item(id)?.end)
        #expect(abs(end.x - end.y) < 1e-9, "snapped onto the diagonal")
        #expect(document.item(id)?.start == CGPoint(x: 0, y: 0))
    }

    @Test func handleLookupFindsTheNearestHandle() throws {
        var document = try noiseDocument()
        let id = document.add(.rectangle(CGRect(x: 100, y: 100, width: 100, height: 60)))
        #expect(document.handle(of: id, at: CGPoint(x: 101, y: 99), radius: 6) == .topLeft)
        #expect(document.handle(of: id, at: CGPoint(x: 150, y: 161), radius: 6) == .bottom)
        #expect(document.handle(of: id, at: CGPoint(x: 150, y: 130), radius: 6) == nil)
    }

    @Test func deleteAndDuplicate() throws {
        var document = try noiseDocument()
        let id = document.add(.text("this one", at: CGPoint(x: 30, y: 40)))
        let duplicated = document.duplicate(id)
        let copy = try #require(duplicated)
        #expect(document.items.count == 2)
        #expect(document.items.last?.id == copy)
        #expect(document.item(copy)?.start == CGPoint(x: 42, y: 52))
        #expect(document.item(copy)?.text == "this one")
        let deleted = document.delete(id)
        #expect(deleted)
        #expect(document.items.map(\.id) == [copy])
        let deletedAgain = document.delete(id)
        #expect(!deletedAgain)
    }

    @Test func textBoundsGrowWithTheTextAndThePill() throws {
        let short = AnnotationItem.text("Hi", at: .zero)
        let long = AnnotationItem.text("A much longer note", at: .zero)
        #expect(long.bounds.width > short.bounds.width)
        #expect(short.bounds.height >= 30, "30 pt text is at least 30 pt tall")
        let pill = AnnotationItem.text("Hi", at: .zero, pill: true)
        #expect(pill.bounds.width > short.bounds.width)
        #expect(!AnnotationItem.text("  ", at: .zero).isMeaningful)
    }

    // MARK: Crop

    @Test func cropClampsSnapsToEdgesAndClears() throws {
        var document = try noiseDocument()
        document.crop(to: CGRect(x: 50, y: 40, width: 100, height: 80))
        #expect(document.cropRect == CGRect(x: 50, y: 40, width: 100, height: 80))
        #expect(document.outputPixelSize == (200, 160))

        // 2 pt from the left edge is 4 px, inside the 6 px snap.
        document.crop(to: CGRect(x: 2, y: -20, width: 100, height: 100))
        #expect(document.cropRect == CGRect(x: 0, y: 0, width: 102, height: 80))

        document.crop(to: CGRect(x: -10, y: -10, width: 1000, height: 1000))
        #expect(document.cropRect == nil, "a crop of the whole image is no crop")

        document.crop(to: CGRect(x: 10, y: 10, width: 3, height: 3))
        #expect(document.cropRect == nil, "a crop under 8 points is ignored")

        document.crop(to: CGRect(x: 100, y: 100, width: 50, height: 50))
        document.resetCrop()
        #expect(document.outputRect == document.imageBounds)
    }

    @Test func flattenAppliesTheCrop() throws {
        var document = try noiseDocument()
        document.crop(to: CGRect(x: 100, y: 50, width: 150, height: 100))
        let flat = try Flattener.flatten(document)
        #expect(flat.width == 300)
        #expect(flat.height == 200)
        let source = try #require(SyntheticImages.rgbaBytes(of: document.image))
        let output = try #require(SyntheticImages.rgbaBytes(of: flat))
        // Pixel (0, 0) of the output is pixel (200, 100) of the source.
        for (x, y) in [(0, 0), (17, 33), (299, 199)] {
            #expect(pixel(output, width: 300, x: x, y: y) == pixel(source, width: 800, x: 200 + x, y: 100 + y))
        }
    }

    // MARK: Flatten

    @Test func flattenDrawsRectangleArrowAndText() throws {
        let white = try #require(SyntheticImages.solid(width: 800, height: 600, color: .white))
        var document = AnnotationDocument(image: white, scale: 2)
        document.add(.rectangle(CGRect(x: 20, y: 20, width: 100, height: 60)))
        document.add(.arrow(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 200)))
        document.add(.text("Note", at: CGPoint(x: 200, y: 40)))
        let flat = try Flattener.flatten(document)
        #expect(flat.width == 800 && flat.height == 600)
        // Rectangle edge at x = 20 pt is x = 40 px; the inside stays white.
        let edge = try #require(SyntheticImages.pixel(of: flat, x: 40, y: 100))
        #expect(edge.red > 200 && edge.green < 120, "red stroke: \(edge)")
        #expect(try #require(SyntheticImages.pixel(of: flat, x: 140, y: 100)) == .white)
        // Arrow shaft at y = 200 pt.
        let shaft = try #require(SyntheticImages.pixel(of: flat, x: 500, y: 400))
        #expect(shaft.red > 200 && shaft.green < 120, "arrow: \(shaft)")
        // Some text pixels are red.
        let bytes = try #require(SyntheticImages.rgbaBytes(of: flat))
        var redCount = 0
        for y in 80..<160 {
            for x in 400..<560 where bytes[(y * 800 + x) * 4 + 1] < 128 { redCount += 1 }
        }
        #expect(redCount > 200, "text drawn: \(redCount) red pixels")
    }

    @Test func flattenRemovesOriginalPixelsUnderPixelate() throws {
        var document = try noiseDocument()
        // 192 x 96 points = 384 x 192 px; the cell is max(8, 192 / 12) = 16 px.
        let region = CGRect(x: 40, y: 60, width: 192, height: 96)
        document.add(.pixelate(region))
        let flat = try Flattener.flatten(document)
        let source = try #require(SyntheticImages.rgbaBytes(of: document.image))
        let output = try #require(SyntheticImages.rgbaBytes(of: flat))
        let cell = Flattener.cellSize(forPixelWidth: 384, height: 192)
        #expect(cell == 16)

        let originX = 80
        let originY = 120
        var unchanged = 0
        var total = 0
        var nonUniformCells = 0
        var cellColors = Set<[UInt8]>()
        for cellY in stride(from: 0, to: 192, by: cell) {
            for cellX in stride(from: 0, to: 384, by: cell) {
                let first = pixel(output, width: 800, x: originX + cellX, y: originY + cellY)
                cellColors.insert(first)
                var uniform = true
                for y in cellY..<(cellY + cell) {
                    for x in cellX..<(cellX + cell) {
                        let out = pixel(output, width: 800, x: originX + x, y: originY + y)
                        let original = pixel(source, width: 800, x: originX + x, y: originY + y)
                        if out != first { uniform = false }
                        if out == original { unchanged += 1 }
                        total += 1
                    }
                }
                if !uniform { nonUniformCells += 1 }
            }
        }
        #expect(nonUniformCells == 0, "every cell is one flat colour (a mosaic)")
        #expect(cellColors.count > 20, "the mosaic still follows the image: \(cellColors.count) colours")
        #expect(Double(unchanged) / Double(total) < 0.02, "\(unchanged) of \(total) pixels kept their original value")

        // Outside the region the image is untouched.
        for (x, y) in [(10, 10), (79, 150), (470, 150), (200, 400)] {
            #expect(pixel(output, width: 800, x: x, y: y) == pixel(source, width: 800, x: x, y: y))
        }
    }

    @Test func pixelateCellIsAtLeastEightPixels() {
        #expect(Flattener.cellSize(forPixelWidth: 40, height: 30) == 8)
        #expect(Flattener.cellSize(forPixelWidth: 1200, height: 600) == 50)
    }
}
