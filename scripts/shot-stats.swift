// Usage: shot-stats <png> [x y w h]
// Prints one line for the whole image, or for the pixel rectangle x y w h (origin top-left):
//   <width> <height> <mean> <stddev> <min> <max> <red> <green> <blue> <alpha>
// width and height are the whole image's pixel size. mean, stddev, min and max are luminance
// (Rec. 709, 0 to 255) of the region; red, green, blue and alpha are the region's mean channel
// values (0 to 255, straight alpha). Pixels are read in sRGB.
// Used by accept.sh for the beautify geometry checks (corner, shadow band, margins) and to check
// that background screenshots are the right size, not blank and differ between light and dark.
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 2 || args.count == 6 else {
    FileHandle.standardError.write(Data("usage: shot-stats <png> [x y w h]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("shot-stats: cannot read \(args[1])\n".utf8))
    exit(1)
}
var region = CGRect(x: 0, y: 0, width: image.width, height: image.height)
if args.count == 6 {
    let numbers = args[2...5].compactMap { Double($0) }
    guard numbers.count == 4 else {
        FileHandle.standardError.write(Data("shot-stats: rectangle must be four numbers\n".utf8))
        exit(2)
    }
    region = region.intersection(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).integral)
}
guard !region.isEmpty, let cropped = image.cropping(to: region) else {
    FileHandle.standardError.write(Data("shot-stats: empty region\n".utf8))
    exit(1)
}
let width = cropped.width
let height = cropped.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.setBlendMode(.copy)
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else {
    FileHandle.standardError.write(Data("shot-stats: cannot read pixels\n".utf8))
    exit(1)
}
var sum = 0.0
var sumSquares = 0.0
var low = 255.0
var high = 0.0
var channels = [0.0, 0.0, 0.0, 0.0]
let count = Double(width * height)
for index in 0..<(width * height) {
    let base = index * 4
    let alpha = Double(pixels[base + 3])
    // Un-premultiply so a half-transparent pixel reports its own color.
    let unpremultiply = alpha > 0 ? 255 / alpha : 0
    let red = min(Double(pixels[base]) * unpremultiply, 255)
    let green = min(Double(pixels[base + 1]) * unpremultiply, 255)
    let blue = min(Double(pixels[base + 2]) * unpremultiply, 255)
    // Luminance is of the premultiplied pixel, as composited on black, like Reel's checks.
    let luma = 0.2126 * Double(pixels[base]) + 0.7152 * Double(pixels[base + 1]) + 0.0722 * Double(pixels[base + 2])
    sum += luma
    sumSquares += luma * luma
    low = min(low, luma)
    high = max(high, luma)
    channels[0] += red
    channels[1] += green
    channels[2] += blue
    channels[3] += alpha
}
let mean = sum / count
let deviation = (max(sumSquares / count - mean * mean, 0)).squareRoot()
print(
    "\(image.width) \(image.height) "
        + String(format: "%.3f %.3f %.1f %.1f ", mean, deviation, low, high)
        + String(format: "%.1f %.1f %.1f %.1f", channels[0] / count, channels[1] / count, channels[2] / count, channels[3] / count)
)
