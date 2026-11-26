import CoreGraphics
import Foundation

/// Where a scrolling capture stands, for the control bar under the area.
public struct ScrollCaptureProgress: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// The first frame is in; nothing has scrolled yet.
        case waiting
        /// New rows came in with the last frame.
        case growing
        /// The view moved further than one frame between two frames; the user should scroll back up a little.
        case tooFast
        /// The image reached its size limit; Done keeps what is there.
        case full
        /// The screen capture kept failing (a display unplugged, the grant revoked); frames stopped.
        case stopped
    }

    public var status: Status
    /// The stitched image so far, in pixels.
    public var pixelSize: PixelSize

    public init(status: Status, pixelSize: PixelSize) {
        self.status = status
        self.pixelSize = pixelSize
    }
}

/// The stitcher, off the main actor.
actor ScrollStitchWorker {
    private var stitcher: ScrollStitcher

    init(stitcher: ScrollStitcher) {
        self.stitcher = stitcher
    }

    func add(_ frame: CGImage) -> (ScrollStitcher.Outcome, PixelSize) {
        let outcome = stitcher.add(frame)
        return (outcome, PixelSize(width: stitcher.pixelWidth, height: stitcher.pixelHeight))
    }

    func image() -> CGImage? { stitcher.makeImage() }
}

/// Scrolling capture (design 6.7): while the user scrolls the content under `area`, a frame of the
/// area is taken every `interval` and stitched onto the image so far. The user scrolls, not Snap,
/// so no Accessibility permission is needed. `finish()` takes one last frame and returns the image.
@MainActor
public final class ScrollCaptureSession {
    /// Ten frames a second keeps up with steady scrolling without taxing the screen capture.
    public static let interval: TimeInterval = 0.1
    /// The strip on the right left out of matching, in points: an overlay scrollbar is about 16 pt.
    public static let scrollbarWidth: Double = 20
    /// One second of failed frames in a row stops the loop.
    public static let maxConsecutiveErrors = 10

    private let source: any CaptureSource
    private let display: DisplayInfo
    private let localRect: CGRect
    /// Read for each frame: Still's panels come and go during a scroll (a card closes), and a
    /// stale window id made every frame refetch the window list.
    private let options: @MainActor () -> CaptureOptions
    private let clock: any Clock
    private let onProgress: @MainActor (ScrollCaptureProgress) -> Void
    private let worker: ScrollStitchWorker
    private var loop: Task<Void, Never>?
    private var canceled = false
    private var lastStatus: ScrollCaptureProgress.Status = .waiting
    private var hasRows = false
    private var consecutiveErrors = 0
    private var lastSize = PixelSize(width: 0, height: 0)
    /// Errors from the capture, for the app log; the loop keeps going.
    public var onError: (@MainActor (any Error) -> Void)?

    /// - Parameter area: global top-left points on `display`.
    public init(
        source: any CaptureSource, display: DisplayInfo, area: CGRect, options: @escaping @MainActor () -> CaptureOptions,
        clock: any Clock,
        onProgress: @escaping @MainActor (ScrollCaptureProgress) -> Void
    ) {
        self.source = source
        self.display = display
        let origin = display.frameTopLeft.origin
        localRect = area.offsetBy(dx: -origin.x, dy: -origin.y)
        self.options = options
        self.clock = clock
        self.onProgress = onProgress
        let ignored = Int((Self.scrollbarWidth * display.scale).rounded())
        worker = ScrollStitchWorker(stitcher: ScrollStitcher(ignoredTrailingColumns: min(ignored, Int(area.width * display.scale) / 4)))
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.takeFrame()
                if status == .full || status == .stopped { return }
                do {
                    try await self.clock.sleep(seconds: Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops taking frames, adds one last frame of the view as it is now, and returns the image.
    /// Nil after `cancel()` or when no frame came in.
    public func finish() async -> CapturedImage? {
        await stop()
        guard !canceled else { return nil }
        if lastStatus != .full, lastStatus != .stopped { _ = await takeFrame() }
        guard let image = await worker.image() else { return nil }
        return CapturedImage(cgImage: image, scale: display.scale, displayID: display.id)
    }

    public func cancel() {
        canceled = true
        loop?.cancel()
    }

    private func stop() async {
        loop?.cancel()
        await loop?.value
        loop = nil
    }

    @discardableResult
    private func takeFrame() async -> ScrollCaptureProgress.Status {
        let frame: CapturedImage
        do {
            frame = try await source.captureRegion(display.id, rect: localRect, options: options())
            consecutiveErrors = 0
        } catch {
            onError?(error)
            consecutiveErrors += 1
            guard consecutiveErrors >= Self.maxConsecutiveErrors else { return lastStatus }
            lastStatus = .stopped
            if !canceled { onProgress(ScrollCaptureProgress(status: .stopped, pixelSize: lastSize)) }
            return lastStatus
        }
        let (outcome, size) = await worker.add(frame.cgImage)
        lastSize = size
        switch outcome {
        case .first: lastStatus = .waiting
        case .added:
            hasRows = true
            lastStatus = .growing
        case .tooFast: lastStatus = .tooFast
        case .full: lastStatus = .full
        case .unchanged:
            // Back in view of the last kept frame (or not moved): any warning no longer holds.
            if lastStatus == .tooFast { lastStatus = hasRows ? .growing : .waiting }
        }
        if !canceled { onProgress(ScrollCaptureProgress(status: lastStatus, pixelSize: size)) }
        return lastStatus
    }
}
