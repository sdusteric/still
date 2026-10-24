import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SnapCore
import Synchronization

/// Writes captures to a pasteboard (design section 9 and D13): one `NSPasteboardItem` with the
/// PNG written at once and TIFF promised through a data provider, because a 5K TIFF is about
/// 59 MB and most paste targets take the PNG. The PNG carries the DPI, so it pastes at point size.
///
/// Holds the pasteboard name rather than the pasteboard, so it is Sendable. The app uses
/// `.general`; tests use a uniquely named private pasteboard and release it.
public struct PasteboardWriter: ClipboardWriting {
    public enum WriteError: Error, CustomStringConvertible {
        case rejected

        public var description: String {
            switch self {
            case .rejected: "the pasteboard rejected the item"
            }
        }
    }

    public let pasteboardName: NSPasteboard.Name

    public init(pasteboardName: NSPasteboard.Name = .general) {
        self.pasteboardName = pasteboardName
    }

    public func writeImage(pngData: Data, image: CGImage, scale: Double) throws {
        let pasteboard = NSPasteboard(name: pasteboardName)
        let item = NSPasteboardItem()
        guard item.setData(pngData, forType: .png) else { throw WriteError.rejected }
        let provider = TIFFProvider(image: image, scale: scale)
        guard item.setDataProvider(provider, forTypes: [.tiff]) else { throw WriteError.rejected }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw WriteError.rejected }
        TIFFProvider.retain(provider, for: pasteboardName)
    }

    /// "Copy file": the file URL only, so Finder and mail clients attach the file itself.
    public func writeFileURL(_ url: URL) throws {
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { throw WriteError.rejected }
    }

    /// TIFF bytes with the same DPI as the PNG, for the lazy provider and tests.
    public static func tiffData(for image: CGImage, scale: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.tiff" as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * (scale > 0 ? scale : 1)
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Supplies TIFF only when a paste target asks for it.
final class TIFFProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    let image: CGImage
    let scale: Double

    /// The latest provider per pasteboard, kept alive until the pasteboard is done with it. One per
    /// pasteboard bounds the memory to one image.
    private static let live = Mutex<[String: TIFFProvider]>([:])

    init(image: CGImage, scale: Double) {
        self.image = image
        self.scale = scale
    }

    static func retain(_ provider: TIFFProvider, for name: NSPasteboard.Name) {
        live.withLock { $0[name.rawValue] = provider }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let data = PasteboardWriter.tiffData(for: image, scale: scale) else { return }
        item.setData(data, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        let name = pasteboard.name.rawValue
        TIFFProvider.live.withLock { live in
            if live[name] === self { live[name] = nil }
        }
    }
}
