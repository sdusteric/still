import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One capture for the Shelf status file: when it was taken and the image a preview is made from.
/// The image location never reaches the file.
public struct ShelfCapture: Sendable, Hashable {
    public var takenAt: Date
    public var imageURL: URL

    public init(takenAt: Date, imageURL: URL) {
        self.takenAt = takenAt
        self.imageURL = imageURL
    }
}

/// Whether Snap adds screenshots to Shelf search, and how many wait for OCR (Recall design 7.8).
public struct RecallStatus: Sendable, Equatable {
    public var enabled: Bool
    public var pending: Int

    public init(enabled: Bool, pending: Int) {
        self.enabled = enabled
        self.pending = pending
    }
}

/// The JSON Shelf reads (Shelf design section 14): common fields plus `captures`.
struct ShelfStatusDocument: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var takenAt: Date
        var preview: String?

        enum CodingKeys: String, CodingKey {
            case takenAt = "taken_at"
            case preview
        }
    }

    var schema = 1
    var app = "snap"
    var appVersion: String
    var updatedAt: Date
    var captures: [Entry]
    var recall: String?
    /// Left out when nothing waits.
    var recallPending: Int?

    enum CodingKeys: String, CodingKey {
        case schema, app, captures, recall
        case appVersion = "app_version"
        case updatedAt = "updated_at"
        case recallPending = "recall_pending"
    }
}

/// Writes `snap.json` and, only when previews are on, `snap/1.jpg` to `snap/3.jpg` into the Shelf
/// status folder. Files are written to a temp name in the same folder, fsynced, then renamed.
public struct ShelfStatusWriter: Sendable {
    public static let maxCaptures = 3
    public static let maxFileBytes = 16 * 1024
    public static let maxPreviewWidth = 240
    public static let maxPreviewBytes = 30 * 1024
    public static let fileName = "snap.json"
    public static let previewFolderName = "snap"

    public let directory: URL
    public let appVersion: String

    public init(directory: URL, appVersion: String) {
        self.directory = directory
        self.appVersion = appVersion
    }

    public var statusFile: URL { directory.appending(path: Self.fileName, directoryHint: .notDirectory) }
    public var previewDirectory: URL { directory.appending(path: Self.previewFolderName, directoryHint: .isDirectory) }

    public func previewName(at index: Int) -> String { "\(index + 1).jpg" }

    /// Writes the status for the newest-first `captures` (extra ones are dropped). With
    /// `showPreviews` off no preview is written and any left over is deleted.
    public func write(captures: [ShelfCapture], showPreviews: Bool, recall: RecallStatus? = nil, now: Date = Date()) throws {
        let kept = Array(captures.prefix(Self.maxCaptures))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var names: [String?] = Array(repeating: nil, count: kept.count)
        if showPreviews {
            try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
            for (index, capture) in kept.enumerated() {
                guard let data = Self.previewData(for: capture.imageURL) else { continue }
                let name = previewName(at: index)
                try Self.writeAtomically(data, to: previewDirectory.appending(path: name, directoryHint: .notDirectory))
                names[index] = name
            }
        }
        removePreviews(keeping: Set(names.compactMap { $0 }))

        let document = ShelfStatusDocument(
            appVersion: appVersion,
            updatedAt: now,
            captures: zip(kept, names).map { .init(takenAt: $0.takenAt, preview: $1) },
            recall: recall.map { $0.enabled ? "on" : "off" },
            recallPending: recall.flatMap { $0.enabled && $0.pending > 0 ? $0.pending : nil }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard data.count <= Self.maxFileBytes else { throw POSIXError(.EFBIG) }
        try Self.writeAtomically(data, to: statusFile)
    }

    /// Deletes the preview files except `keeping`, and the folder when nothing is left.
    func removePreviews(keeping: Set<String>) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: previewDirectory.path(percentEncoded: false)) else { return }
        for name in names where !keeping.contains(name) && (name.hasSuffix(".jpg") || name.hasSuffix(".tmp")) {
            try? manager.removeItem(at: previewDirectory.appending(path: name, directoryHint: .notDirectory))
        }
        if keeping.isEmpty, (try? manager.contentsOfDirectory(atPath: previewDirectory.path(percentEncoded: false)))?.isEmpty == true {
            try? manager.removeItem(at: previewDirectory)
        }
    }

    /// A JPEG at most 240 px wide and 30 KB, or nil when the image cannot be read or made that small.
    static func previewData(for url: URL, maxPixels: Int = maxPreviewWidth, maxBytes: Int = maxPreviewBytes) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for _ in 0..<4 {
            for quality in [0.7, 0.55, 0.4, 0.3, 0.2] {
                if let data = jpeg(image, quality: quality), data.count <= maxBytes { return data }
            }
            // Still too big: halve the size and try again.
            let width = max(image.width / 2, 1)
            let height = max(image.height / 2, 1)
            guard width > 8, let scaled = resized(image, width: width, height: height) else { return nil }
            image = scaled
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // JPEG has no alpha: flatten onto white so a transparent capture does not turn black.
        let flat = flattened(image) ?? image
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Temp file next to the target (`.<name>.tmp`), mode 0600, fsync, then rename over the target.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp", directoryHint: .notDirectory)
        let tempPath = temp.path(percentEncoded: false)
        let descriptor = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        if close(descriptor) != 0, failure == 0 { failure = errno }
        if failure == 0, fchmodat(AT_FDCWD, tempPath, 0o600, 0) != 0 { failure = errno }
        if failure == 0, rename(tempPath, url.path(percentEncoded: false)) != 0 { failure = errno }
        if failure != 0 {
            unlink(tempPath)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}
