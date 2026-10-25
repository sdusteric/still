import Foundation

/// Microphone access as Snap sees it (design 20.7).
public enum MicrophoneAccess: String, Sendable, Hashable, Codable, CaseIterable {
    case authorized
    case denied
    case restricted
    case notDetermined

    public var isAuthorized: Bool { self == .authorized }
}

/// The microphone permission probe and request (design 20.7, D65). Live:
/// `MicrophoneAuthorization` in SnapSystem over `AVCaptureDevice`. `requestAccess` is called at
/// most once per install and only from a user action that turns the microphone on, never from
/// a recording start: the controller reads `status()` only.
public protocol MicrophoneAuthorizing: Sendable {
    func status() -> MicrophoneAccess
    /// Shows the system prompt when the status is not determined; returns whether access was granted.
    func requestAccess() async -> Bool
}
