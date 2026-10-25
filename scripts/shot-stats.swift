// Usage: shot-stats <png> [x y w h]
//        shot-stats --compare <a.png> <b.png> [--grid 32] [--regions <tsv> --scenario <name>] [--scale 2]
//
//        shot-stats --cells <png> x y w h
//
// Single image: prints one line for the whole image, or for the pixel rectangle x y w h (origin
// top-left):
//   <width> <height> <mean> <stddev> <min> <max> <red> <green> <blue> <alpha> <maxRed> <maxGreen> <maxBlue>
// width and height are the whole image's pixel size. mean, stddev, min and max are luminance
// (Rec. 709, 0 to 255) of the region; red, green, blue and alpha are the region's mean channel
// values and maxRed, maxGreen and maxBlue the largest (0 to 255, straight alpha). Pixels are read
// in sRGB.
//
// --cells (AC-M2-6, pixelate): prints JSON with the shortest run of identical pixels along the
// rows and along the columns of the rectangle, leaving out the first and last run of each line
// (the region's edge may cut a cell), and how many lines had an interior run.
// Used by accept.sh for the beautify geometry checks (corner, shadow band, margins) and to check
// that background screenshots are the right size, not blank and differ between light and dark.
//
// --compare (design 20.14, AC-M2-10): prints one JSON object comparing a shot with its mockup.
// Both images must have the same pixel size ("sizeMatch"). The image is cut into a grid of
// square cells, `--grid` columns wide (default 32) and as many rows as fit; the mean luminance of
// each cell is taken in both images, and "grid" reports the mean and the 90th percentile of the
// absolute differences (0 to 255). With --regions, every row of the TSV whose first column is
// the scenario gives a named region in points (x y w h, top-left origin), multiplied by --scale
// (default 2) to pixels; "regions" lists each one's mean luminance in both images, the signed
// difference (a minus b) and its absolute value. Exit 0 when the JSON was printed, also when the
// sizes differ (then "grid" and "regions" are null); 1 when an image or the TSV cannot be read.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("shot-stats: \(message)\n".utf8))
    exit(status)
}

/// RGBA pixels, premultiplied, 8 bits per channel, in sRGB, top row first.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        bytes = buffer
    }

    /// Luminance of the premultiplied pixel, as composited on black, like Reel's checks.
    func luma(_ x: Int, _ y: Int) -> Double {
        let base = (y * width + x) * 4
        return 0.2126 * Double(bytes[base]) + 0.7152 * Double(bytes[base + 1]) + 0.0722 * Double(bytes[base + 2])
    }

    /// Mean luminance of the pixel rectangle [x0, x1) x [y0, y1), clipped to the image.
    func meanLuma(x0: Int, y0: Int, x1: Int, y1: Int) -> Double? {
        let left = max(x0, 0)
        let top = max(y0, 0)
        let right = min(x1, width)
        let bottom = min(y1, height)
        guard right > left, bottom > top else { return nil }
        var sum = 0.0
        for y in top..<bottom {
            for x in left..<right { sum += luma(x, y) }
        }
        return sum / Double((right - left) * (bottom - top))
    }
}

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("cannot read \(path)")
    }
    return image
}

// MARK: Single image

func singleImage(_ args: [String]) -> Never {
    let image = loadImage(args[1])
    var region = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    if args.count == 6 {
        let numbers = args[2...5].compactMap { Double($0) }
        guard numbers.count == 4 else { fail("rectangle must be four numbers", status: 2) }
        region = region.intersection(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).integral)
    }
    guard !region.isEmpty, let cropped = image.cropping(to: region) else { fail("empty region") }
    guard let pixels = Pixels(image: cropped) else { fail("cannot read pixels") }
    var sum = 0.0
    var sumSquares = 0.0
    var low = 255.0
    var high = 0.0
    var channels = [0.0, 0.0, 0.0, 0.0]
    var largest = [0.0, 0.0, 0.0]
    let count = Double(pixels.width * pixels.height)
    for index in 0..<(pixels.width * pixels.height) {
        let base = index * 4
        let alpha = Double(pixels.bytes[base + 3])
        // Un-premultiply so a half-transparent pixel reports its own color.
        let unpremultiply = alpha > 0 ? 255 / alpha : 0
        let red = min(Double(pixels.bytes[base]) * unpremultiply, 255)
        let green = min(Double(pixels.bytes[base + 1]) * unpremultiply, 255)
        let blue = min(Double(pixels.bytes[base + 2]) * unpremultiply, 255)
        channels[0] += red
        channels[1] += green
        channels[2] += blue
        channels[3] += alpha
        largest = [max(largest[0], red), max(largest[1], green), max(largest[2], blue)]
        let luma = pixels.luma(index % pixels.width, index / pixels.width)
        sum += luma
        sumSquares += luma * luma
        low = min(low, luma)
        high = max(high, luma)
    }
    let mean = sum / count
    let deviation = (max(sumSquares / count - mean * mean, 0)).squareRoot()
    print(
        "\(image.width) \(image.height) "
            + String(format: "%.3f %.3f %.1f %.1f ", mean, deviation, low, high)
            + String(format: "%.1f %.1f %.1f %.1f ", channels[0] / count, channels[1] / count, channels[2] / count, channels[3] / count)
            + String(format: "%.1f %.1f %.1f", largest[0], largest[1], largest[2])
    )
    exit(0)
}

// MARK: Cells

func cells(_ args: [String]) -> Never {
    guard args.count == 7 else { fail("usage: shot-stats --cells <png> x y w h", status: 2) }
    let image = loadImage(args[2])
    let numbers = args[3...6].compactMap { Int($0) }
    guard numbers.count == 4 else { fail("rectangle must be four whole numbers", status: 2) }
    guard let pixels = Pixels(image: image) else { fail("cannot read pixels") }
    let x0 = max(numbers[0], 0), y0 = max(numbers[1], 0)
    let x1 = min(numbers[0] + numbers[2], pixels.width), y1 = min(numbers[1] + numbers[3], pixels.height)
    guard x1 > x0, y1 > y0 else { fail("empty region") }
    func same(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        let first = (a.1 * pixels.width + a.0) * 4
        let second = (b.1 * pixels.width + b.0) * 4
        return (0..<4).allSatisfy { pixels.bytes[first + $0] == pixels.bytes[second + $0] }
    }
    /// The shortest interior run of one line, nil when the line has fewer than three runs.
    func shortestInterior(_ points: [(Int, Int)]) -> Int? {
        var runs: [Int] = []
        var length = 1
        for index in 1..<points.count {
            if same(points[index - 1], points[index]) {
                length += 1
            } else {
                runs.append(length)
                length = 1
            }
        }
        runs.append(length)
        guard runs.count >= 3 else { return nil }
        return runs.dropFirst().dropLast().min()
    }
    var rowRuns: [Int] = []
    for y in y0..<y1 {
        if let run = shortestInterior((x0..<x1).map { ($0, y) }) { rowRuns.append(run) }
    }
    var columnRuns: [Int] = []
    for x in x0..<x1 {
        if let run = shortestInterior((y0..<y1).map { (x, $0) }) { columnRuns.append(run) }
    }
    let report: [String: Any] = [
        "region": [x0, y0, x1 - x0, y1 - y0],
        "rowsWithCells": rowRuns.count,
        "columnsWithCells": columnRuns.count,
        "minRunX": rowRuns.min().map { $0 as Any } ?? NSNull(),
        "minRunY": columnRuns.min().map { $0 as Any } ?? NSNull(),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { fail("cannot encode the report") }
    print(text)
    exit(0)
}

// MARK: Compare

struct Region {
    var name: String
    /// Points, top-left origin.
    var rect: CGRect
}

/// Rows `scenario<TAB>name<TAB>x<TAB>y<TAB>w<TAB>h`; lines starting with # are comments.
func readRegions(_ path: String, scenario: String) -> [Region] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    var regions: [Region] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        let fields = trimmed.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 6, fields[0] == scenario else { continue }
        let numbers = fields[2...5].compactMap { Double($0) }
        guard numbers.count == 4 else { fail("bad region row: \(trimmed)") }
        regions.append(Region(name: fields[1], rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])))
    }
    return regions
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    // Nearest rank.
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank - 1, 0), sorted.count - 1)]
}

func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

func compare(_ args: [String]) -> Never {
    var positional: [String] = []
    var options: [String: String] = [:]
    var index = 2
    while index < args.count {
        let arg = args[index]
        if ["--grid", "--regions", "--scenario", "--scale"].contains(arg) {
            guard index + 1 < args.count else { fail("\(arg) needs a value", status: 2) }
            options[arg] = args[index + 1]
            index += 2
        } else if arg.hasPrefix("--") {
            fail("unknown option \(arg)", status: 2)
        } else {
            positional.append(arg)
            index += 1
        }
    }
    guard positional.count == 2 else { fail("--compare needs two PNG paths", status: 2) }
    let columns = Int(options["--grid"] ?? "32") ?? 0
    guard columns > 0 else { fail("--grid must be a positive whole number", status: 2) }
    let scale = Double(options["--scale"] ?? "2") ?? 0
    guard scale > 0 else { fail("--scale must be positive", status: 2) }
    if (options["--regions"] == nil) != (options["--scenario"] == nil) {
        fail("--regions and --scenario go together", status: 2)
    }

    let imageA = loadImage(positional[0])
    let imageB = loadImage(positional[1])
    guard let a = Pixels(image: imageA), let b = Pixels(image: imageB) else { fail("cannot read pixels") }
    var report: [String: Any] = [
        "a": positional[0],
        "b": positional[1],
        "sizeA": [a.width, a.height],
        "sizeB": [b.width, b.height],
    ]
    let sizeMatch = a.width == b.width && a.height == b.height
    report["sizeMatch"] = sizeMatch

    if sizeMatch {
        // Square cells: `columns` across, as many rows as the height holds (at least one).
        let cell = Double(a.width) / Double(columns)
        let rows = max(Int((Double(a.height) / cell).rounded()), 1)
        var differences: [Double] = []
        for row in 0..<rows {
            let y0 = Int((Double(row) * Double(a.height) / Double(rows)).rounded(.down))
            let y1 = Int((Double(row + 1) * Double(a.height) / Double(rows)).rounded(.down))
            for column in 0..<columns {
                let x0 = Int((Double(column) * cell).rounded(.down))
                let x1 = Int((Double(column + 1) * cell).rounded(.down))
                guard let meanA = a.meanLuma(x0: x0, y0: y0, x1: x1, y1: y1),
                      let meanB = b.meanLuma(x0: x0, y0: y0, x1: x1, y1: y1) else { continue }
                differences.append(abs(meanA - meanB))
            }
        }
        let mean = differences.isEmpty ? 0 : differences.reduce(0, +) / Double(differences.count)
        report["grid"] = [
            "columns": columns,
            "rows": rows,
            "cellPixels": rounded(cell),
            "cells": differences.count,
            "meanAbsDiff": rounded(mean),
            "p90AbsDiff": rounded(percentile(differences, 0.9)),
            "maxAbsDiff": rounded(differences.max() ?? 0),
        ]
    } else {
        report["grid"] = NSNull()
    }

    if let path = options["--regions"], let scenario = options["--scenario"] {
        report["scenario"] = scenario
        if sizeMatch {
            let regions = readRegions(path, scenario: scenario)
            report["regions"] = regions.map { region -> [String: Any] in
                let pixels = CGRect(
                    x: region.rect.minX * scale, y: region.rect.minY * scale,
                    width: region.rect.width * scale, height: region.rect.height * scale
                ).integral
                let x0 = Int(pixels.minX), y0 = Int(pixels.minY), x1 = Int(pixels.maxX), y1 = Int(pixels.maxY)
                var entry: [String: Any] = [
                    "name": region.name,
                    "points": [region.rect.minX, region.rect.minY, region.rect.width, region.rect.height],
                    "pixels": [x0, y0, x1 - x0, y1 - y0],
                ]
                if let meanA = a.meanLuma(x0: x0, y0: y0, x1: x1, y1: y1),
                   let meanB = b.meanLuma(x0: x0, y0: y0, x1: x1, y1: y1) {
                    entry["meanA"] = rounded(meanA)
                    entry["meanB"] = rounded(meanB)
                    entry["diff"] = rounded(meanA - meanB)
                    entry["absDiff"] = rounded(abs(meanA - meanB))
                } else {
                    entry["meanA"] = NSNull()
                    entry["meanB"] = NSNull()
                    entry["diff"] = NSNull()
                    entry["absDiff"] = NSNull()
                }
                return entry
            }
        } else {
            report["regions"] = NSNull()
        }
    }

    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { fail("cannot encode the report") }
    print(text)
    exit(0)
}

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--compare" {
    compare(args)
}
if args.count >= 2, args[1] == "--cells" {
    cells(args)
}
guard args.count == 2 || args.count == 6 else {
    FileHandle.standardError.write(Data(
        ("usage: shot-stats <png> [x y w h]\n"
            + "       shot-stats --compare <a.png> <b.png> [--grid 32] [--regions <tsv> --scenario <name>] [--scale 2]\n"
            + "       shot-stats --cells <png> x y w h\n").utf8
    ))
    exit(2)
}
singleImage(args)
