import CoreGraphics
import CryptoKit
import Foundation
import SnapCore
import Testing

private func bytes(_ image: CGImage) throws -> [UInt8] {
    try #require(SyntheticImages.rgbaBytes(of: image))
}

private func hash(_ image: CGImage) throws -> String {
    SHA256.hash(data: Data(try bytes(image))).map { String(format: "%02x", $0) }.joined()
}

/// Mean color of a pixel rectangle (top-left origin) as 0 to 255 doubles.
private func meanColor(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) throws -> [Double] {
    let data = try bytes(image)
    var total = [0.0, 0.0, 0.0]
    for row in y..<(y + height) {
        for column in x..<(x + width) {
            let base = (row * image.width + column) * 4
            for channel in 0..<3 { total[channel] += Double(data[base + channel]) }
        }
    }
    return total.map { $0 / Double(width * height) }
}

private func expectedBytes(_ color: RGBAColor) -> [Double] {
    [color.red * 255, color.green * 255, color.blue * 255]
}

@Suite struct MeshGradientTests {
    @Test func sixMeshesWithNineColorsEach() {
        #expect(MeshID.allCases.map(\.rawValue) == ["haze", "bloom", "tide", "dune", "nebula", "orchard"])
        for id in MeshID.allCases {
            #expect(id.grid.count == 9, "\(id)")
        }
        #expect(MeshID(name: "Haze") == .haze)
        #expect(MeshID(name: "nope") == nil)
        #expect(MeshID.orchard.displayName == "Orchard")
    }

    @Test func cornersMatchTheGridColorsWithin3Of255() throws {
        for id in MeshID.allCases {
            let image = try #require(MeshGradientPainter.image(id, width: 712, height: 512))
            let grid = id.grid
            let corners: [(x: Int, y: Int, color: RGBAColor)] = [
                (2, 2, grid[0]), (712 - 4, 2, grid[2]), (2, 512 - 4, grid[6]), (712 - 4, 512 - 4, grid[8]),
            ]
            for corner in corners {
                let mean = try meanColor(image, x: corner.x, y: corner.y, width: 2, height: 2)
                for (got, want) in zip(mean, expectedBytes(corner.color)) {
                    #expect(abs(got - want) <= 3, "\(id) corner \(corner.x),\(corner.y): \(got) vs \(want)")
                }
            }
        }
    }

    @Test func centreMatchesTheCentreColor() throws {
        let image = try #require(MeshGradientPainter.image(.tide, width: 640, height: 480))
        let mean = try meanColor(image, x: 319, y: 239, width: 2, height: 2)
        for (got, want) in zip(mean, expectedBytes(MeshID.tide.grid[4])) {
            #expect(abs(got - want) <= 3)
        }
    }

    @Test func samplesAreSixtyFourSquareAndPassThroughTheCorners() {
        let samples = MeshGradientPainter.samples(for: .haze)
        #expect(samples.count == 64 * 64 * 3)
        let grid = MeshID.haze.grid
        #expect(abs(samples[0] - grid[0].red) < 1e-9)
        let last = samples.count - 3
        #expect(abs(samples[last] - grid[8].red) < 1e-9)
        #expect(abs(samples[last + 2] - grid[8].blue) < 1e-9)
    }

    @Test func theBlurRunsOnTheSixtyFourGridAndOneDrawUpscalesItToFiveK() throws {
        let grid = try #require(MeshGradientPainter.gridImage(.haze))
        #expect(grid.width == 64 && grid.height == 64 && grid.bitsPerComponent == 16)
        // A 5K canvas used to need full-size Double buffers (about 350 MB); now it is one draw.
        let start = Date()
        let image = try #require(MeshGradientPainter.image(.haze, width: 5120, height: 2880))
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(image.width == 5120 && image.height == 2880)
        let grid9 = MeshID.haze.grid
        let mean = try meanColor(image, x: 5120 - 4, y: 2880 - 4, width: 2, height: 2)
        for (got, want) in zip(mean, expectedBytes(grid9[8])) {
            #expect(abs(got - want) <= 3)
        }
    }

    @Test func rendersTwiceToIdenticalBytes() throws {
        for id in MeshID.allCases {
            let first = try #require(MeshGradientPainter.image(id, width: 301, height: 199))
            let second = try #require(MeshGradientPainter.image(id, width: 301, height: 199))
            #expect(try hash(first) == hash(second), "\(id)")
        }
    }

    @Test func meshesDifferFromEachOther() throws {
        var hashes = Set<String>()
        for id in MeshID.allCases {
            hashes.insert(try hash(try #require(MeshGradientPainter.image(id, width: 120, height: 80))))
        }
        #expect(hashes.count == 6)
    }

    @Test func imageIsSmoothWithNoBanding() throws {
        // Neighbouring pixels of a smooth mesh never jump by more than a few levels.
        let image = try #require(MeshGradientPainter.image(.bloom, width: 600, height: 400))
        let data = try bytes(image)
        var largest = 0
        for row in 0..<image.height {
            for column in 1..<image.width {
                let base = (row * image.width + column) * 4
                for channel in 0..<3 {
                    largest = max(largest, abs(Int(data[base + channel]) - Int(data[base - 4 + channel])))
                }
            }
        }
        #expect(largest <= 3)
    }

    @Test func beautifyWithMeshIsByteIdenticalAndKeepsTheGeometry() throws {
        let image = try #require(SyntheticFixture.block2x.makeImage())
        let preset = BackgroundPreset(background: .mesh(.haze))
        let first = try BeautifyRenderer.render(image, scale: 2, preset: preset)
        let second = try BeautifyRenderer.render(image, scale: 2, preset: preset)
        #expect(first.image.width == 712)
        #expect(first.image.height == 512)
        #expect(try hash(first.image) == hash(second.image))

        let solid = try BeautifyRenderer.render(image, scale: 2, preset: BackgroundPreset(background: .none))
        #expect(solid.geometry == first.geometry)

        // The default shadow reaches the corners only faintly, so the corner colours still hold.
        let grid = MeshID.haze.grid
        let corners: [(x: Int, y: Int, color: RGBAColor)] = [
            (2, 2, grid[0]), (712 - 4, 2, grid[2]), (2, 512 - 4, grid[6]), (712 - 4, 512 - 4, grid[8]),
        ]
        for corner in corners {
            let mean = try meanColor(first.image, x: corner.x, y: corner.y, width: 2, height: 2)
            for (got, want) in zip(mean, expectedBytes(corner.color)) {
                #expect(abs(got - want) <= 3, "corner \(corner.x),\(corner.y): \(got) vs \(want)")
            }
        }
    }

    @Test func meshFillCodesParsesAndKeepsOldPresetsReadable() throws {
        #expect(BackgroundFill(parsing: "mesh:haze") == .mesh(.haze))
        #expect(BackgroundFill(parsing: "mesh:Orchard") == .mesh(.orchard))
        #expect(BackgroundFill(parsing: "mesh:nope") == nil)

        let preset = BackgroundPreset(background: .mesh(.dune))
        let data = try JSONEncoder().encode(preset)
        #expect(try JSONDecoder().decode(BackgroundPreset.self, from: data).background == .mesh(.dune))

        let old = Data(##"{"background":{"type":"gradient","gradient":"ocean"}}"##.utf8)
        #expect(try JSONDecoder().decode(BackgroundPreset.self, from: old).background == .gradient(.ocean))
        let unknown = Data(##"{"background":{"type":"mesh","mesh":"gone"}}"##.utf8)
        #expect(try JSONDecoder().decode(BackgroundPreset.self, from: unknown).background == .gradient(.dusk))
    }
}
