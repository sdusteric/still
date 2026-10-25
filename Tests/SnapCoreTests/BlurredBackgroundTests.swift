import CoreGraphics
import Foundation
import SnapCore
import Testing

/// Luminance standard deviation of a pixel rectangle (top-left origin).
private func luminanceStdDev(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) throws -> Double {
    let data = try #require(SyntheticImages.rgbaBytes(of: image))
    var values: [Double] = []
    values.reserveCapacity(width * height)
    for row in y..<(y + height) {
        for column in x..<(x + width) {
            let base = (row * image.width + column) * 4
            values.append(SyntheticImages.Pixel(red: data[base], green: data[base + 1], blue: data[base + 2]).luminance)
        }
    }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return variance.squareRoot()
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> SyntheticImages.Pixel {
    try #require(SyntheticImages.pixel(of: image, x: x, y: y))
}

private let blurred = BackgroundPreset(background: .blurredCapture)

@Suite struct BlurredBackgroundTests {
    @Test func noiseCaptureGives1256By856WithAQuietPadding() throws {
        let input = try #require(SyntheticFixture.noise2x.makeImage())
        let output = try BeautifyRenderer.render(input, scale: 2, preset: blurred)
        #expect(output.image.width == 1256)
        #expect(output.image.height == 856)

        let inputDeviation = try luminanceStdDev(input, x: 0, y: 0, width: input.width, height: input.height)
        // A 16 px band of the 28 px padding, down the left edge.
        let band = try luminanceStdDev(output.image, x: 0, y: 100, width: 16, height: 600)
        #expect(inputDeviation > 20)
        #expect(band <= inputDeviation * 0.5, "band \(band) input \(inputDeviation)")
    }

    @Test func geometryMatchesTheOtherBackgrounds() throws {
        let input = try #require(SyntheticFixture.block2x.makeImage())
        let blurredOutput = try BeautifyRenderer.render(input, scale: 2, preset: blurred)
        let solidOutput = try BeautifyRenderer.render(input, scale: 2, preset: BackgroundPreset(background: .none))
        #expect(blurredOutput.image.width == 712)
        #expect(blurredOutput.image.height == 512)
        #expect(blurredOutput.geometry == solidOutput.geometry)
    }

    @Test func backgroundIsOpaqueAcrossTheCanvas() throws {
        let input = try #require(SyntheticFixture.window2x.makeImage())
        let output = try BeautifyRenderer.render(input, scale: 2, preset: blurred)
        let width = output.image.width
        let height = output.image.height
        for point in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1), (width / 2, 2)] {
            #expect(try pixel(output.image, point.0, point.1).alpha == 255, "\(point)")
        }
    }

    @Test func brightnessAndSaturationAreApplied() throws {
        let color = SyntheticImages.Pixel(red: 200, green: 100, blue: 100)
        let capture = try #require(SyntheticImages.solid(width: 400, height: 300, color: color))
        let space = SyntheticImages.colorSpace
        let result = try #require(BlurredCaptureBackground.image(from: capture, width: 400, height: 300, space: space))
        let got = try pixel(result, 200, 150)
        // Brightness -0.06 (about 15 levels) and saturation 1.15: the mean drops and the spread grows.
        let before = Double(color.red) + Double(color.green) + Double(color.blue)
        let after = Double(got.red) + Double(got.green) + Double(got.blue)
        #expect(after < before - 20)
        #expect(Int(got.red) - Int(got.green) > Int(color.red) - Int(color.green))
    }

    @Test func radiusIsSixPercentOfTheLongSide() {
        #expect(BlurredCaptureBackground.radius(width: 1256, height: 856) == 1256 * 0.06)
        #expect(BlurredCaptureBackground.radius(width: 400, height: 900) == 54)
        #expect(BlurredCaptureBackground.brightness == -0.06)
        #expect(BlurredCaptureBackground.saturation == 1.15)
    }

    @Test func captureIsAspectFilledNotStretched() throws {
        // A wide capture with a red left half and a blue right half, drawn onto a tall canvas: the
        // middle of the canvas stays a blend and the top and bottom rows match each other.
        let wide = try #require(SyntheticImages.block(
            width: 800, height: 200, block: CGRect(x: 0, y: 0, width: 400, height: 200),
            background: .init(red: 0, green: 0, blue: 255), color: .init(red: 255, green: 0, blue: 0)
        ))
        let result = try #require(BlurredCaptureBackground.image(
            from: wide, width: 300, height: 600, space: SyntheticImages.colorSpace
        ))
        let top = try pixel(result, 150, 20)
        let bottom = try pixel(result, 150, 580)
        #expect(abs(Int(top.red) - Int(bottom.red)) <= 6)
        let left = try pixel(result, 10, 300)
        let right = try pixel(result, 290, 300)
        #expect(left.red > right.red)
        #expect(right.blue > left.blue)
    }

    @Test func blurredFillCodesParsesAndKeepsOldPresetsReadable() throws {
        #expect(BackgroundFill(parsing: "blurred") == .blurredCapture)
        let data = try JSONEncoder().encode(blurred)
        #expect(try JSONDecoder().decode(BackgroundPreset.self, from: data).background == .blurredCapture)
        let old = Data(##"{"background":{"type":"solid","color":"#F5F5F7"}}"##.utf8)
        #expect(try JSONDecoder().decode(BackgroundPreset.self, from: old).background != .blurredCapture)
        #expect(blurred.clamped().background == .blurredCapture)
    }

    @Test func presetStoreKeepsMeshAndBlurredPresets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "snap-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "presets.json", directoryHint: .notDirectory)
        let store = PresetStore(fileURL: file)
        try store.load()
        try store.save(BackgroundPreset(id: "mesh", name: "Mesh", background: .mesh(.nebula)))
        try store.save(BackgroundPreset(id: "blur", name: "Blur", background: .blurredCapture))

        let reloaded = PresetStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.preset(id: "mesh")?.background == .mesh(.nebula))
        #expect(reloaded.preset(id: "blur")?.background == .blurredCapture)
    }
}
