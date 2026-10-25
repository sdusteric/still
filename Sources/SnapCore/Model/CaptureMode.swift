import Foundation

/// The three capture targets: area, window and fullscreen. The all-in-one HUD (design 20.5) uses
/// the same three as its targets for screenshots and recordings.
public enum CaptureMode: String, Sendable, Hashable, Codable, CaseIterable {
    case area
    case window
    case fullscreen

    public var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        }
    }

    /// The HUD's target button label.
    public var targetTitle: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .fullscreen: "Fullscreen"
        }
    }
}

/// What a history item holds (design 20.4): a screenshot PNG or a screen recording mp4.
public enum CaptureKind: String, Sendable, Hashable, Codable, CaseIterable {
    case image
    case video
}

/// Lifecycle of a history item (design 20.4). Screenshots are always `complete`. A recording is
/// `recording` from before its first frame until it finishes, and `interrupted` when Snap found it
/// still recording at launch or the finished file did not probe as playable.
public enum CaptureState: String, Sendable, Hashable, Codable, CaseIterable {
    case complete
    case recording
    case interrupted
}

/// An audio source a recording carries (design 20.6).
public enum AudioSource: String, Sendable, Hashable, Codable, CaseIterable {
    case system
    case microphone
}

/// The HUD's mode switch (design 20.5): Screenshot or Record.
public enum HUDMode: String, Sendable, Hashable, Codable, CaseIterable {
    case screenshot
    case record

    public var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .record: "Record"
        }
    }

    public var toggled: HUDMode { self == .screenshot ? .record : .screenshot }
}

/// A size in whole pixels. `item.json` stores it as `[w, h]`.
public struct PixelSize: Sendable, Hashable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        width = try container.decode(Int.self)
        height = try container.decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(width)
        try container.encode(height)
    }

    public var description: String { "\(width)x\(height)" }
}
