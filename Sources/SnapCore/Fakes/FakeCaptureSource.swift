import CoreGraphics
import Foundation
import Synchronization

/// A capture source that never touches the screen: each fake display returns a gradient-and-grid
/// image at its pixel size (1x and 2x, including 5120x2880), after an optional delay.
public final class FakeCaptureSource: CaptureSource {
    /// One call, recorded for tests.
    public enum Call: Sendable, Hashable {
        case displays
        case display(DisplayID, CaptureOptions)
        case window(WindowID, CaptureOptions)
    }

    public let displayList: [DisplayInfo]
    public let windows: [WindowInfo]
    /// Seconds each capture waits before returning, through `clock`.
    public let delay: TimeInterval
    private let clock: any Clock
    private let images: Mutex<[DisplayID: CGImage]>
    private let failure: Mutex<CaptureError?>
    private let calls: Mutex<[Call]>

    /// Renders every display image up front (unless `prerender` is false) so the timed path only
    /// hands out a cached image, as the live source hands out a finished frame.
    public init(
        displays: [DisplayInfo] = [.fake5K],
        windows: [WindowInfo] = FakeWindowSource.sample,
        delay: TimeInterval = 0,
        clock: any Clock = SystemClock(),
        prerender: Bool = true
    ) {
        self.displayList = displays
        self.windows = windows
        self.delay = max(delay, 0)
        self.clock = clock
        self.images = Mutex([:])
        self.failure = Mutex(nil)
        self.calls = Mutex([])
        if prerender {
            for display in displays { _ = image(for: display) }
        }
    }

    /// Makes every later capture throw `error` (nil clears it), for permission lapse tests.
    public func setFailure(_ error: CaptureError?) {
        failure.withLock { $0 = error }
    }

    public var recordedCalls: [Call] { calls.withLock { $0 } }

    public func displays() async throws -> [DisplayInfo] {
        calls.withLock { $0.append(.displays) }
        if let error = failure.withLock({ $0 }) { throw error }
        return displayList
    }

    public func captureDisplay(_ displayID: DisplayID, options: CaptureOptions) async throws -> CapturedImage {
        calls.withLock { $0.append(.display(displayID, options)) }
        try await wait()
        guard let display = displayList.first(where: { $0.id == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        guard let cgImage = image(for: display) else {
            throw CaptureError.failed("fake image for display \(displayID) could not be drawn")
        }
        return CapturedImage(cgImage: cgImage, scale: display.scale, displayID: displayID)
    }

    public func captureWindow(_ windowID: WindowID, options: CaptureOptions) async throws -> CapturedImage {
        calls.withLock { $0.append(.window(windowID, options)) }
        try await wait()
        guard let window = windows.first(where: { $0.id == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let scale = scale(containing: window.frame)
        // The live capture grows by the shadow; 24 pt per side stands in for it here.
        let margin = options.includeWindowShadow ? 24 * scale : 0
        let width = Int((window.frame.width * scale + 2 * margin).rounded())
        let height = Int((window.frame.height * scale + 2 * margin).rounded())
        guard let context = SyntheticImages.makeContext(width: width, height: height) else {
            throw CaptureError.failed("fake window image \(width)x\(height) could not be drawn")
        }
        let body = CGRect(x: margin, y: margin, width: window.frame.width * scale, height: window.frame.height * scale)
        if margin > 0 {
            context.setShadow(offset: CGSize(width: 0, height: 8 * scale), blur: 20 * scale,
                              color: CGColor(gray: 0, alpha: 0.4))
        }
        let radius = 16 * scale
        context.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1))
        context.fillPath()
        guard let cgImage = context.makeImage() else {
            throw CaptureError.failed("fake window image could not be finished")
        }
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: nil)
    }

    private func wait() async throws {
        if let error = failure.withLock({ $0 }) { throw error }
        if delay > 0 { try await clock.sleep(seconds: delay) }
    }

    private func scale(containing frame: CGRect) -> Double {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displayList.first { $0.frameTopLeft.contains(center) }?.scale ?? displayList.first?.scale ?? 2
    }

    private func image(for display: DisplayInfo) -> CGImage? {
        if let cached = images.withLock({ $0[display.id] }) { return cached }
        guard let made = SyntheticImages.gradientGrid(
            width: display.pixelWidth, height: display.pixelHeight, scale: display.scale
        ) else { return nil }
        images.withLock { $0[display.id] = made }
        return made
    }
}
