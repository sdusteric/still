// swift make-icon.swift out.png : 1024x1024 app icon (design 17.8). A rounded square with a
// blue-to-violet gradient (#3B4CE0 to #8A4DE8 at 145 degrees) and a white viewfinder: four
// corner brackets with round caps, drawn on the mockup's 24 unit grid at stroke 1.9.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("make-icon: cannot create bitmap\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255, alpha: 1
    )
}

// Apple icon grid: an 824 point shape centred in the 1024 canvas. The mockup draws it at 64 pt
// with radius 14.4, which is the same 22.5% ratio.
let side = 824.0
let shapeRect = NSRect(x: 100, y: 100, width: side, height: side)
let shape = NSBezierPath(roundedRect: shapeRect, xRadius: side * 0.225, yRadius: side * 0.225)
// CSS 145deg points down and to the right; NSGradient angles run counterclockwise from +x with
// y up, so the same direction is -55 degrees.
NSGradient(starting: srgb(0x3B4CE0), ending: srgb(0x8A4DE8))?.draw(in: shape, angle: -55)

// The viewfinder is 35/64 of the icon side, on a 24 unit grid (y down in the mockup's SVG).
let glyph = side * 35 / 64
let unit = glyph / 24
let origin = NSPoint(x: shapeRect.midX - glyph / 2, y: shapeRect.midY + glyph / 2)
func point(_ x: Double, _ y: Double) -> NSPoint {
    NSPoint(x: origin.x + x * unit, y: origin.y - y * unit)
}

// Each bracket: a short line, a quarter arc of radius 3, another short line.
let brackets: [(start: (Double, Double), corner: (Double, Double), end: (Double, Double))] = [
    ((3, 8), (3, 3), (8, 3)),
    ((16, 3), (21, 3), (21, 8)),
    ((21, 16), (21, 21), (16, 21)),
    ((8, 21), (3, 21), (3, 16)),
]
let path = NSBezierPath()
for bracket in brackets {
    path.move(to: point(bracket.start.0, bracket.start.1))
    path.appendArc(
        from: point(bracket.corner.0, bracket.corner.1),
        to: point(bracket.end.0, bracket.end.1),
        radius: 3 * unit
    )
    path.line(to: point(bracket.end.0, bracket.end.1))
}
path.lineWidth = 1.9 * unit
path.lineCapStyle = .round
path.lineJoinStyle = .round
NSColor.white.setStroke()
path.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("make-icon: PNG encoding failed\n".utf8))
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: out))
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
