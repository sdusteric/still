import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

/// A recording source with no screen and no audio device (design 20.14, D76): it writes a real
/// mp4 with `AVAssetWriter` from synthetic frames (the `SyntheticImages` gradient and grid with a
/// frame counter block, so every frame differs) at the plan's size, fps and codec, plus one silent
/// AAC track per requested audio source, built from generated sample buffers. Nothing is played.
public final class FakeRecordingSource: RecordingSource {
    public struct Options: Sendable, Hashable {
        /// Frames written after start; the session then idles until `stop()`.
        public var frames: Int
        /// `start` throws `startError`, before any file is created.
        public var failOnStart: Bool
        public var startError: RecordingSourceError
        /// After this many frames the session reports `stoppedBySystem(systemStopReason)`.
        public var stopAfterFrames: Int?
        public var systemStopReason: RecordingStopReason
        /// After this many frames the session stops writing and never finishes the file, as a
        /// crash would: the mp4 has no index and does not play.
        public var killAfterFrames: Int?
        /// The level of a 440 Hz tone in the audio tracks, in dBFS; nil writes digital silence.
        public var audioToneDBFS: Double?
        /// False leaves the audio tracks out although the plan asks for audio, as a recorder that
        /// lost its audio would.
        public var writesAudioTracks: Bool

        public init(
            frames: Int = 30,
            failOnStart: Bool = false,
            startError: RecordingSourceError = .startFailed("the fake source was told to fail"),
            stopAfterFrames: Int? = nil,
            systemStopReason: RecordingStopReason = .windowClosed,
            killAfterFrames: Int? = nil,
            audioToneDBFS: Double? = nil,
            writesAudioTracks: Bool = true
        ) {
            self.frames = max(frames, 0)
            self.failOnStart = failOnStart
            self.startError = startError
            self.stopAfterFrames = stopAfterFrames
            self.systemStopReason = systemStopReason
            self.killAfterFrames = killAfterFrames
            self.audioToneDBFS = audioToneDBFS
            self.writesAudioTracks = writesAudioTracks
        }
    }

    private struct State {
        var options: Options
        var sessions: [FakeRecordingSession] = []
        var startCount = 0
    }

    private let clock: any Clock
    private let state: Mutex<State>

    public init(clock: any Clock = SystemClock(), options: Options = Options()) {
        self.clock = clock
        self.state = Mutex(State(options: options))
    }

    public var options: Options {
        get { state.withLock { $0.options } }
        set { state.withLock { $0.options = newValue } }
    }

    /// Calls to `start`, including failed ones.
    public var startCount: Int { state.withLock { $0.startCount } }

    /// Every session started, oldest first.
    public var sessions: [FakeRecordingSession] { state.withLock { $0.sessions } }

    public var lastSession: FakeRecordingSession? { sessions.last }

    public func start(_ plan: RecordingPlan) async throws -> any RecordingSession {
        let options = state.withLock { state -> Options in
            state.startCount += 1
            return state.options
        }
        if options.failOnStart { throw options.startError }
        guard let url = plan.outputURL else { throw RecordingSourceError.missingOutputURL }
        let session = try FakeRecordingSession(plan: plan, outputURL: url, options: options, clock: clock)
        state.withLock { $0.sessions.append(session) }
        session.begin()
        return session
    }
}

/// One fake recording: a background writing task and the `AVAssetWriter` it feeds. The writer and
/// its receivers are not sendable, so the writing tasks own them from start to end: the video task
/// writes the frames, waits for `stop()`, then finishes the file and hands `stop()` the outcome.
/// Audio goes in from its own task: a non-real-time writer holds one input back until the other
/// catches up, so feeding both from one loop can leave that loop waiting on an input forever.
public final class FakeRecordingSession: RecordingSession {
    public enum Phase: String, Sendable, Hashable {
        case writing
        /// All requested frames are written; waiting for `stop()`.
        case idle
        /// Stopped writing after `killAfterFrames` without finishing the file.
        case killed
        case finishing
        case finished
        case failed
    }

    private struct Writer {
        let writer: AVAssetWriter
        let baseFrame: [UInt8]
    }

    private struct Progress {
        var phase: Phase = .writing
        var framesWritten = 0
        var stopRequested = false
        var loopEnded = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// The writing task, waiting for `stop()` once its frames are written.
        var stopWaiter: CheckedContinuation<Void, Never>?
        /// Whether the audio task finishes its inputs (a normal stop) or leaves them open (killed
        /// or failed); nil until the video task decides.
        var finishAudio: Bool?
        var audioWaiters: [CheckedContinuation<Bool, Never>] = []
        /// Samples delivered after the written frames, by `deliver(...)` (the heartbeat tests).
        var extra = RecordingSampleCounts()
    }

    public static let counterCellSize = 16
    public static let counterBits = 16

    public let plan: RecordingPlan
    public let outputURL: URL
    public let options: FakeRecordingSource.Options
    public let events: AsyncStream<RecordingSessionEvent>
    private let continuation: AsyncStream<RecordingSessionEvent>.Continuation
    private let clock: any Clock
    /// The writer and its receivers until `begin()` starts the writing task, which takes them.
    private let slot: Mutex<Writer?>
    private let videoSlot: Mutex<AVAssetWriterInput.PixelBufferReceiver?>
    private let audioSlot: Mutex<[AVAssetWriterInput.SampleBufferReceiver]?>
    private let task = Mutex<Task<Ending, Never>?>(nil)
    private let progress = Mutex(Progress())

    init(plan: RecordingPlan, outputURL: URL, options: FakeRecordingSource.Options, clock: any Clock) throws {
        self.plan = plan
        self.outputURL = outputURL
        self.options = options
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: RecordingSessionEvent.self)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoSlot = Mutex(try FakeRecordingSession.makeVideoReceiver(writer: writer, plan: plan))
        audioSlot = Mutex(
            options.writesAudioTracks ? try FakeRecordingSession.makeAudioReceivers(writer: writer, plan: plan) : nil
        )
        slot = Mutex(try FakeRecordingSession.startWriting(writer, plan: plan))
    }

    public var framesWritten: Int { progress.withLock { $0.framesWritten } }
    public var phase: Phase { progress.withLock { $0.phase } }

    /// Every written frame counts as one video sample and, for each audio source the plan records,
    /// one audio sample; `deliver` adds more without writing them.
    public var sampleCounts: RecordingSampleCounts {
        progress.withLock { progress in
            let frames = progress.framesWritten
            return RecordingSampleCounts(
                videoFrames: frames + progress.extra.videoFrames,
                systemAudio: plan.capturesAudio ? frames + progress.extra.systemAudio : 0,
                microphone: plan.capturesMicrophone ? frames + progress.extra.microphone : 0
            )
        }
    }

    /// Counts samples as delivered without writing them, as a running stream would between
    /// heartbeat reads. A test that wants a stall stops calling it for one track.
    public func deliver(video: Int = 1, systemAudio: Int = 1, microphone: Int = 1) {
        progress.withLock { progress in
            progress.extra.videoFrames += video
            progress.extra.systemAudio += systemAudio
            progress.extra.microphone += microphone
        }
    }

    /// The frame count the writing loop stops at before idling, being killed or reporting a system stop.
    public var frameTarget: Int {
        min(options.frames, options.stopAfterFrames ?? .max, options.killAfterFrames ?? .max)
    }

    /// Returns once the writing loop has written its frames (or was killed, stopped or failed).
    public func waitUntilWritten() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let ended = progress.withLock { progress -> Bool in
                if progress.loopEnded { return true }
                progress.waiters.append(waiter)
                return false
            }
            if ended { waiter.resume() }
        }
    }

    func begin() {
        let handle = Task.detached(priority: .userInitiated) { [self] in
            await writeLoop()
        }
        task.withLock { $0 = handle }
    }

    public func stop() async throws -> URL {
        let (alreadyStopped, waiter) = progress.withLock { progress -> (Bool, CheckedContinuation<Void, Never>?) in
            if progress.stopRequested { return (true, nil) }
            progress.stopRequested = true
            defer { progress.stopWaiter = nil }
            return (false, progress.stopWaiter)
        }
        if alreadyStopped { throw RecordingSourceError.notRecording }
        waiter?.resume()
        let ending = await task.withLock { $0 }?.value ?? .failed("the writing task never started")
        continuation.finish()
        switch ending {
        case .completed:
            progress.withLock { $0.phase = .finished }
            return outputURL
        case .failed(let message):
            progress.withLock { $0.phase = .failed }
            throw RecordingSourceError.startFailed(message)
        case .unfinished:
            throw RecordingSourceError.notRecording
        }
    }

    /// How the writing task left the file.
    private enum Ending: Sendable {
        case completed
        case failed(String)
        /// Killed or failed while writing frames: the file was never finished.
        case unfinished
    }

    /// Returns once `stop()` was called.
    private func waitForStop() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let stopped = progress.withLock { progress -> Bool in
                if progress.stopRequested { return true }
                progress.stopWaiter = waiter
                return false
            }
            if stopped { waiter.resume() }
        }
    }

    // MARK: Writing

    private func writeLoop() async -> Ending {
        guard let state = slot.withLock({ $0.take() }), let video = videoSlot.withLock({ $0.take() }) else {
            return .failed("the writer was already taken")
        }
        let target = frameTarget
        let audio = audioSlot.withLock { $0.take() } ?? []
        let audioTask: Task<String?, Never>? = audio.isEmpty ? nil : Task.detached(priority: .userInitiated) { [self] in
            await writeAudio(audio, frameTarget: target)
        }
        var failure: String?
        for index in 0..<target {
            if progress.withLock({ $0.stopRequested }) { break }
            do {
                // A stop while the input holds a frame back ends the loop instead of waiting for it.
                let outcome = try await FakeRecordingSession.append(
                    frame: index, plan: plan, base: state.baseFrame, to: video, writer: state.writer
                ) { self.progress.withLock { $0.stopRequested } }
                if outcome == .gaveUp { break }
            } catch {
                failure = String(describing: error)
                break
            }
            progress.withLock { $0.framesWritten = index + 1 }
            if index == 0 { continuation.yield(.firstFrame(at: clock.now())) }
        }
        let written = framesWritten
        let waiters = progress.withLock { progress -> [CheckedContinuation<Void, Never>] in
            if failure != nil {
                progress.phase = .failed
            } else if let kill = options.killAfterFrames, written >= kill {
                progress.phase = .killed
            } else {
                progress.phase = .idle
            }
            progress.loopEnded = true
            let waiters = progress.waiters
            progress.waiters = []
            return waiters
        }
        if let failure {
            continuation.yield(.failed(failure))
        } else if options.killAfterFrames.map({ written >= $0 }) != true,
                  let stopAfter = options.stopAfterFrames, written >= stopAfter {
            continuation.yield(.stoppedBySystem(options.systemStopReason))
        }
        for waiter in waiters { waiter.resume() }

        // A killed session keeps its writer open and unfinished until `stop()`, as a crash leaves
        // the file; a failed one has nothing to finish.
        await waitForStop()
        let finishing = progress.withLock { progress -> Bool in
            guard progress.phase == .idle else { return false }
            progress.phase = .finishing
            return true
        }
        guard finishing else {
            decideAudio(finish: false)
            return .unfinished
        }
        // Finishing the video input first lets an audio input that waits for video take more again.
        video.finish()
        decideAudio(finish: true)
        if let audioFailure = await audioTask?.value {
            state.writer.cancelWriting()
            return .failed(audioFailure)
        }
        state.writer.endSession(atSourceTime: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(plan.fps)))
        await state.writer.finishWriting()
        guard state.writer.status == .completed else {
            return .failed(state.writer.error.map { String(describing: $0) } ?? "the writer did not complete")
        }
        return .completed
    }

    /// Writes silence to every audio input. While the frames are written it runs up to one
    /// second past the last frame, so the writer never holds a frame back for audio; once the
    /// video input is finished it covers the frames written plus two (`endSession` trims the
    /// rest), then finishes the audio inputs. Returns an error message, or nil.
    private func writeAudio(_ receivers: [AVAssetWriterInput.SampleBufferReceiver], frameTarget: Int) async -> String? {
        let rate = RecordingPlan.audioSampleRate
        let fps = max(plan.fps, 1)
        var written = Array(repeating: 0, count: receivers.count)
        do {
            let format = try FakeRecordingSession.makeAudioFormat()
            try await fillAudio(receivers, written: &written, upTo: frameTarget * rate / fps + rate, format: format) {
                self.progress.withLock { $0.loopEnded || $0.stopRequested }
            }
            guard await audioDecision() else { return nil }
            let goal = min(frameTarget * rate / fps + rate, (framesWritten + 2) * rate / fps)
            try await fillAudio(receivers, written: &written, upTo: goal, format: format) { false }
        } catch {
            return String(describing: error)
        }
        for receiver in receivers { receiver.finish() }
        return nil
    }

    /// Appends silence to each input until it holds `goal` samples, or until `giveUp` while an
    /// input is not ready.
    private func fillAudio(
        _ receivers: [AVAssetWriterInput.SampleBufferReceiver],
        written: inout [Int],
        upTo goal: Int,
        format: CMAudioFormatDescription,
        giveUp: () -> Bool
    ) async throws {
        while true {
            var appended = false
            for (index, receiver) in receivers.enumerated() where written[index] < goal {
                let start = written[index]
                let count = min(1024, goal - start)
                let sample = try FakeRecordingSession.audio(
                    format: format, start: start, count: count, toneDBFS: options.audioToneDBFS
                )
                let ready = CMReadySampleBuffer(unsafeBuffer: sample)
                let outcome = try await WriterInputAppend.untilAccepted(giveUp: giveUp) {
                    do {
                        return try receiver.appendImmediately(ready)
                    } catch {
                        throw FakeRecordingError.appendFailed(String(describing: error))
                    }
                }
                guard outcome == .appended else { return }
                written[index] = start + count
                appended = true
            }
            if !appended { return }
        }
    }

    private func decideAudio(finish: Bool) {
        let waiters = progress.withLock { progress -> [CheckedContinuation<Bool, Never>] in
            progress.finishAudio = finish
            let waiters = progress.audioWaiters
            progress.audioWaiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: finish) }
    }

    /// Returns once the video task has decided whether the audio inputs are finished.
    private func audioDecision() async -> Bool {
        await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
            let decided = progress.withLock { progress -> Bool? in
                if let finish = progress.finishAudio { return finish }
                progress.audioWaiters.append(waiter)
                return nil
            }
            if let decided { waiter.resume(returning: decided) }
        }
    }

    /// Appends one frame once the video input takes more data, as a non-real-time writer requires,
    /// or gives up when `giveUp` turns true while the input is not ready.
    package static func append(
        frame index: Int,
        plan: RecordingPlan,
        base: [UInt8],
        to video: AVAssetWriterInput.PixelBufferReceiver,
        writer: AVAssetWriter,
        giveUp: () -> Bool
    ) async throws -> WriterInputAppend.Outcome {
        guard let pool = video.pixelBufferPool else { throw FakeRecordingError.noPixelBufferPool }
        let buffer: CVMutablePixelBuffer
        do {
            buffer = try pool.makeMutablePixelBuffer()
        } catch {
            throw FakeRecordingError.noPixelBuffer
        }
        buffer.withUnsafeBuffer { fill($0, base: base, size: plan.pixelSize, frame: index) }
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(plan.fps))
        let frame = CVReadOnlyPixelBuffer(buffer)
        do {
            return try await WriterInputAppend.untilAccepted(giveUp: giveUp) {
                try video.appendImmediately(frame, with: time)
            }
        } catch {
            throw FakeRecordingError.appendFailed(describe(writer, error))
        }
    }

    private static func describe(_ writer: AVAssetWriter, _ error: any Error) -> String {
        writer.error.map { String(describing: $0) } ?? String(describing: error)
    }

    /// Copies the base frame and draws the counter: `counterBits` cells, white for a set bit.
    private static func fill(_ buffer: CVPixelBuffer, base: [UInt8], size: PixelSize, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = min(size.width, CVPixelBufferGetWidth(buffer))
        let height = min(size.height, CVPixelBufferGetHeight(buffer))
        let sourceRowBytes = size.width * 4
        base.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(address + row * rowBytes, sourceBase + row * sourceRowBytes, width * 4)
            }
        }
        let cell = counterCellSize
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        for bit in 0..<counterBits {
            let value: UInt8 = (frame >> bit) & 1 == 1 ? 255 : 0
            let originX = cell + bit * cell
            guard originX + cell <= width, cell * 2 <= height else { break }
            for row in cell..<(cell * 2) {
                let start = row * rowBytes + originX * 4
                for column in 0..<cell {
                    let offset = start + column * 4
                    pixels[offset] = value
                    pixels[offset + 1] = value
                    pixels[offset + 2] = value
                    pixels[offset + 3] = 255
                }
            }
        }
    }

    /// `count` frames of 16-bit stereo PCM starting at frame `start`: silence, or a 440 Hz tone at
    /// `toneDBFS`.
    private static func audio(format: CMAudioFormatDescription, start: Int, count: Int, toneDBFS: Double?) throws -> CMSampleBuffer {
        let channels = RecordingPlan.audioChannelCount
        let bytes = count * 2 * channels
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw FakeRecordingError.audioBuffer(status) }
        if let toneDBFS {
            let amplitude = pow(10, toneDBFS / 20) * Double(Int16.max)
            let rate = Double(RecordingPlan.audioSampleRate)
            var samples = [Int16](repeating: 0, count: count * channels)
            for frame in 0..<count {
                let value = Int16(clamping: Int((amplitude * sin(2 * .pi * 440 * Double(start + frame) / rate)).rounded()))
                for channel in 0..<channels { samples[frame * channels + channel] = value }
            }
            status = samples.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            }
        } else {
            status = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == noErr else { throw FakeRecordingError.audioBuffer(status) }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(RecordingPlan.audioSampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw FakeRecordingError.audioBuffer(status) }
        return sample
    }

    // MARK: Setup

    private static func makeVideoReceiver(
        writer: AVAssetWriter,
        plan: RecordingPlan
    ) throws -> sending AVAssetWriterInput.PixelBufferReceiver {
        let size = plan.pixelSize
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        guard writer.canAdd(videoInput) else { throw FakeRecordingError.cannotAddInput("video") }
        return writer.inputPixelBufferReceiver(
            for: videoInput,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: CVImageSize(width: size.width, height: size.height)
            )
        )
    }

    /// One silent AAC input per requested audio source.
    private static func makeAudioReceivers(
        writer: AVAssetWriter,
        plan: RecordingPlan
    ) throws -> sending [AVAssetWriterInput.SampleBufferReceiver]? {
        guard !plan.audioSources.isEmpty else { return nil }
        let audioFormat = try makeAudioFormat()
        var audio: [AVAssetWriterInput.SampleBufferReceiver] = []
        for source in plan.audioSources {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: RecordingPlan.audioSampleRate,
                    AVNumberOfChannelsKey: RecordingPlan.audioChannelCount,
                    AVEncoderBitRateKey: 128_000,
                ],
                sourceFormatHint: audioFormat
            )
            guard writer.canAdd(input) else { throw FakeRecordingError.cannotAddInput("audio \(source.rawValue)") }
            audio.append(writer.inputReceiver(for: input))
        }
        return audio
    }

    /// Starts the writer once its inputs are added.
    private static func startWriting(_ writer: sending AVAssetWriter, plan: RecordingPlan) throws -> sending Writer {
        do {
            try writer.start()
        } catch {
            throw FakeRecordingError.cannotStart(String(describing: error))
        }
        writer.startSession(atSourceTime: .zero)
        guard let base = baseFrame(plan: plan) else { throw FakeRecordingError.noBaseFrame }
        return Writer(writer: writer, baseFrame: base)
    }

    /// The fake desktop in BGRA bytes, drawn once and copied into every frame.
    package static func baseFrame(plan: RecordingPlan) -> [UInt8]? {
        let width = plan.pixelSize.width
        let height = plan.pixelSize.height
        guard let image = SyntheticImages.gradientGrid(width: width, height: height, scale: plan.scale) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: SyntheticImages.colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func makeAudioFormat() throws -> CMAudioFormatDescription {
        let channels = UInt32(RecordingPlan.audioChannelCount)
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(RecordingPlan.audioSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw FakeRecordingError.audioBuffer(status) }
        return format
    }
}

public enum FakeRecordingError: Error, Sendable, Hashable, CustomStringConvertible {
    case cannotAddInput(String)
    case cannotStart(String)
    case noBaseFrame
    case noPixelBufferPool
    case noPixelBuffer
    case noAudioFormat
    case audioBuffer(OSStatus)
    case appendFailed(String)

    public var description: String {
        switch self {
        case .cannotAddInput(let what): "cannot add the \(what) input"
        case .cannotStart(let message): "cannot start writing: \(message)"
        case .noBaseFrame: "cannot draw the synthetic frame"
        case .noPixelBufferPool: "the writer has no pixel buffer pool"
        case .noPixelBuffer: "cannot get a pixel buffer"
        case .noAudioFormat: "no audio format"
        case .audioBuffer(let status): "cannot build a silent audio buffer (\(status))"
        case .appendFailed(let message): message
        }
    }
}
