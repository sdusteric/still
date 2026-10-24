import CoreGraphics
import Foundation
import SnapCore
import Synchronization
import Testing

private final class FakeClipboard: ClipboardWriting {
    private let images = Mutex<[Data]>([])
    private let urls = Mutex<[URL]>([])

    func writeImage(pngData: Data, image: CGImage, scale: Double) throws {
        images.withLock { $0.append(pngData) }
    }

    func writeFileURL(_ url: URL) throws {
        urls.withLock { $0.append(url) }
    }

    var writtenImages: [Data] { images.withLock { $0 } }
    var writtenURLs: [URL] { urls.withLock { $0 } }
}

@Suite struct ClipboardCopyTests {
    let image: CapturedImage
    let file = URL(filePath: "/tmp/snap-test/history/abc/Snap 2026-10-24 at 14.03.22.png")

    init() throws {
        image = CapturedImage(cgImage: try #require(SyntheticImages.solid(width: 8, height: 4, color: .red)), scale: 2)
    }

    @Test func copyWritesTheImageOnly() throws {
        let clipboard = FakeClipboard()
        try ClipboardCopy.write(.image, image: image, fileURL: file, to: clipboard)
        #expect(clipboard.writtenImages.count == 1)
        #expect(clipboard.writtenURLs.isEmpty)
    }

    @Test func copyFileWritesTheHistoryFileURLInstead() throws {
        let clipboard = FakeClipboard()
        try ClipboardCopy.write(.file, image: image, fileURL: file, to: clipboard)
        #expect(clipboard.writtenURLs == [file])
        #expect(clipboard.writtenImages.isEmpty)
    }

    @Test func copyFileWithoutAFileFails() {
        let clipboard = FakeClipboard()
        #expect(throws: ClipboardCopy.CopyError.self) {
            try ClipboardCopy.write(.file, image: image, fileURL: nil, to: clipboard)
        }
        #expect(clipboard.writtenURLs.isEmpty)
    }
}
