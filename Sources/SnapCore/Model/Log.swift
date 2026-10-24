import Foundation
import Synchronization

/// `SNAP_HOME/logs/snap.log`: events, errors and latency lines. When the file passes
/// `maxBytes` (5 MB) it is renamed to `snap.log.1`, replacing the previous one. Never sent anywhere.
public final class Log: Sendable {
    public static let defaultMaxBytes = 5 * 1024 * 1024

    public enum Level: String, Sendable {
        case info, warning, error
    }

    public let fileURL: URL
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    /// Also echo to stderr (snapctl and debugging).
    private let echo: Bool
    private let lock = Mutex(())

    public init(
        fileURL: URL,
        maxBytes: Int = Log.defaultMaxBytes,
        echo: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.maxBytes = max(maxBytes, 1024)
        self.echo = echo
        self.now = now
    }

    public convenience init(paths: SnapPaths, echo: Bool = false) {
        self.init(fileURL: paths.logFile, echo: echo)
    }

    /// The rotated file, `snap.log.1`.
    public var rotatedURL: URL {
        fileURL.deletingLastPathComponent().appending(path: fileURL.lastPathComponent + ".1", directoryHint: .notDirectory)
    }

    public func info(_ message: String) { write(message, level: .info) }
    public func warning(_ message: String) { write(message, level: .warning) }
    public func error(_ message: String) { write(message, level: .error) }

    /// Appends one line. Logging must never break a capture, so failures go to stderr only.
    public func write(_ message: String, level: Level = .info) {
        let line = "\(Log.timestamp(now())) \(level.rawValue) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        lock.withLock { _ in
            do {
                try append(Data(line.utf8))
            } catch {
                FileHandle.standardError.write(Data("snap log write failed: \(error)\n".utf8))
            }
        }
    }

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attributes = try? manager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int, size + data.count > maxBytes {
            let rotated = rotatedURL
            if manager.fileExists(atPath: rotated.path(percentEncoded: false)) {
                try manager.removeItem(at: rotated)
            }
            try manager.moveItem(at: fileURL, to: rotated)
        }
        if !manager.fileExists(atPath: path) {
            guard manager.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            do { try handle.close() } catch { FileHandle.standardError.write(Data("snap log close failed\n".utf8)) }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
    }
}
