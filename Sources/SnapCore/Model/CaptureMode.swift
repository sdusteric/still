import Foundation

/// The three M1 capture modes (Cmd+Shift+4, Cmd+Shift+5 and Cmd+Shift+3 by default).
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
}
