import CoreGraphics
import Foundation

/// The six original mesh gradients of design 20.9. Each is a 3 x 3 grid of colours.
public enum MeshID: String, Codable, Sendable, CaseIterable, Hashable {
    case haze, bloom, tide, dune, nebula, orchard

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Case-insensitive lookup by name.
    public init?(name: String) {
        self.init(rawValue: name.lowercased())
    }

    /// Row-major grid colours: 0 top-left, 4 centre, 8 bottom-right.
    public var grid: [RGBAColor] {
        let hexes: [String]
        switch self {
        case .haze:
            hexes = [
                "#A5B4FC", "#CBC4FD", "#F0ABFC",
                "#B3C9F4", "#C7D2FE", "#F3BEDB",
                "#99F6E4", "#CDEBBE", "#FDE68A",
            ]
        case .bloom:
            hexes = [
                "#FB7185", "#FD9A82", "#FDBA74",
                "#FC8D9A", "#FDA4AF", "#FDB09A",
                "#F78CA8", "#F472B6", "#F690AE",
            ]
        case .tide:
            hexes = [
                "#22D3EE", "#1AB8F0", "#3B82F6",
                "#18B4E8", "#0EA5E9", "#2F6FD8",
                "#1D4B9C", "#1E3A8A", "#2347A0",
            ]
        case .dune:
            hexes = [
                "#FDE68A", "#F9D77A", "#F59E0B",
                "#F6DE96", "#F3D9A4", "#F4B64C",
                "#DDAE76", "#D6A16B", "#E8BE80",
            ]
        case .nebula:
            hexes = [
                "#6D28D9", "#A12AA8", "#DB2777",
                "#4C2AA6", "#312E81", "#7E2A7A",
                "#2A2478", "#1E1B4B", "#4B1F5E",
            ]
        case .orchard:
            hexes = [
                "#BEF264", "#7DE882", "#34D399",
                "#A6F27F", "#86EFAC", "#5CE3A0",
                "#D8EC6A", "#FDE047", "#A8EC8C",
            ]
        }
        return hexes.compactMap { RGBAColor(hex: $0) }
    }
}

/// Draws the meshes without Core Image or the GPU, so the same preset gives the same bytes: the
/// grid is interpolated bicubically (Catmull-Rom through the nine colours) at 64 x 64 samples,
/// softened there with a small Gaussian blur, and upscaled to the canvas with one high-quality
/// `CGContext` draw. Only the 64 x 64 grid is ever held in floating point.
public enum MeshGradientPainter {
    public static let sampleCount = 64
    /// The blur on the sample grid, in samples.
    public static let blurSigma = 1.0

    /// The 64 x 64 samples, row-major, three floats (0 to 1) per sample.
    public static func samples(for id: MeshID) -> [Double] {
        let grid = id.grid
        guard grid.count == 9 else { return [] }
        let count = sampleCount
        var result = [Double](repeating: 0, count: count * count * 3)
        // Interpolate each row of the grid along x at the 64 sample columns, then along y.
        var rows = [[Double]](repeating: [Double](repeating: 0, count: count * 3), count: 3)
        for row in 0..<3 {
            for column in 0..<count {
                let position = Double(column) / Double(count - 1) * 2
                for channel in 0..<3 {
                    let values = (0..<3).map { component(grid[row * 3 + $0], channel) }
                    rows[row][column * 3 + channel] = catmullRom(values, at: position)
                }
            }
        }
        for sampleRow in 0..<count {
            let position = Double(sampleRow) / Double(count - 1) * 2
            for index in 0..<(count * 3) {
                let values = (0..<3).map { rows[$0][index] }
                result[sampleRow * count * 3 + index] = min(max(catmullRom(values, at: position), 0), 1)
            }
        }
        return result
    }

    /// The blurred 64 x 64 grid as a 16-bit sRGB image, so the upscale has no 8-bit steps to smear.
    public static func gridImage(_ id: MeshID) -> CGImage? {
        var source = samples(for: id)
        guard !source.isEmpty else { return nil }
        let count = sampleCount
        blur(&source, width: count, height: count, sigma: blurSigma)
        var words = [UInt16](repeating: UInt16.max, count: count * count * 4)
        for index in 0..<(count * count) {
            for channel in 0..<3 {
                words[index * 4 + channel] = UInt16((min(max(source[index * 3 + channel], 0), 1) * 65535).rounded())
            }
        }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: count, height: count, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: count * 8,
            space: SyntheticImages.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// The mesh as an opaque sRGB bitmap of `width` x `height` pixels.
    public static func image(_ id: MeshID, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let grid = gridImage(id),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: SyntheticImages.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(grid, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Fills `rect` (bottom-left origin) of `context` with the mesh, rendered at the rect's pixel
    /// size and copied without resampling.
    public static func draw(_ id: MeshID, in context: CGContext, rect: CGRect) {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard let image = image(id, width: width, height: height) else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        context.restoreGState()
    }

    // MARK: Interpolation

    private static func component(_ color: RGBAColor, _ channel: Int) -> Double {
        switch channel {
        case 0: color.red
        case 1: color.green
        default: color.blue
        }
    }

    /// Catmull-Rom through three equally spaced values at `position` 0 to 2; the end tangents use
    /// the end values twice, so the curve passes through every grid colour.
    private static func catmullRom(_ values: [Double], at position: Double) -> Double {
        let segment = min(Int(position), 1)
        let t = position - Double(segment)
        let p1 = values[segment]
        let p2 = values[segment + 1]
        let p0 = segment > 0 ? values[segment - 1] : p1
        let p3 = segment + 2 < values.count ? values[segment + 2] : p2
        return cubic(p0, p1, p2, p3, t)
    }

    private static func cubic(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - 3 * p2 + p3 - p0) * t3)
    }

    // MARK: Blur

    private static func kernel(sigma: Double) -> [Double] {
        let radius = max(Int((sigma * 3).rounded(.up)), 1)
        var weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        return weights
    }

    /// Separable Gaussian blur with clamped edges, so the corner colours stay at the corners.
    private static func blur(_ pixels: inout [Double], width: Int, height: Int, sigma: Double) {
        let weights = kernel(sigma: sigma)
        let radius = weights.count / 2
        var middle = [Double](repeating: 0, count: pixels.count)
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<3 {
                    var sum = 0.0
                    for tap in 0..<weights.count {
                        let x = min(max(column + tap - radius, 0), width - 1)
                        sum += weights[tap] * pixels[(row * width + x) * 3 + channel]
                    }
                    middle[(row * width + column) * 3 + channel] = sum
                }
            }
        }
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<3 {
                    var sum = 0.0
                    for tap in 0..<weights.count {
                        let y = min(max(row + tap - radius, 0), height - 1)
                        sum += weights[tap] * middle[(y * width + column) * 3 + channel]
                    }
                    pixels[(row * width + column) * 3 + channel] = sum
                }
            }
        }
    }
}
