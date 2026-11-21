import CoreGraphics
import Foundation

/// Joins frames of one screen region, taken while the user scrolls it down, into one tall image
/// (scrolling capture). Each new frame is matched against the last kept one by exact row
/// hashes: the vertical shift most rows agree on is how far the content moved, and only the rows
/// that came into view are added. Rows that stay put at the top and bottom (a sticky header,
/// toolbar or footer) are found from the first pair that moved and appear once. Blank rows match
/// anywhere, so they never vote, and a strip on the right is left out of the hashes because an
/// overlay scrollbar changes there while scrolling. When whole rows disagree because part of the
/// width stays put (a fixed sidebar), the match is tried again on vertical bands of the frame.
/// Pure and synchronous; run it off the main thread.
public struct ScrollStitcher: Sendable {
    public enum Outcome: Sendable, Hashable {
        /// The first frame: the image so far.
        case first
        /// The content moved down by this many pixel rows, which were added.
        case added(rows: Int)
        /// Nothing new: the same view, a scroll back up, or a frame of another size.
        case unchanged
        /// No overlap with the last kept frame: scrolled too far between two frames.
        case tooFast
        /// The image reached `maxPixels`; the rows were not added.
        case full
    }

    /// Strip on the right, in pixels, left out of matching (the overlay scrollbar).
    public let ignoredTrailingColumns: Int
    /// The largest image, in pixels: 64 M is 256 MB of RGBA.
    public let maxPixels: Int
    /// Fewest shared rows that count as an overlap.
    static let minimumOverlap = 8
    /// Vertical bands tried when the full width does not match.
    static let bands = 4

    private var width = 0
    private var frameHeight = 0
    private var colorSpace: CGColorSpace?
    private var header: [UInt8] = []
    private var body: [UInt8] = []
    private var footer: [UInt8] = []
    private var headerRows = 0
    private var footerRows = 0
    private var fixedRowsKnown = false
    /// Row hashes of the last kept frame (nil for a blank row): full width, then per band.
    private var lastHashes: [UInt64?] = []
    private var lastBandHashes: [[UInt64?]] = []

    public init(ignoredTrailingColumns: Int = 0, maxPixels: Int = 64_000_000) {
        self.ignoredTrailingColumns = max(ignoredTrailingColumns, 0)
        self.maxPixels = maxPixels
    }

    private var rowBytes: Int { width * 4 }

    /// The height of the image so far, in pixels.
    public var pixelHeight: Int {
        guard width > 0 else { return 0 }
        return (header.count + body.count + footer.count) / rowBytes
    }

    public var pixelWidth: Int { width }

    public mutating func add(_ frame: CGImage) -> Outcome {
        if width == 0 { return start(frame) }
        guard frame.width == width, frame.height == frameHeight, let bytes = Self.rgba(frame, colorSpace: colorSpace) else {
            return .unchanged
        }
        let (hashes, bandHashes) = rowHashes(bytes)
        if hashes == lastHashes { return .unchanged }

        var top = headerRows
        var bottom = footerRows
        if !fixedRowsKnown {
            (top, bottom) = fixedRows(lastHashes, hashes)
        }
        let contentStart = top
        let contentEnd = frameHeight - bottom
        guard contentEnd - contentStart > Self.minimumOverlap else { return .unchanged }

        switch bestShift(full: hashes, bands: bandHashes, in: contentStart..<contentEnd) {
        case .none:
            return .tooFast
        case .some(let rows) where rows <= 0:
            return .unchanged
        case .some(let rows):
            if (pixelHeight + rows) * width > maxPixels { return .full }
            if !fixedRowsKnown { fixRows(top: top, bottom: bottom) }
            body += bytes[((contentEnd - rows) * rowBytes)..<(contentEnd * rowBytes)]
            footer = Array(bytes[(contentEnd * rowBytes)...])
            lastHashes = hashes
            lastBandHashes = bandHashes
            return .added(rows: rows)
        }
    }

    /// The stitched image, nil before the first frame.
    public func makeImage() -> CGImage? {
        guard width > 0 else { return nil }
        // One copy into the image's data; the pieces can be hundreds of megabytes.
        var data = Data(capacity: header.count + body.count + footer.count)
        data.append(contentsOf: header)
        data.append(contentsOf: body)
        data.append(contentsOf: footer)
        let height = data.count / rowBytes
        guard let provider = CGDataProvider(data: data as CFData),
              let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: Steps

    private mutating func start(_ frame: CGImage) -> Outcome {
        let space = frame.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard frame.width > 0, frame.height > 0, frame.width * frame.height <= maxPixels,
              let bytes = Self.rgba(frame, colorSpace: space) else { return .unchanged }
        width = frame.width
        frameHeight = frame.height
        colorSpace = space
        body = bytes
        (lastHashes, lastBandHashes) = rowHashes(bytes)
        return .first
    }

    /// Rows equal at the same place in both frames, counted from the top and from the bottom.
    private func fixedRows(_ old: [UInt64?], _ new: [UInt64?]) -> (top: Int, bottom: Int) {
        var top = 0
        while top < frameHeight, old[top] == new[top] { top += 1 }
        var bottom = 0
        while bottom < frameHeight - top, old[frameHeight - 1 - bottom] == new[frameHeight - 1 - bottom] { bottom += 1 }
        // Keep room for the content between them.
        let room = frameHeight - 2 * Self.minimumOverlap
        if top + bottom > room { return (0, 0) }
        return (top, bottom)
    }

    /// Splits the first frame, which is all of `body` so far, into header, body and footer.
    private mutating func fixRows(top: Int, bottom: Int) {
        headerRows = top
        footerRows = bottom
        fixedRowsKnown = true
        header = Array(body[0..<(top * rowBytes)])
        body = Array(body[(top * rowBytes)..<((frameHeight - bottom) * rowBytes)])
        footer = []
    }

    /// The full width's shift when it holds; else the best moving band's; else a band's zero or
    /// negative shift (nothing new); nil when nothing overlaps at all.
    private func bestShift(full: [UInt64?], bands: [[UInt64?]], in content: Range<Int>) -> Int? {
        let whole = shift(from: lastHashes, to: full, in: content)
        if let whole, whole.rows > 0 { return whole.rows }
        var still = whole?.rows
        var best: (rows: Int, agreeing: Int)?
        for (old, new) in zip(lastBandHashes, bands) {
            guard let found = shift(from: old, to: new, in: content) else { continue }
            if found.rows > 0 {
                if found.agreeing > best?.agreeing ?? 0 { best = found }
            } else if still == nil {
                still = found.rows
            }
        }
        return best?.rows ?? still
    }

    /// How far the content moved down (positive) or up (zero or negative) with the rows that agree,
    /// or nil when no row of the new frame appears in the old one.
    private func shift(from old: [UInt64?], to new: [UInt64?], in content: Range<Int>) -> (rows: Int, agreeing: Int)? {
        var rowsByHash: [UInt64: [Int]] = [:]
        for index in content {
            if let hash = old[index] { rowsByHash[hash, default: []].append(index) }
        }
        var votes: [Int: Int] = [:]
        for index in content {
            guard let hash = new[index], let matches = rowsByHash[hash] else { continue }
            for match in matches { votes[match - index, default: 0] += 1 }
        }
        guard let best = votes.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else { return nil }
        let rows = best.key
        guard rows > 0 else { return (rows, best.value) }
        // The overlap must really agree: most of its non-blank rows match at this shift.
        let overlap = content.lowerBound..<(content.upperBound - rows)
        guard overlap.count >= Self.minimumOverlap else { return nil }
        var informative = 0
        var agreeing = 0
        for index in overlap {
            guard let hash = new[index] else { continue }
            informative += 1
            if old[index + rows] == hash { agreeing += 1 }
        }
        guard informative > 0, Double(agreeing) >= 0.8 * Double(informative) else { return nil }
        return (rows, agreeing)
    }

    // MARK: Pixels

    /// A hash of each row without the ignored strip, and of each of `bands` vertical bands of it;
    /// nil for a stretch of one color, which would match anywhere.
    private func rowHashes(_ bytes: [UInt8]) -> (full: [UInt64?], bands: [[UInt64?]]) {
        let usedColumns = max(width - ignoredTrailingColumns, 1)
        let bandCount = usedColumns >= Self.bands * 8 ? Self.bands : 1
        let bandWidth = usedColumns / bandCount
        var full = [UInt64?](repeating: nil, count: frameHeight)
        var bands = [[UInt64?]](repeating: [UInt64?](repeating: nil, count: frameHeight), count: bandCount)
        bytes.withUnsafeBytes { raw in
            for row in 0..<frameHeight {
                let start = row * rowBytes
                let first = raw.loadUnaligned(fromByteOffset: start, as: UInt32.self)
                var uniform = true
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325
                for band in 0..<bandCount {
                    let from = band * bandWidth
                    let to = band == bandCount - 1 ? usedColumns : from + bandWidth
                    let bandFirst = raw.loadUnaligned(fromByteOffset: start + from * 4, as: UInt32.self)
                    var bandUniform = true
                    var bandHash: UInt64 = 0xCBF2_9CE4_8422_2325
                    for column in from..<to {
                        let pixel = raw.loadUnaligned(fromByteOffset: start + column * 4, as: UInt32.self)
                        if pixel != bandFirst { bandUniform = false }
                        if pixel != first { uniform = false }
                        hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                        bandHash = (bandHash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                    }
                    bands[band][row] = bandUniform ? nil : bandHash
                }
                full[row] = uniform ? nil : hash
            }
        }
        return (full, bands)
    }

    /// RGBA, premultiplied, in `colorSpace`, top row first.
    static func rgba(_ image: CGImage, colorSpace: CGColorSpace?) -> [UInt8]? {
        guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}
