import Foundation

/// A width to height ratio for the Background canvas. Nil on a preset means free.
public struct AspectRatio: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Parses "16:9", "1.91:1" or "4x3".
    public init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "x" || $0 == "/" })
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
    }

    public var value: Double { width / height }

    /// The editor's Ratio menu after "Auto" (design 10.4).
    public static let presets: [(label: String, ratio: AspectRatio)] = [
        ("1:1", AspectRatio(width: 1, height: 1)),
        ("4:3", AspectRatio(width: 4, height: 3)),
        ("3:2", AspectRatio(width: 3, height: 2)),
        ("16:9", AspectRatio(width: 16, height: 9)),
        ("9:16", AspectRatio(width: 9, height: 16)),
        ("1.91:1", AspectRatio(width: 1.91, height: 1)),
    ]
}

/// What fills the canvas behind the card (design 10.1).
public enum BackgroundFill: Codable, Sendable, Hashable {
    case gradient(GradientID)
    case solid(RGBAColor)
    /// An image file, aspect-filled; `blur` 0 to 40 points. A missing file falls back to the default gradient.
    case image(path: String, blur: Double)
    /// A transparent canvas.
    case none

    public static let defaultGradient = GradientID.dusk

    private enum CodingKeys: String, CodingKey {
        case type, gradient, color, path, blur
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "solid":
            self = .solid(try container.decode(RGBAColor.self, forKey: .color))
        case "image":
            self = .image(
                path: try container.decode(String.self, forKey: .path),
                blur: try container.value(.blur, default: 0)
            )
        case "none":
            self = .none
        default:
            let name = try container.decodeIfPresent(String.self, forKey: .gradient) ?? ""
            self = .gradient(GradientID(name: name) ?? BackgroundFill.defaultGradient)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gradient(let id):
            try container.encode("gradient", forKey: .type)
            try container.encode(id, forKey: .gradient)
        case .solid(let color):
            try container.encode("solid", forKey: .type)
            try container.encode(color, forKey: .color)
        case .image(let path, let blur):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(blur, forKey: .blur)
        case .none:
            try container.encode("none", forKey: .type)
        }
    }

    /// Parses the `snapctl --background` forms: `gradient:<name>`, `solid:#RRGGBB`, `image:<path>`, `none`.
    public init?(parsing text: String) {
        if text == "none" {
            self = .none
        } else if text.hasPrefix("gradient:"), let id = GradientID(name: String(text.dropFirst(9))) {
            self = .gradient(id)
        } else if text.hasPrefix("solid:"), let color = RGBAColor(hex: String(text.dropFirst(6))) {
            self = .solid(color)
        } else if text.hasPrefix("image:"), text.count > 6 {
            self = .image(path: String(text.dropFirst(6)), blur: 0)
        } else {
            return nil
        }
    }
}

/// A Background beautifier preset (design 10.1). The defaults are the user's CleanShot values
/// (padding 21, inset 21, corner radius 0.12, shadow 32, centred, auto-balance) with the Dusk gradient.
public struct BackgroundPreset: Codable, Sendable, Hashable, Identifiable {
    public static let paddingRange = 0.0...120.0
    public static let insetRange = 0.0...80.0
    public static let shadowRange = 0.0...100.0
    public static let blurRange = 0.0...40.0

    public static let factoryID = "default"

    public var id: String
    public var name: String
    public var background: BackgroundFill
    /// Points, 0 to 120.
    public var padding: Double
    /// Points, 0 to 80.
    public var inset: Double
    /// A fraction 0 to 1, read as a slider position up to 100 pt (design 10.2 step 6).
    public var cornerRadius: Double
    /// 0 to 100.
    public var shadow: Double
    public var ratio: AspectRatio?
    /// Row-major 3x3: 0 top-left, 4 centre, 8 bottom-right. Only matters with a ratio.
    public var alignment: Int
    public var autoBalance: Bool

    public init(
        id: String = BackgroundPreset.factoryID,
        name: String = "Default",
        background: BackgroundFill = .gradient(BackgroundFill.defaultGradient),
        padding: Double = 21,
        inset: Double = 21,
        cornerRadius: Double = 0.12,
        shadow: Double = 32,
        ratio: AspectRatio? = nil,
        alignment: Int = 4,
        autoBalance: Bool = true
    ) {
        self.id = id
        self.name = name
        self.background = background
        self.padding = padding
        self.inset = inset
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.ratio = ratio
        self.alignment = alignment
        self.autoBalance = autoBalance
    }

    /// The first-run default.
    public static let factoryDefault = BackgroundPreset()

    private enum CodingKeys: String, CodingKey {
        case id, name, background, padding, inset, cornerRadius, shadow, ratio, alignment, autoBalance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BackgroundPreset()
        self.init(
            id: try container.value(.id, default: defaults.id),
            name: try container.value(.name, default: defaults.name),
            background: try container.value(.background, default: defaults.background),
            padding: try container.value(.padding, default: defaults.padding),
            inset: try container.value(.inset, default: defaults.inset),
            cornerRadius: try container.value(.cornerRadius, default: defaults.cornerRadius),
            shadow: try container.value(.shadow, default: defaults.shadow),
            ratio: try container.decodeIfPresent(AspectRatio.self, forKey: .ratio),
            alignment: try container.value(.alignment, default: defaults.alignment),
            autoBalance: try container.value(.autoBalance, default: defaults.autoBalance)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(background, forKey: .background)
        try container.encode(padding, forKey: .padding)
        try container.encode(inset, forKey: .inset)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(shadow, forKey: .shadow)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(alignment, forKey: .alignment)
        try container.encode(autoBalance, forKey: .autoBalance)
    }

    /// The preset with every value inside its documented range and a usable ratio.
    public func clamped() -> BackgroundPreset {
        var copy = self
        copy.padding = Self.clamp(padding, to: Self.paddingRange)
        copy.inset = Self.clamp(inset, to: Self.insetRange)
        copy.cornerRadius = Self.clamp(cornerRadius, to: 0...1)
        copy.shadow = Self.clamp(shadow, to: Self.shadowRange)
        copy.alignment = min(max(alignment, 0), 8)
        if let ratio, !(ratio.width > 0 && ratio.height > 0 && ratio.width.isFinite && ratio.height.isFinite) {
            copy.ratio = nil
        }
        if case .image(let path, let blur) = background {
            copy.background = .image(path: path, blur: Self.clamp(blur, to: Self.blurRange))
        }
        return copy
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}
