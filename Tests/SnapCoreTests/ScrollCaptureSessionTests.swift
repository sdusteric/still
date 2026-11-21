import CoreGraphics
import Foundation
@testable import SnapCore
import Synchronization
import Testing

/// Hands out scripted frames, one per region capture; the last one repeats. Records each request.
final class ScriptedRegionSource: CaptureSource {
    private let frames: [CGImage]
    /// Every capture throws when set (a display unplugged, the grant revoked).
    let failing = Mutex(false)
    private let state = Mutex<(served: Int, rects: [CGRect], options: [CaptureOptions])>((0, [], []))
    let display: DisplayInfo

    init(frames: [CGImage], display: DisplayInfo) {
        self.frames = frames
        self.display = display
    }

    var served: Int { state.withLock { $0.served } }
    var rects: [CGRect] { state.withLock { $0.rects } }
    var options: [CaptureOptions] { state.withLock { $0.options } }

    func displays() async throws -> [DisplayInfo] { [display] }

    func captureDisplay(_ displayID: DisplayID, options: CaptureOptions) async throws -> CapturedImage {
        throw CaptureError.failed("scripted source captures regions only")
    }

    func captureWindow(_ windowID: WindowID, options: CaptureOptions) async throws -> CapturedImage {
        throw CaptureError.windowNotFound(windowID)
    }

    func captureRegion(_ displayID: DisplayID, rect: CGRect, options: CaptureOptions) async throws -> CapturedImage {
        if failing.withLock({ $0 }) {
            state.withLock { $0.served += 1 }
            throw CaptureError.displayNotFound(displayID)
        }
        let index = state.withLock { state -> Int in
            state.rects.append(rect)
            state.options.append(options)
            defer { state.served += 1 }
            return state.served
        }
        return CapturedImage(cgImage: frames[min(index, frames.count - 1)], scale: 2, displayID: displayID)
    }
}

@MainActor
@Suite struct ScrollCaptureSessionTests {
    let fixture = ScrollFixture()
    let clock = FakeClock()
    /// A display whose top-left is not the origin, so the local rect is checked too.
    let display = DisplayInfo(id: 7, frameTopLeft: CGRect(x: 2560, y: 0, width: 1920, height: 1080), scale: 2)

    func frames(_ offsets: [Int]) throws -> [CGImage] {
        try offsets.enumerated().map { index, offset in try #require(fixture.frame(offset: offset, frameIndex: index)) }
    }

    /// Lets the loop run until it has taken `count` frames, advancing the clock between them.
    func step(_ source: ScriptedRegionSource, until count: Int) async {
        for _ in 0..<400 where source.served < count {
            await Task.yield()
            if clock.sleeperCount > 0 { clock.advance(by: ScrollCaptureSession.interval) }
        }
    }

    @Test func framesAreTakenOfTheRegionAndStitchedUntilDone() async throws {
        let offsets = [0, 30, 70, 110]
        let source = ScriptedRegionSource(frames: try frames(offsets + [110]), display: display)
        var progress: [ScrollCaptureProgress] = []
        let area = CGRect(x: 2660, y: 100, width: 60, height: 57)
        let session = ScrollCaptureSession(
            source: source, display: display, area: area, options: CaptureOptions(excludedWindowIDs: [42]),
            clock: clock, onProgress: { progress.append($0) }
        )
        session.start()
        await step(source, until: offsets.count)
        let image = try #require(await session.finish())
        let height = ScrollFixture.header + 110 + ScrollFixture.content + ScrollFixture.footer
        #expect(image.pixelHeight == height)
        #expect(image.scale == 2)
        #expect(source.rects.first == CGRect(x: 100, y: 100, width: 60, height: 57), "display-local points")
        #expect(source.options.allSatisfy { $0.excludedWindowIDs == [42] })
        #expect(progress.first?.status == .waiting)
        #expect(progress.last?.status == .growing)
        #expect(progress.last?.pixelSize.height == height)

        // Done stops the loop: no frames are taken afterwards.
        let served = source.served
        clock.advance(by: 1)
        await Task.yield()
        #expect(source.served == served)
    }

    @Test func doneTakesOneLastFrameSoTheFinalViewIsIn() async throws {
        let source = ScriptedRegionSource(frames: try frames([0, 40]), display: display)
        let session = ScrollCaptureSession(
            source: source, display: display, area: CGRect(x: 2560, y: 0, width: 60, height: 57), options: CaptureOptions(),
            clock: clock, onProgress: { _ in }
        )
        session.start()
        await step(source, until: 1)
        let image = try #require(await session.finish())
        #expect(image.pixelHeight == ScrollFixture.header + 40 + ScrollFixture.content + ScrollFixture.footer)
    }

    @Test func repeatedCaptureErrorsStopTheLoopAndSaySo() async throws {
        let source = ScriptedRegionSource(frames: try frames([0]), display: display)
        source.failing.withLock { $0 = true }
        var statuses: [ScrollCaptureProgress.Status] = []
        var errors = 0
        let session = ScrollCaptureSession(
            source: source, display: display, area: CGRect(x: 2560, y: 0, width: 60, height: 57), options: CaptureOptions(),
            clock: clock, onProgress: { statuses.append($0.status) }
        )
        session.onError = { _ in errors += 1 }
        session.start()
        await step(source, until: ScrollCaptureSession.maxConsecutiveErrors)
        for _ in 0..<50 { await Task.yield() }
        #expect(statuses.last == .stopped)
        let served = source.served
        clock.advance(by: 5)
        for _ in 0..<20 { await Task.yield() }
        #expect(source.served == served, "the loop stopped")
        #expect(errors == ScrollCaptureSession.maxConsecutiveErrors)
    }

    @Test func backInViewAfterTooFastClearsTheWarning() async throws {
        let source = ScriptedRegionSource(frames: try frames([0, 300, 0]), display: display)
        var statuses: [ScrollCaptureProgress.Status] = []
        let session = ScrollCaptureSession(
            source: source, display: display, area: CGRect(x: 2560, y: 0, width: 60, height: 57), options: CaptureOptions(),
            clock: clock, onProgress: { statuses.append($0.status) }
        )
        session.start()
        await step(source, until: 3)
        for _ in 0..<200 where statuses.count < 3 { await Task.yield() }
        #expect(statuses.prefix(3) == [.waiting, .tooFast, .waiting])
        session.cancel()
        #expect(await session.finish() == nil)
    }

    @Test func aJumpReportsTooFastUntilTheContentJoinsAgain() async throws {
        let source = ScriptedRegionSource(frames: try frames([0, 300, 50]), display: display)
        var statuses: [ScrollCaptureProgress.Status] = []
        let session = ScrollCaptureSession(
            source: source, display: display, area: CGRect(x: 2560, y: 0, width: 60, height: 57), options: CaptureOptions(),
            clock: clock, onProgress: { statuses.append($0.status) }
        )
        session.start()
        await step(source, until: 3)
        for _ in 0..<200 where statuses.count < 3 { await Task.yield() }
        #expect(statuses.prefix(3) == [.waiting, .tooFast, .growing])
        session.cancel()
        #expect(await session.finish() == nil, "a canceled session has no image")
    }
}
