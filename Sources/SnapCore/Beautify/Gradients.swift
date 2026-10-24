import CoreGraphics
import Foundation

/// An sRGB colour with straight alpha, components 0 to 1. Codes as "#RRGGBB" or "#RRGGBBAA".
public struct RGBAColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses "#RRGGBB", "RRGGBB", "#RRGGBBAA" or "RRGGBBAA".
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let bits = text.count == 8 ? value : value << 8 | 0xFF
        self.init(
            red: Double((bits >> 24) & 0xFF) / 255,
            green: Double((bits >> 16) & 0xFF) / 255,
            blue: Double((bits >> 8) & 0xFF) / 255,
            alpha: Double(bits & 0xFF) / 255
        )
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    private static func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }

    public var hex: String {
        let base = String(
            format: "#%02X%02X%02X", RGBAColor.byte(red), RGBAColor.byte(green), RGBAColor.byte(blue)
        )
        return alpha >= 1 ? base : base + String(format: "%02X", RGBAColor.byte(alpha))
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = RGBAColor(hex: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a hex colour: \(text)")
            )
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The 12 named gradients of design 10.3, linear at 135 degrees.
public enum GradientID: String, Codable, Sendable, CaseIterable, Hashable {
    case dusk, citrus, lagoon, mint, rose, ember, slate, aurora, sand, ocean, orchid, fog

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Case-insensitive lookup by name.
    public init?(name: String) {
        self.init(rawValue: name.lowercased())
    }

    public var stops: [RGBAColor] {
        let hexes: [String]
        switch self {
        case .dusk: hexes = ["#5B6CFF", "#B65BFF"]
        case .citrus: hexes = ["#FFB347", "#FF5E62"]
        case .lagoon: hexes = ["#2BC0E4", "#3A7BD5"]
        case .mint: hexes = ["#6EE7B7", "#3B82F6"]
        case .rose: hexes = ["#FF9A9E", "#FAD0C4"]
        case .ember: hexes = ["#F12711", "#F5AF19"]
        case .slate: hexes = ["#334155", "#0F172A"]
        case .aurora: hexes = ["#00C9A7", "#845EC2", "#FF6F91"]
        case .sand: hexes = ["#F5E6CC", "#E3C9A0"]
        case .ocean: hexes = ["#0F2027", "#2C5364"]
        case .orchid: hexes = ["#C471F5", "#FA71CD"]
        case .fog: hexes = ["#E5E7EB", "#9CA3AF"]
        }
        return hexes.compactMap { RGBAColor(hex: $0) }
    }
}

/// The 10 solid swatches of design 10.3. A colour well adds any other colour.
public struct SolidSwatch: Sendable, Hashable, Identifiable {
    public let name: String
    public let color: RGBAColor
    public var id: String { color.hex }

    public static let all: [SolidSwatch] = [
        ("White", "#FFFFFF"), ("Snow", "#F5F5F7"), ("Light Gray", "#D1D1D6"), ("Graphite", "#1C1C1E"),
        ("Black", "#000000"), ("Blue", "#0A84FF"), ("Green", "#30D158"), ("Orange", "#FF9F0A"),
        ("Pink", "#FF375F"), ("Purple", "#BF5AF2"),
    ].compactMap { name, hex in RGBAColor(hex: hex).map { SolidSwatch(name: name, color: $0) } }
}

/// Core Graphics drawing of the named gradients.
public enum GradientPainter {
    /// CSS angle of every named gradient: towards the bottom right.
    public static let angleDegrees = 135.0

    /// Fills `rect` (bottom-left origin, as in an unflipped CGContext) with `gradient`. Like the CSS
    /// `linear-gradient(135deg, ...)`, the first stop sits at the top-left corner and the last at the
    /// bottom-right corner of any rectangle.
    public static func draw(_ gradient: GradientID, in context: CGContext, rect: CGRect) {
        draw(stops: gradient.stops, in: context, rect: rect)
    }

    public static func draw(stops: [RGBAColor], in context: CGContext, rect: CGRect) {
        guard let first = stops.first else { return }
        guard stops.count > 1 else {
            context.setFillColor(first.cgColor)
            context.fill(rect)
            return
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = stops.map(\.cgColor) as CFArray
        let locations = stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        let radians = angleDegrees * .pi / 180
        // CSS direction in a top-left space, flipped to the context's bottom-left space.
        let direction = CGPoint(x: sin(radians), y: -cos(radians))
        let lineLength = abs(rect.width * sin(radians)) + abs(rect.height * cos(radians))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: center.x - direction.x * lineLength / 2, y: center.y + direction.y * lineLength / 2)
        let end = CGPoint(x: center.x + direction.x * lineLength / 2, y: center.y - direction.y * lineLength / 2)
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
}
