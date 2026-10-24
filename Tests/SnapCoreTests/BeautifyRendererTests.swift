import CoreGraphics
import Foundation
import SnapCore
import Testing

private let snow = RGBAColor(hex: "#F5F5F7") ?? .white

private func preset(
    background: BackgroundFill = .solid(snow),
    shadow: Double = 32,
    inset: Double = 21,
    ratio: AspectRatio? = nil,
    alignment: Int = 4,
    autoBalance: Bool = true
) -> BackgroundPreset {
    BackgroundPreset(
        background: background, padding: 21, inset: inset, cornerRadius: 0.12, shadow: shadow,
        ratio: ratio, alignment: alignment, autoBalance: autoBalance
    )
}

private func render(_ fixture: SyntheticFixture, _ preset: BackgroundPreset, outputScale: Double? = nil) throws
    -> BeautifyRenderer.Output {
    let image = try #require(fixture.makeImage())
    return try BeautifyRenderer.render(image, scale: fixture.scale, preset: preset, outputScale: outputScale)
}

/// Mean luminance of a pixel rectangle (top-left origin).
private func meanLuminance(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) throws -> Double {
    let bytes = try #require(SyntheticImages.rgbaBytes(of: image))
    var total = 0.0
    for row in y..<(y + height) {
        for column in x..<(x + width) {
            let base = (row * image.width + column) * 4
            total += SyntheticImages.Pixel(red: bytes[base], green: bytes[base + 1], blue: bytes[base + 2]).luminance
        }
    }
    return total / Double(width * height)
}

private func maxChannelDifference(_ lhs: SyntheticImages.Pixel, _ rhs: SyntheticImages.Pixel) -> Int {
    max(abs(Int(lhs.red) - Int(rhs.red)), abs(Int(lhs.green) - Int(rhs.green)), abs(Int(lhs.blue) - Int(rhs.blue)))
}

@Suite struct BeautifyRendererTests {
    // MARK: Section 10.2 worked examples

    @Test func exampleANoiseHasNoInsetAndGives1256By856() throws {
        let output = try render(.noise2x, preset())
        #expect(output.image.width == 1256)
        #expect(output.image.height == 856)
        let geometry = output.geometry
        #expect(abs(geometry.unit - 2.0 / 3.0) < 1e-9)
        #expect(abs(geometry.padding - 14) < 1e-9)
        #expect(geometry.inset == 0)
        #expect(!geometry.uniformBorder)
        #expect(geometry.cardPoints == .init(width: 600, height: 400))
        #expect(geometry.cardRect == .init(x: 28, y: 28, width: 1200, height: 800))
    }

    @Test func exampleBBlockWithAutoBalanceGives712By512() throws {
        let output = try render(.block2x, preset())
        #expect(output.image.width == 712)
        #expect(output.image.height == 512)
        let geometry = output.geometry
        #expect(abs(geometry.inset - 14) < 1e-9)
        #expect(geometry.uniformBorder)
        #expect(abs(geometry.cardPoints.width - 328) < 1e-9)
        #expect(abs(geometry.cardPoints.height - 228) < 1e-9)
        #expect(geometry.cardRect == .init(x: 28, y: 28, width: 656, height: 456))
        #expect(geometry.contentRect == .init(x: 100, y: 100, width: 600, height: 400))
        #expect(abs(geometry.radius - 8) < 1e-9)
    }

    @Test func exampleBWithoutAutoBalanceGives1312By912() throws {
        let output = try render(.block2x, preset(autoBalance: false))
        #expect(output.image.width == 1312)
        #expect(output.image.height == 912)
        #expect(abs(output.geometry.cardPoints.width - 628) < 1e-9)
        #expect(abs(output.geometry.cardPoints.height - 428) < 1e-9)
    }

    @Test func exampleBAtSixteenByNineGives910By512() throws {
        let ratio = AspectRatio(width: 16, height: 9)
        let output = try render(.block2x, preset(ratio: ratio, alignment: 4))
        #expect(output.image.width == 910)
        #expect(output.image.height == 512)
        let geometry = output.geometry
        #expect(abs(geometry.canvasPoints.width - 455.111) < 0.001)
        #expect(abs(geometry.canvasPoints.height - 256) < 1e-9)
        // Centred: equal space left and right of the card.
        let rect = geometry.cardRect
        #expect(abs(rect.x - (910 - rect.x - rect.width)) <= 1)
        #expect(rect.y == 28)
    }

    @Test func alignmentPlacesTheCardInTheExtraSpace() throws {
        let ratio = AspectRatio(width: 16, height: 9)
        let left = try render(.block2x, preset(ratio: ratio, alignment: 0)).geometry.cardRect
        let right = try render(.block2x, preset(ratio: ratio, alignment: 8)).geometry.cardRect
        let bottomLeft = try render(.block2x, preset(ratio: ratio, alignment: 6)).geometry.cardRect
        #expect(left.x == 28)
        #expect(right.x + right.width == 910 - 28)
        #expect(bottomLeft.x == 28)
        let tall = AspectRatio(width: 1, height: 1)
        let top = try render(.block2x, preset(ratio: tall, alignment: 1)).geometry
        let bottom = try render(.block2x, preset(ratio: tall, alignment: 7)).geometry
        #expect(top.cardRect.y == 28)
        #expect(bottom.cardRect.y + bottom.cardRect.height == bottom.canvasSize.height - 28)
        #expect(top.canvasSize.width == top.canvasSize.height)
    }

    @Test func alignmentIsIgnoredWithoutARatio() throws {
        let corner = try render(.block2x, preset(alignment: 0)).geometry
        let centre = try render(.block2x, preset(alignment: 4)).geometry
        #expect(corner == centre)
    }

    @Test func oneXInputRendersAtOneX() throws {
        let output = try render(.block1x, preset())
        #expect(output.image.width == 356)
        #expect(output.image.height == 256)
        #expect(output.geometry.scale == 1)
    }

    @Test func unitIsClampedToHalfAndThree() throws {
        let tiny = try #require(SyntheticImages.noise(width: 100, height: 100))
        #expect(try BeautifyRenderer.render(tiny, scale: 1, preset: preset()).geometry.unit == 0.5)
        let huge = try #require(SyntheticImages.noise(width: 2400, height: 2400))
        #expect(try BeautifyRenderer.render(huge, scale: 1, preset: preset()).geometry.unit == 3)
    }

    @Test func previewScaleKeepsTheLayoutProportions() throws {
        let preview = try render(.block2x, preset(), outputScale: 1)
        #expect(preview.image.width == 356)
        #expect(preview.image.height == 256)
        #expect(preview.geometry.cardRect == .init(x: 14, y: 14, width: 328, height: 228))
    }

    @Test func cornerRadiusIsCappedAtHalfTheShortSide() throws {
        let pill = BackgroundPreset(background: .solid(snow), padding: 0, inset: 0, cornerRadius: 1, shadow: 0)
        let small = try #require(SyntheticImages.noise(width: 60, height: 40))
        let capped = try BeautifyRenderer.render(small, scale: 1, preset: pill).geometry
        #expect(capped.radius == 20)
        #expect(capped.radiusPixels == 20)
        // A larger image keeps cornerRadius * 100 * u: 66.7 pt at u = 0.667.
        let free = try render(.noise2x, pill).geometry
        #expect(abs(free.radius - 100 * 2.0 / 3.0) < 1e-9)
    }

    // MARK: Pixels

    @Test func cardCornerShowsTheBackgroundNotTheContent() throws {
        let output = try render(.block2x, preset())
        let rect = output.geometry.cardRect
        let corner = try #require(SyntheticImages.pixel(of: output.image, x: rect.x + 1, y: rect.y + 1))
        let background = SyntheticImages.Pixel(red: 0xF5, green: 0xF5, blue: 0xF7)
        #expect(maxChannelDifference(corner, background) <= 40)
        let distanceFromRed = max(
            abs(Int(corner.red) - 255), abs(Int(corner.green)), abs(Int(corner.blue))
        )
        #expect(distanceFromRed >= 60)
        // The middle of the card's top edge is inside the rounded rectangle: white card colour.
        let edge = try #require(SyntheticImages.pixel(of: output.image, x: rect.x + rect.width / 2, y: rect.y + 4))
        #expect(edge.red > 235 && edge.green > 235 && edge.blue > 235)
    }

    @Test func shadowDarkensTheBandBelowTheCard() throws {
        let withShadow = try render(.block2x, preset(shadow: 32))
        let rect = withShadow.geometry.cardRect
        let band = try meanLuminance(
            withShadow.image, x: rect.x + 20, y: rect.y + rect.height, width: rect.width - 40, height: 8
        )
        let background = SyntheticImages.Pixel(red: 0xF5, green: 0xF5, blue: 0xF7).luminance
        #expect(background - band >= 8)

        let flat = try render(.block2x, preset(shadow: 0))
        let flatBand = try meanLuminance(
            flat.image, x: rect.x + 20, y: rect.y + rect.height, width: rect.width - 40, height: 8
        )
        #expect(abs(flatBand - background) <= 2)
    }

    @Test func shadowFallsDownwardMoreThanUpward() throws {
        let output = try render(.block2x, preset(shadow: 60))
        let rect = output.geometry.cardRect
        let below = try meanLuminance(output.image, x: rect.x + 40, y: rect.y + rect.height, width: rect.width - 80, height: 8)
        let above = try meanLuminance(output.image, x: rect.x + 40, y: rect.y - 8, width: rect.width - 80, height: 8)
        #expect(below < above)
    }

    @Test func redContentHasEqualMargins() throws {
        let output = try render(.block2x, preset(background: .solid(snow), shadow: 0))
        let bytes = try #require(SyntheticImages.rgbaBytes(of: output.image))
        let width = output.image.width
        let height = output.image.height
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                if bytes[base] > 200, bytes[base + 1] < 60, bytes[base + 2] < 60 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        #expect(maxX >= minX)
        let left = minX
        let right = width - 1 - maxX
        let top = minY
        let bottom = height - 1 - maxY
        #expect(abs(left - right) <= 1)
        #expect(abs(top - bottom) <= 1)
        #expect(maxX - minX + 1 == 600)
        #expect(maxY - minY + 1 == 400)
    }

    @Test func windowKeepsItsTransparentCornersInsideTheCard() throws {
        let clear = BackgroundPreset(background: .none, padding: 21, inset: 0, cornerRadius: 0.12, shadow: 0)
        let output = try render(.window2x, clear)
        let rect = output.geometry.cardRect
        #expect(!output.geometry.uniformBorder)
        // Inside the card's own rounded clip but outside the window's larger rounded corner.
        let hole = try #require(SyntheticImages.pixel(of: output.image, x: rect.x + 8, y: rect.y + 8))
        #expect(hole.alpha == 0)
        let corner = try #require(SyntheticImages.pixel(of: output.image, x: rect.x + 1, y: rect.y + 1))
        #expect(corner.alpha == 0)
        let inside = try #require(SyntheticImages.pixel(of: output.image, x: rect.x + rect.width / 2, y: rect.y + 300))
        #expect(inside.alpha == 255)
        let canvasCorner = try #require(SyntheticImages.pixel(of: output.image, x: 2, y: 2))
        #expect(canvasCorner.alpha == 0)
    }

    @Test func gradientRunsFromFirstStopAtTopLeftToLastAtBottomRight() throws {
        let gradient = BackgroundPreset(background: .gradient(.dusk), padding: 60, inset: 0, shadow: 0)
        let output = try render(.noise1x, gradient)
        let topLeft = try #require(SyntheticImages.pixel(of: output.image, x: 0, y: 0))
        let bottomRight = try #require(SyntheticImages.pixel(of: output.image, x: output.image.width - 1, y: output.image.height - 1))
        #expect(maxChannelDifference(topLeft, .init(red: 0x5B, green: 0x6C, blue: 0xFF)) <= 6)
        #expect(maxChannelDifference(bottomRight, .init(red: 0xB6, green: 0x5B, blue: 0xFF)) <= 6)
        #expect(topLeft.alpha == 255 && bottomRight.alpha == 255)
    }

    @Test func solidAndNoneBackgrounds() throws {
        let blue = RGBAColor(hex: "#0A84FF") ?? .black
        let solid = try render(.block1x, preset(background: .solid(blue), shadow: 0))
        let pixel = try #require(SyntheticImages.pixel(of: solid.image, x: 2, y: 2))
        #expect(pixel == .init(red: 0x0A, green: 0x84, blue: 0xFF))
        let none = try render(.block1x, preset(background: .none, shadow: 0))
        #expect(try #require(SyntheticImages.pixel(of: none.image, x: 2, y: 2)).alpha == 0)
    }

    @Test func missingBackgroundImageFallsBackToTheDefaultGradient() throws {
        let missing = BackgroundPreset(
            background: .image(path: "/nonexistent/snap-test-background.png", blur: 12), shadow: 0
        )
        let fallback = BackgroundPreset(background: .gradient(.dusk), shadow: 0)
        let first = try render(.block1x, missing)
        let second = try render(.block1x, fallback)
        #expect(SyntheticImages.rgbaBytes(of: first.image) == SyntheticImages.rgbaBytes(of: second.image))
    }

    @Test func imageBackgroundIsAspectFilledAndBlurred() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "snap-bg-\(UUID().uuidString).png", directoryHint: .notDirectory)
        defer {
            do {
                try FileManager.default.removeItem(at: scratch)
            } catch {
                // The file lives in the temp dir; a leftover is harmless.
            }
        }
        let source = try #require(SyntheticImages.block(
            width: 80, height: 40, block: CGRect(x: 0, y: 0, width: 40, height: 40), background: .white, color: .red
        ))
        try PNGWriter.write(source, scale: 1, to: scratch)
        let sharp = BackgroundPreset(background: .image(path: scratch.path(percentEncoded: false), blur: 0), shadow: 0)
        let output = try render(.block1x, sharp)
        // Left half red, right half white, like the 80x40 source filled to the canvas.
        #expect(try #require(SyntheticImages.pixel(of: output.image, x: 4, y: 4)) == .red)
        #expect(try #require(SyntheticImages.pixel(of: output.image, x: output.image.width - 5, y: 4)) == .white)

        let soft = BackgroundPreset(background: .image(path: scratch.path(percentEncoded: false), blur: 20), shadow: 0)
        let blurred = try render(.block1x, soft)
        let middle = try #require(SyntheticImages.pixel(of: blurred.image, x: blurred.image.width / 2, y: 4))
        #expect(middle.green > 40 && middle.green < 215)
    }

    @Test func outputKeepsTheInputColourSpace() throws {
        let output = try render(.block2x, preset())
        #expect(output.image.colorSpace?.model == .rgb)
    }

    // MARK: Preset model

    @Test func defaultPresetHasTheUsersValues() {
        let preset = BackgroundPreset.factoryDefault
        #expect(preset.padding == 21)
        #expect(preset.inset == 21)
        #expect(preset.cornerRadius == 0.12)
        #expect(preset.shadow == 32)
        #expect(preset.ratio == nil)
        #expect(preset.alignment == 4)
        #expect(preset.autoBalance)
        #expect(preset.background == .gradient(.dusk))
    }

    @Test func presetRoundTripsThroughJSONAndFillsMissingKeys() throws {
        let original = BackgroundPreset(
            id: "x", name: "Sunset", background: .image(path: "/tmp/a.png", blur: 8), padding: 10, inset: 0,
            cornerRadius: 0.5, shadow: 80, ratio: AspectRatio(width: 4, height: 3), alignment: 2, autoBalance: false
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(BackgroundPreset.self, from: data) == original)

        let partial = try JSONDecoder().decode(BackgroundPreset.self, from: Data(#"{"shadow":0}"#.utf8))
        #expect(partial.shadow == 0)
        #expect(partial.padding == 21)
        #expect(partial.background == .gradient(.dusk))

        let solid = try JSONDecoder().decode(
            BackgroundPreset.self, from: Data(##"{"background":{"type":"solid","color":"#F5F5F7"}}"##.utf8)
        )
        #expect(solid.background == .solid(snow))
    }

    @Test func clampedKeepsValuesInRange() {
        let wild = BackgroundPreset(
            background: .image(path: "x", blur: 99), padding: 500, inset: -4, cornerRadius: 3, shadow: 250,
            ratio: AspectRatio(width: 0, height: 1), alignment: 12
        ).clamped()
        #expect(wild.padding == 120)
        #expect(wild.inset == 0)
        #expect(wild.cornerRadius == 1)
        #expect(wild.shadow == 100)
        #expect(wild.alignment == 8)
        #expect(wild.ratio == nil)
        #expect(wild.background == .image(path: "x", blur: 40))
    }

    @Test func parsesBackgroundAndRatioArguments() {
        #expect(BackgroundFill(parsing: "solid:#F5F5F7") == .solid(snow))
        #expect(BackgroundFill(parsing: "gradient:Ocean") == .gradient(.ocean))
        #expect(BackgroundFill(parsing: "none") == BackgroundFill.none)
        #expect(BackgroundFill(parsing: "gradient:nope") == nil)
        #expect(AspectRatio(parsing: "16:9") == AspectRatio(width: 16, height: 9))
        #expect(AspectRatio(parsing: "1.91:1")?.value == 1.91)
        #expect(AspectRatio(parsing: "0:1") == nil)
    }

    @Test func gradientAndSolidCatalogsMatchTheDesign() {
        #expect(GradientID.allCases.count == 12)
        #expect(GradientID.aurora.stops.count == 3)
        #expect(GradientID.dusk.stops.map(\.hex) == ["#5B6CFF", "#B65BFF"])
        #expect(SolidSwatch.all.count == 10)
        #expect(SolidSwatch.all.map(\.color.hex).contains("#F5F5F7"))
    }
}

@Suite struct PresetStoreTests {
    private func makeFile() throws -> (file: URL, cleanup: @Sendable () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "snap-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(path: "presets.json", directoryHint: .notDirectory), {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // The directory lives in the temp dir; a leftover is harmless.
            }
        })
    }

    @Test func firstRunHasTheFactoryDefaultStarred() throws {
        let (file, cleanup) = try makeFile()
        defer { cleanup() }
        let store = PresetStore(fileURL: file)
        #expect(try store.load() == .missing)
        #expect(store.starred == BackgroundPreset.factoryDefault)
        #expect(store.presets.count == 1)
    }

    @Test func saveStarAndDeleteSurviveAReload() throws {
        let (file, cleanup) = try makeFile()
        defer { cleanup() }
        let store = PresetStore(fileURL: file)
        try store.load()
        let sunset = BackgroundPreset(id: "sunset", name: "Sunset", background: .gradient(.citrus), padding: 400, shadow: 10)
        try store.save(sunset)
        #expect(try store.setStarred(id: "sunset"))
        #expect(try store.setStarred(id: "missing") == false)

        let reloaded = PresetStore(fileURL: file)
        #expect(try reloaded.load() == .loaded)
        #expect(reloaded.presets.map(\.id) == ["default", "sunset"])
        #expect(reloaded.starred.id == "sunset")
        #expect(reloaded.starred.padding == 120)

        try reloaded.save(BackgroundPreset(id: "sunset", name: "Renamed", shadow: 5))
        #expect(reloaded.presets.count == 2)
        #expect(reloaded.preset(id: "sunset")?.name == "Renamed")

        try reloaded.delete(id: "sunset")
        #expect(reloaded.starred.id == "default")
        try reloaded.delete(id: "default")
        #expect(reloaded.presets.map(\.id) == ["default"])
    }

    @Test func corruptFileIsMovedAsideAndDefaultsReturn() throws {
        let (file, cleanup) = try makeFile()
        defer { cleanup() }
        try Data("{ not json".utf8).write(to: file)
        let store = PresetStore(fileURL: file)
        guard case .recovered = try store.load() else {
            Issue.record("expected a recovered load")
            return
        }
        #expect(store.starred == BackgroundPreset.factoryDefault)
    }
}
