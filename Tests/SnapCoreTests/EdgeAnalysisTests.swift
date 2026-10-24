import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct EdgeAnalysisTests {
    @Test func whiteBorderWithRedBlockIsUniformAndFindsTheBlock() throws {
        let image = try #require(SyntheticFixture.block2x.makeImage())
        let analysis = try #require(EdgeAnalysis.analyze(image))
        #expect(analysis.isUniform)
        #expect(analysis.matchFraction == 1)
        #expect(analysis.borderColor == .white)
        #expect(analysis.hasContent)
        #expect(analysis.contentBounds == CGRect(x: 100, y: 100, width: 600, height: 400))
    }

    @Test func noiseHasNoUniformBorder() throws {
        let image = try #require(SyntheticFixture.noise2x.makeImage())
        let analysis = try #require(EdgeAnalysis.analyze(image))
        #expect(!analysis.isUniform)
        #expect(analysis.matchFraction < 0.5)
    }

    @Test func windowWithTitleBarAndCornersIsNotUniform() throws {
        let image = try #require(SyntheticFixture.window2x.makeImage())
        let analysis = try #require(EdgeAnalysis.analyze(image))
        #expect(!analysis.isUniform)
    }

    @Test func toleranceIsSixPerChannel() throws {
        // A border that wobbles by 5 stays one colour; one that wobbles by 8 does not.
        func image(wobble: UInt8) throws -> CGImage {
            let width = 40
            let height = 30
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let edge = x == 0 || y == 0 || x == width - 1 || y == height - 1
                    let base = (y * width + x) * 4
                    let value: UInt8 = edge && (x + y) % 2 == 0 ? 200 &+ wobble : 200
                    bytes[base] = value
                    bytes[base + 1] = value
                    bytes[base + 2] = value
                    if x >= 10, x < 20, y >= 8, y < 12 { bytes[base] = 0 }
                }
            }
            return try #require(SyntheticImages.image(fromRGBA: bytes, width: width, height: height))
        }
        let close = try #require(EdgeAnalysis.analyze(try image(wobble: 5)))
        #expect(close.isUniform)
        #expect(close.contentBounds == CGRect(x: 10, y: 8, width: 10, height: 4))

        let far = try #require(EdgeAnalysis.analyze(try image(wobble: 8)))
        #expect(!far.isUniform)
        #expect(far.matchFraction < 0.9)
    }

    @Test func ninetyPercentIsTheUniformThreshold() throws {
        // 100x100 image: the perimeter has 396 pixels. Paint 40 of them dark: 356/396 = 89.9%.
        func image(dark: Int) throws -> CGImage {
            var bytes = [UInt8](repeating: 255, count: 100 * 100 * 4)
            for x in 0..<dark {
                let base = x * 4
                bytes[base] = 0
                bytes[base + 1] = 0
                bytes[base + 2] = 0
            }
            return try #require(SyntheticImages.image(fromRGBA: bytes, width: 100, height: 100))
        }
        #expect(try #require(EdgeAnalysis.analyze(try image(dark: 40))).isUniform == false)
        #expect(try #require(EdgeAnalysis.analyze(try image(dark: 39))).isUniform)
    }

    @Test func solidImageHasNoContent() throws {
        let image = try #require(SyntheticImages.solid(width: 20, height: 10, color: .white))
        let analysis = try #require(EdgeAnalysis.analyze(image))
        #expect(analysis.isUniform)
        #expect(!analysis.hasContent)
        #expect(analysis.contentBounds == CGRect(x: 0, y: 0, width: 20, height: 10))
    }

    @Test func transparentBorderPixelsMatchEachOther() throws {
        let image = try #require(SyntheticImages.solid(width: 12, height: 12, color: .clear))
        let analysis = try #require(EdgeAnalysis.analyze(image))
        #expect(analysis.isUniform)
        #expect(analysis.borderColor.alpha == 0)
    }

    @Test func onePixelImageDoesNotCrash() throws {
        let image = try #require(SyntheticImages.solid(width: 1, height: 1, color: .red))
        let analysis = try #require(EdgeAnalysis.analyze(image))
        #expect(analysis.isUniform)
        #expect(!analysis.hasContent)
    }
}
