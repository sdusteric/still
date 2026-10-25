import AppKit
import ImageIO
import SnapCore

/// Where history tiles get their thumbnails. The live one is `ThumbnailCache`; the shot scene
/// hands out fixed images.
@MainActor
public protocol HistoryThumbnailProviding: AnyObject {
    /// A thumbnail that is ready now, else nil (the tile shows `thumbnailBacking` meanwhile).
    func cachedThumbnail(for url: URL) -> CGImage?
    /// Makes the thumbnail off the main thread when it is not cached.
    func thumbnail(for url: URL) async -> CGImage?
}

/// History tile thumbnails (design 20.3): `CGImageSourceCreateThumbnailAtIndex` at 328 px on the
/// long side (164 pt at 2x), made off the main thread and kept in an `NSCache` keyed by path and
/// modification date, so an edited capture gets a new thumbnail.
public final class ThumbnailCache: HistoryThumbnailProviding {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public let maxPixelSize: Int
    private let cache = NSCache<NSString, Entry>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(maxPixelSize: Int = Theme.History.thumbnailPixels, countLimit: Int = 600) {
        self.maxPixelSize = maxPixelSize
        cache.countLimit = countLimit
    }

    /// `path|modification time`, or nil when the file is gone.
    nonisolated static func key(for url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(path)|\(modified)"
    }

    public func cachedThumbnail(for url: URL) -> CGImage? {
        guard let key = Self.key(for: url) else { return nil }
        return cache.object(forKey: key as NSString)?.image
    }

    public func thumbnail(for url: URL) async -> CGImage? {
        guard let key = Self.key(for: url) else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached.image }
        if let running = inFlight[key] { return await running.value }
        let size = maxPixelSize
        let task = Task.detached(priority: .utility) { Self.makeThumbnail(url: url, maxPixelSize: size) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(Entry(image), forKey: key as NSString) }
        return image
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    /// The downsampled image, with the EXIF orientation applied. Runs on any thread.
    nonisolated public static func makeThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
