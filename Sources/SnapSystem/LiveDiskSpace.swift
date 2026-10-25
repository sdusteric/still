import Foundation
import SnapCore

/// Free space on the volume holding SNAP_HOME (design 20.6, D68), from
/// `volumeAvailableCapacityForImportantUsage`. The recording controller passes the history folder.
public struct LiveDiskSpace: DiskSpaceProbe {
    public struct UnavailableError: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "no free space value for the volume holding \(path)" }
    }

    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        let target = LiveDiskSpace.existingAncestor(of: url)
        let values = try target.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        guard let bytes = LiveDiskSpace.choose(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            plain: values.volumeAvailableCapacity
        ) else { throw UnavailableError(path: target.path) }
        return bytes
    }

    /// The nearest folder that exists, so a history folder not created yet still reads its volume.
    public static func existingAncestor(of url: URL, fileManager: FileManager = .default) -> URL {
        var current = url.standardizedFileURL
        while !fileManager.fileExists(atPath: current.path), current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    /// Prefers the important-usage value (it counts purgeable space); some volumes report 0 or
    /// nothing for it, and then the plain available capacity is used.
    public static func choose(importantUsage: Int64?, plain: Int?) -> Int64? {
        if let importantUsage, importantUsage > 0 { return importantUsage }
        if let plain { return Int64(plain) }
        return importantUsage
    }
}
