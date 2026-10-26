import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (or the temp dir), removed by its exact path when done.
private final class ProbeScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "video-probe-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A leftover scratch dir inside a temp dir is harmless.
        }
    }

    func file(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }
}

/// Writes a real mp4 with the fake source: `frames` synthetic frames of a 128 x 80 point area at 2x.
private func makeVideo(
    at url: URL,
    frames: Int,
    fps: Int = 30,
    codec: VideoFormat = .h264,
    audio: [AudioSource] = [],
    killAfterFrames: Int? = nil
) async throws -> FakeRecordingSession {
    var settings = Settings()
    settings.recording.fps = fps
    settings.recording.format = codec
    settings.recording.systemAudio = audio.contains(.system)
    settings.recording.microphone = audio.contains(.microphone)
    var plan = try RecordingPlan.make(
        target: .area(CGRect(x: 0, y: 0, width: 128, height: 80)), displays: [DisplayInfo(spec: "2560x1440@2")!],
        settings: settings
    )
    plan.outputURL = url
    let source = FakeRecordingSource(
        clock: FakeClock(), options: FakeRecordingSource.Options(frames: frames, killAfterFrames: killAfterFrames)
    )
    let session = try #require(try await source.start(plan) as? FakeRecordingSession)
    await session.waitUntilWritten()
    if killAfterFrames == nil { _ = try await session.stop() }
    return session
}

@Suite struct VideoProbeTests {
    @Test func probeReportsDurationFramesCodecAndSize() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("clip.mp4")
        _ = try await makeVideo(at: url, frames: 15)
        let probe = await VideoProbe.probe(url)
        #expect(probe.playable)
        #expect(abs(probe.durationSeconds - 0.5) < 0.01)
        #expect(probe.frameCount == 15)
        #expect(probe.codec == "avc1")
        #expect(probe.pixelSize == PixelSize(width: 256, height: 160))
        #expect(probe.videoTrackCount == 1)
        #expect(probe.audioTrackCount == 0)
        #expect(probe.fileBytes > 0)
        #expect(probe.error == nil)
    }

    @Test func hevcAtSixtyFramesPerSecondProbesAsHvc1() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("clip.mp4")
        _ = try await makeVideo(at: url, frames: 30, fps: 60, codec: .hevc)
        let probe = await VideoProbe.probe(url)
        #expect(probe.playable)
        #expect(probe.codec == "hvc1")
        #expect(probe.frameCount == 30)
        #expect(abs(probe.durationSeconds - 0.5) < 0.01)
        let rate = try #require(probe.nominalFrameRate)
        #expect(abs(rate - 60) < 0.5)
    }

    @Test func thePosterHasTheVideoSizeAndShowsTheFrame() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("clip.mp4")
        _ = try await makeVideo(at: url, frames: 30)
        let image = try await PosterWriter.posterImage(of: url, duration: 1)
        #expect(image.width == 256)
        #expect(image.height == 160)
        let png = try await PosterWriter.posterPNG(of: url, duration: 1, scale: 2)
        let read = try PNGReader.read(png)
        #expect(read.pixelWidth == 256)
        #expect(read.scale == 2)
        // The synthetic desktop is a gradient with a grid, never one flat colour.
        let corner = try #require(SyntheticImages.pixel(of: image, x: 2, y: 150))
        let far = try #require(SyntheticImages.pixel(of: image, x: 250, y: 150))
        #expect(abs(corner.luminance - far.luminance) > 4)
    }

    @Test func thePosterTimeIsHalfASecondOrHalfAShortRecording() {
        #expect(PosterWriter.posterTime(duration: 42.4) == 0.5)
        #expect(PosterWriter.posterTime(duration: 1) == 0.5)
        #expect(PosterWriter.posterTime(duration: 0.6) == 0.3)
        #expect(PosterWriter.posterTime(duration: 0) == 0)
    }

    @Test func audioMixExportTurnsTwoAudioTracksIntoOne() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("Snap two tracks.mp4")
        _ = try await makeVideo(at: url, frames: 30, audio: [.system, .microphone])
        let before = await VideoProbe.probe(url)
        #expect(before.audioTrackCount == 2)

        let mixed = try await AudioMixExport.mixAudioIfNeeded(at: url)
        #expect(mixed)
        let after = await VideoProbe.probe(url)
        #expect(after.playable)
        #expect(after.audioTrackCount == 1)
        #expect(after.frameCount == 30)
        #expect(after.codec == "avc1")
        #expect(after.pixelSize == before.pixelSize)
        #expect(abs(after.durationSeconds - 1) < 0.05)
        // The swap is a rename: no temp file is left next to the mp4.
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path(percentEncoded: false))
        #expect(names == ["Snap two tracks.mp4"])
    }

    @Test func audioMixExportLeavesAOneTrackFileAlone() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("one track.mp4")
        _ = try await makeVideo(at: url, frames: 15, audio: [.system])
        let bytes = VideoProbe.fileSize(url)
        #expect(try await AudioMixExport.mixAudioIfNeeded(at: url) == false)
        #expect(VideoProbe.fileSize(url) == bytes)
        #expect(await VideoProbe.probe(url).audioTrackCount == 1)
    }

    @Test func missingAndUnfinishedFilesAreNotPlayable() async throws {
        let scratch = try ProbeScratch()
        let missing = await VideoProbe.probe(scratch.file("nothing.mp4"))
        #expect(!missing.playable)
        #expect(missing.error != nil)

        let killed = scratch.file("killed.mp4")
        let session = try await makeVideo(at: killed, frames: 30, killAfterFrames: 10)
        #expect(session.phase == .killed)
        #expect(session.framesWritten == 10)
        let probe = await VideoProbe.probe(killed)
        #expect(!probe.playable)
    }

    @Test func stoppingWhileFramesAreWrittenFinishesAPlayableFile() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("early.mp4")
        var settings = Settings()
        settings.recording.systemAudio = true
        var plan = try RecordingPlan.make(
            target: .area(CGRect(x: 0, y: 0, width: 128, height: 80)), displays: [DisplayInfo(spec: "2560x1440@2")!],
            settings: settings
        )
        plan.outputURL = url
        let source = FakeRecordingSource(clock: FakeClock(), options: FakeRecordingSource.Options(frames: 3_000))
        let session = try #require(try await source.start(plan) as? FakeRecordingSession)
        // Stop right after the first frame, while the rest are still being written.
        for await event in session.events {
            if case .firstFrame = event { break }
        }
        #expect(try await session.stop() == url)
        #expect(session.phase == .finished)
        await #expect(throws: RecordingSourceError.notRecording) { try await session.stop() }
        let written = session.framesWritten
        #expect(written >= 1 && written < 3_000)
        let probe = await VideoProbe.probe(url)
        #expect(probe.playable)
        #expect(probe.frameCount == written)
        #expect(probe.audioTrackCount == 1)
    }

    @Test func stoppingAKilledSessionLeavesTheFileUnfinished() async throws {
        let scratch = try ProbeScratch()
        let url = scratch.file("killed-stop.mp4")
        let session = try await makeVideo(at: url, frames: 30, killAfterFrames: 6)
        await #expect(throws: RecordingSourceError.notRecording) { try await session.stop() }
        #expect(session.phase == .killed)
        #expect(!(await VideoProbe.probe(url)).playable)
    }

    @Test func aMixCopyThrowsAtOnceWhenTheOtherCopyFailedInsteadOfWaitingForTheTimeout() async throws {
        struct WriterFailed: Error {}
        let abort = CopyAbort()
        let started = Date()
        let stuck = Task { try await AudioMixExport.append(abort: abort) { false } }
        let failing = Task { try await AudioMixExport.append(abort: abort) { throw WriterFailed() } }
        await #expect(throws: WriterFailed.self) { try await failing.value }
        await #expect(throws: AudioMixExportError.cannotWrite("the other track failed")) { try await stuck.value }
        #expect(abort.isSet)
        // Well under the 30 s append timeout; 2 s failed under a loaded parallel suite (2.7 to 3.2 s).
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func theFakeVideoAppendGivesUpWhenTheWriterHoldsFramesBack() async throws {
        let scratch = try ProbeScratch()
        var plan = try RecordingPlan.make(
            target: .area(CGRect(x: 0, y: 0, width: 64, height: 40)), displays: [DisplayInfo(spec: "2560x1440@2")!],
            settings: Settings()
        )
        plan.outputURL = scratch.file("held.mp4")
        let writer = try AVAssetWriter(outputURL: scratch.file("held.mp4"), fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 80,
        ])
        // An audio input that never gets data makes a non-real-time writer stop taking video.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        writer.add(video)
        writer.add(audio)
        let receiver = writer.inputPixelBufferReceiver(
            for: video,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: 128, height: 80)
            )
        )
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let base = try #require(FakeRecordingSession.baseFrame(plan: plan))
        let started = Date()
        var outcome = WriterInputAppend.Outcome.appended
        var frame = 0
        while outcome == .appended, frame < 3_000 {
            outcome = try await FakeRecordingSession.append(
                frame: frame, plan: plan, base: base, to: receiver, writer: writer
            ) { true }
            frame += 1
        }
        #expect(outcome == .gaveUp)
        #expect(Date().timeIntervalSince(started) < 10)
        writer.cancelWriting()
    }

    @Test func fourCCCodesReadAsFourCharacters() {
        #expect(VideoProbe.fourCC(0x6176_6331) == "avc1")
        #expect(VideoProbe.fourCC(0x6876_6331) == "hvc1")
    }
}
