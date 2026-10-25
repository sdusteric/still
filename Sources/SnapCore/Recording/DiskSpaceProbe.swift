import Foundation

/// Free space on the volume that holds a folder (design 20.6, D68). Live: `LiveDiskSpace` in
/// SnapSystem. Tests and `snapctl record` use `FakeDiskSpace`.
public protocol DiskSpaceProbe: Sendable {
    /// Bytes available for important usage on the volume holding `url`.
    func availableBytes(at url: URL) throws -> Int64
}

/// The thresholds of D68.
public enum DiskSpaceLimits {
    /// A recording refuses to start below 2 GB free.
    public static let minimumToStart: Int64 = 2 * 1024 * 1024 * 1024
    /// A running recording stops cleanly below 500 MB free.
    public static let minimumWhileRecording: Int64 = 500 * 1024 * 1024
    /// How often a running recording checks.
    public static let pollInterval: TimeInterval = 5
}
