import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A tall "page" of rows that are all different except for blank runs, cut into frames the way a
/// scrolling window shows it: a fixed header and footer, and a scrollbar strip on the right that
/// changes from frame to frame.
struct ScrollFixture {
    static let width = 120
    static let header = 14
    static let footer = 10
    static let content = 90
    static let scrollbar = 6
    let pageHeight: Int

    init(pageHeight: Int = 600) {
        self.pageHeight = pageHeight
    }

    /// RGBA of one page row: a gradient seeded by the row, or white for the blank runs.
    func pageRow(_ y: Int) -> [UInt8] {
        let blank = (y / 40) % 3 == 2 && y % 40 < 12
        var row: [UInt8] = []
        row.reserveCapacity(Self.width * 4)
        for x in 0..<Self.width {
            if blank {
                row += [255, 255, 255, 255]
            } else {
                let seed = UInt64(y) &* 2_654_435_761 &+ UInt64(x / 8) &* 40_503
                row += [UInt8(truncatingIfNeeded: seed), UInt8(truncatingIfNeeded: seed >> 8),
                        UInt8(truncatingIfNeeded: seed >> 16), 255]
            }
        }
        return row
    }

    func fixedRow(_ y: Int, footer: Bool) -> [UInt8] {
        let value: UInt8 = footer ? 40 : 200
        return (0..<Self.width).flatMap { x in [value, UInt8(x % 255), UInt8(y * 9 % 255), 255] }
    }

    /// The frame with the page scrolled to `offset`; `frameIndex` moves the scrollbar thumb.
    func frame(offset: Int, frameIndex: Int) -> CGImage? {
        var bytes: [UInt8] = []
        let rows = (0..<Self.header).map { fixedRow($0, footer: false) }
            + (0..<Self.content).map { pageRow(offset + $0) }
            + (0..<Self.footer).map { fixedRow($0, footer: true) }
        for (y, row) in rows.enumerated() {
            var row = row
            for x in (Self.width - Self.scrollbar)..<Self.width {
                let thumb = abs(y - frameIndex * 7 % rows.count) < 12
                let value: UInt8 = thumb ? 90 : 230
                row.replaceSubrange((x * 4)..<(x * 4 + 4), with: [value, value, value, 255])
            }
            bytes += row
        }
        return SyntheticImages.image(fromRGBA: bytes, width: Self.width, height: rows.count)
    }

    /// The page rows the stitched image must hold between the header and the footer.
    func expectedContent(through offset: Int) -> [[UInt8]] {
        (0..<(offset + Self.content)).map { pageRow($0) }
    }
}

@Suite struct ScrollStitcherTests {
    let fixture = ScrollFixture()

    func rows(of image: CGImage) throws -> [[UInt8]] {
        let bytes = try #require(SyntheticImages.rgbaBytes(of: image))
        let stride = image.width * 4
        return (0..<image.height).map { Array(bytes[($0 * stride)..<($0 * stride + stride)]) }
    }

    /// Everything but the scrollbar strip, which differs by frame on purpose.
    func trimmed(_ row: [UInt8]) -> [UInt8] {
        Array(row[0..<((ScrollFixture.width - ScrollFixture.scrollbar) * 4)])
    }

    func makeStitcher() -> ScrollStitcher {
        ScrollStitcher(ignoredTrailingColumns: ScrollFixture.scrollbar)
    }

    @Test func framesScrolledDownJoinIntoTheWholePageWithTheHeaderAndFooterOnce() throws {
        var stitcher = makeStitcher()
        let offsets = [0, 23, 51, 52, 90, 141, 199, 260, 330]
        for (index, offset) in offsets.enumerated() {
            let frame = try #require(fixture.frame(offset: offset, frameIndex: index))
            let outcome = stitcher.add(frame)
            if index == 0 {
                #expect(outcome == .first)
            } else {
                #expect(outcome == .added(rows: offset - offsets[index - 1]), "frame \(index)")
            }
        }
        let image = try #require(stitcher.makeImage())
        let last = try #require(offsets.last)
        #expect(image.width == ScrollFixture.width)
        #expect(image.height == ScrollFixture.header + last + ScrollFixture.content + ScrollFixture.footer)
        #expect(stitcher.pixelHeight == image.height)

        let stitched = try rows(of: image).map(trimmed)
        let header = (0..<ScrollFixture.header).map { trimmed(fixture.fixedRow($0, footer: false)) }
        let footer = (0..<ScrollFixture.footer).map { trimmed(fixture.fixedRow($0, footer: true)) }
        let content = fixture.expectedContent(through: last).map(trimmed)
        #expect(Array(stitched.prefix(ScrollFixture.header)) == header)
        #expect(Array(stitched.suffix(ScrollFixture.footer)) == footer)
        #expect(Array(stitched.dropFirst(ScrollFixture.header).dropLast(ScrollFixture.footer)) == content)
    }

    @Test func anUnchangedFrameAddsNothing() throws {
        var stitcher = makeStitcher()
        _ = stitcher.add(try #require(fixture.frame(offset: 0, frameIndex: 0)))
        #expect(stitcher.add(try #require(fixture.frame(offset: 0, frameIndex: 1))) == .unchanged)
        #expect(stitcher.pixelHeight == ScrollFixture.header + ScrollFixture.content + ScrollFixture.footer)
    }

    @Test func aJumpPastTheOverlapIsTooFastAndTheNextCloseFrameStillJoins() throws {
        var stitcher = makeStitcher()
        _ = stitcher.add(try #require(fixture.frame(offset: 0, frameIndex: 0)))
        #expect(stitcher.add(try #require(fixture.frame(offset: 200, frameIndex: 1))) == .tooFast)
        // Scrolling back up into the overlap with the last kept frame picks up where it left off.
        #expect(stitcher.add(try #require(fixture.frame(offset: 40, frameIndex: 2))) == .added(rows: 40))
    }

    @Test func scrollingBackUpAddsNothing() throws {
        var stitcher = makeStitcher()
        _ = stitcher.add(try #require(fixture.frame(offset: 0, frameIndex: 0)))
        _ = stitcher.add(try #require(fixture.frame(offset: 60, frameIndex: 1)))
        let height = stitcher.pixelHeight
        #expect(stitcher.add(try #require(fixture.frame(offset: 30, frameIndex: 2))) == .unchanged)
        #expect(stitcher.pixelHeight == height)
    }

    @Test func theImageStopsGrowingAtThePixelLimit() throws {
        let limit = ScrollFixture.width * 200
        var stitcher = ScrollStitcher(ignoredTrailingColumns: ScrollFixture.scrollbar, maxPixels: limit)
        var outcomes: [ScrollStitcher.Outcome] = []
        for (index, offset) in stride(from: 0, through: 400, by: 50).enumerated() {
            outcomes.append(stitcher.add(try #require(fixture.frame(offset: offset, frameIndex: index))))
        }
        #expect(outcomes.contains(.full))
        #expect(stitcher.pixelHeight <= 200)
        #expect(stitcher.makeImage() != nil)
    }

    @Test func aFixedSidebarBesideTheScrollingContentStillJoins() throws {
        // A full-height sidebar that does not scroll changes nothing between frames, so every
        // full-width row differs; the match falls back to a band of columns that scrolls.
        func withSidebar(_ image: CGImage?, frameIndex: Int) throws -> CGImage {
            let image = try #require(image)
            var bytes = try #require(SyntheticImages.rgbaBytes(of: image))
            for y in 0..<image.height {
                for x in 0..<30 {
                    let index = (y * image.width + x) * 4
                    bytes.replaceSubrange(index..<(index + 4), with: [UInt8(y % 200), 60, UInt8(x * 5), 255])
                }
            }
            return try #require(SyntheticImages.image(fromRGBA: bytes, width: image.width, height: image.height))
        }
        var stitcher = makeStitcher()
        _ = stitcher.add(try withSidebar(fixture.frame(offset: 0, frameIndex: 0), frameIndex: 0))
        #expect(stitcher.add(try withSidebar(fixture.frame(offset: 37, frameIndex: 1), frameIndex: 1)) == .added(rows: 37))
        #expect(stitcher.add(try withSidebar(fixture.frame(offset: 80, frameIndex: 2), frameIndex: 2)) == .added(rows: 43))
    }

    @Test func aFrameOfAnotherSizeIsRejected() throws {
        var stitcher = makeStitcher()
        _ = stitcher.add(try #require(fixture.frame(offset: 0, frameIndex: 0)))
        let other = try #require(SyntheticImages.solid(width: 50, height: 50, color: .init(red: 1, green: 2, blue: 3)))
        #expect(stitcher.add(other) == .unchanged)
    }
}
