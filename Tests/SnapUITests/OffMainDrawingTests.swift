import AppKit
import SnapCore
@testable import SnapUI
import Testing

/// NSImage documents that a drawing handler "may be invoked whenever and on whatever thread the
/// image itself is drawn on". A handler that inherits the main actor traps in dispatch_assert_queue
/// when AppKit draws the image elsewhere, so each image Snap builds this way is drawn here on a
/// global queue. Before the fix these tests crash the test process instead of failing.
@MainActor
@Suite struct OffMainDrawingTests {
    @Test func menuThumbnailDrawsOffTheMainThread() async throws {
        let image = StatusMenuController.thumbnailImage(Self.solidImage())
        let center = try #require(await Self.drawOffMain(image))
        #expect(center.alphaComponent > 0.9)
        #expect(center.redComponent > 0.9)
    }

    @Test func menuThumbnailWithoutAnImageDrawsOffTheMainThread() async throws {
        let image = StatusMenuController.thumbnailImage(nil)
        #expect(await Self.drawOffMain(image) != nil)
    }

    @Test func statusDotDrawsOffTheMainThread() async throws {
        let image = StatusMenuController.dotImage(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let center = try #require(await Self.drawOffMain(image))
        #expect(center.alphaComponent > 0.9)
        #expect(center.redComponent > 0.9)
    }

    @Test func dragImageDrawsOffTheMainThread() async throws {
        let image = ThumbnailDragSourceView.dragImage(from: Self.solidImage(), displaySize: CGSize(width: 320, height: 200))
        let center = try #require(await Self.drawOffMain(image))
        #expect(center.alphaComponent > 0.9)
    }

    /// Draws `image` into a bitmap on a global queue, the way AppKit may, and returns the color at
    /// its center (nil when the bitmap could not be made).
    nonisolated static func drawOffMain(_ image: NSImage) async -> NSColor? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(!Thread.isMainThread)
                let width = max(Int(image.size.width), 1)
                let height = max(Int(image.size.height), 1)
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
                    continuation.resume(returning: nil)
                    return
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                NSGraphicsContext.restoreGraphicsState()
                let center = rep.colorAt(x: width / 2, y: height / 2)?.usingColorSpace(.sRGB)
                continuation.resume(returning: center)
            }
        }
    }

    /// A 64 x 64 opaque red image.
    nonisolated static func solidImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()
    }
}
