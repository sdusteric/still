import Foundation

/// What Copy puts on the pasteboard (design 9): the image, or with Option ("Copy file") the URL
/// of the item's current PNG in history, so Finder and mail clients take the file itself.
public enum ClipboardCopy {
    public enum Kind: Sendable, Hashable {
        case image, file
    }

    public enum CopyError: Error, CustomStringConvertible {
        case noFile

        public var description: String {
            switch self {
            case .noFile: "the capture has no file in history yet"
            }
        }
    }

    public static func write(
        _ kind: Kind, image: CapturedImage, fileURL: URL?, to clipboard: any ClipboardWriting
    ) throws {
        switch kind {
        case .image:
            let png = try PNGWriter.data(for: image.cgImage, scale: image.scale)
            try clipboard.writeImage(pngData: png, image: image.cgImage, scale: image.scale)
        case .file:
            guard let fileURL else { throw CopyError.noFile }
            try clipboard.writeFileURL(fileURL)
        }
    }
}
