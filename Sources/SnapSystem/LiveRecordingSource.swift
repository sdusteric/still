import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import SnapCore
import Synchronization

/// A ScreenCaptureKit error reduced to what the mapping needs, so the mapping is testable
/// without ScreenCaptureKit objects.
public struct StreamFailure: Sendable, Hashable, CustomStringConvertible {
    public var domain: String
    public var code: Int
    public var message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(_ error: any Error) {
        let nsError = error as NSError
        self.init(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
    }

    public var description: String { "\(domain) \(code): \(message)" }
}

/// Errors `LiveRecordingSession.stop()` throws. The controller logs them and probes the file anyway.
public enum LiveRecordingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `SCRecordingOutput` reported a failure while finishing the file.
    case finishFailed(String)

    public var description: String {
        switch self {
        case .finishFailed(let message): "the recording file did not finish: \(message)"
        }
    }
}

/// Screen recording through `SCStream` with `SCRecordingOutput` (design 20.6, D60). The plan
/// holds every value; this type only copies its fields into the filter, the stream configuration
/// and the recording output configuration. Compiled and linted, but never run by a test, tool or
/// agent: only the installed app calls it.
public final class LiveRecordingSource: RecordingSource {
    /// `SCStreamErrorDomain`.
    public static let streamErrorDomain = SCStreamErrorDomain
    /// How long `stop()` waits for `SCRecordingOutput` to finish the file (quit allows 5 s).
    public static let finishTimeout: TimeInterval = 5
    /// How long `start` waits for the recording output to report that it started writing.
    public static let startTimeout: TimeInterval = 3

    /// The `SCStreamError.Code` values the mapping names.
    public enum ErrorCode {
        public static let userDeclined = -3801
        public static let noWindowList = -3813
        public static let noDisplayList = -3814
        public static let noCaptureSource = -3815
        public static let userStopped = -3817
        public static let systemStoppedStream = -3821
        public static let insufficientStorage = -3822
    }

    private let captureSource: LiveCaptureSource
    private let clock: any Clock
    private let log: Log?

    /// - Parameter captureSource: the screenshot source, whose shareable content cache the filters use.
    public init(captureSource: LiveCaptureSource, clock: any Clock = SystemClock(), log: Log? = nil) {
        self.captureSource = captureSource
        self.clock = clock
        self.log = log
    }

    // MARK: RecordingSource

    public func start(_ plan: RecordingPlan) async throws -> any RecordingSession {
        guard let outputURL = plan.outputURL else { throw RecordingSourceError.missingOutputURL }
        let filter: SCContentFilter
        do {
            filter = try await captureSource.recordingFilter(for: plan)
        } catch {
            throw LiveRecordingSource.startError(for: error)
        }
        let configuration = LiveRecordingSource.streamConfiguration(for: plan)
        let outputConfiguration = try LiveRecordingSource.outputConfiguration(for: plan, url: outputURL)
        let session = LiveRecordingSession(
            filter: filter, configuration: configuration, outputConfiguration: outputConfiguration,
            outputURL: outputURL, filterKind: plan.filterKind, clock: clock, log: log
        )
        try await session.begin()
        return session
    }

    /// Finder's desktop-icon windows on a display (design 6.3), for `RecordingPlan.make`'s
    /// `desktopIconWindowIDs` when Hide desktop icons is on.
    public func desktopIconWindowIDs(on displayID: DisplayID) async throws -> [WindowID] {
        try await captureSource.desktopIconWindowIDs(on: displayID)
    }

    // MARK: Copying the plan

    static func streamConfiguration(for plan: RecordingPlan) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = plan.sourceRect
        configuration.width = plan.pixelSize.width
        configuration.height = plan.pixelSize.height
        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        configuration.queueDepth = plan.queueDepth
        configuration.showsCursor = plan.showsCursor
        configuration.showMouseClicks = plan.showsMouseClicks
        configuration.ignoreShadowsSingleWindow = plan.ignoresShadowsSingleWindow
        // YCbCr frames, so the BT.709 matrix of the plan applies; the encoder takes them as is.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = plan.colorSpaceName as CFString
        configuration.colorMatrix = plan.colorMatrix as CFString
        configuration.captureDynamicRange = .SDR
        configuration.capturesAudio = plan.capturesAudio
        configuration.excludesCurrentProcessAudio = plan.excludesCurrentProcessAudio
        configuration.sampleRate = plan.audioSampleRate
        configuration.channelCount = plan.audioChannelCount
        configuration.captureMicrophone = plan.capturesMicrophone
        configuration.microphoneCaptureDeviceID = plan.capturesMicrophone
            ? InputDevices.connectedDeviceID(plan.microphoneDeviceID) : nil
        return configuration
    }

    static func outputConfiguration(for plan: RecordingPlan, url: URL) throws -> SCRecordingOutputConfiguration {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        let codec = LiveRecordingSource.codecType(plan.codec)
        guard configuration.availableVideoCodecTypes.contains(codec) else {
            throw RecordingSourceError.startFailed("\(plan.codec.title) is not available for recording")
        }
        configuration.videoCodecType = codec
        configuration.outputFileType = .mp4
        // One mixed AAC track when both sources record (D64); AudioMixExport stays the fallback.
        if plan.capturesAudio, plan.capturesMicrophone { configuration.mixesAudioWithMicrophone = true }
        return configuration
    }

    static func codecType(_ format: VideoFormat) -> AVVideoCodecType {
        switch format {
        case .h264: .h264
        case .hevc: .hevc
        }
    }

    // MARK: Error mapping

    /// A start failure: -3801 (user declined) is the permission problem of D69, anything else
    /// is "Recording could not start".
    public static func startError(for failure: StreamFailure) -> RecordingSourceError {
        if failure.domain == streamErrorDomain, failure.code == ErrorCode.userDeclined { return .permissionDenied }
        return .startFailed(failure.description)
    }

    static func startError(for error: any Error) -> RecordingSourceError {
        if let sourceError = error as? RecordingSourceError { return sourceError }
        if let captureError = error as? CaptureError {
            switch captureError {
            case .permissionDenied: return .permissionDenied
            case .displayNotFound(let id): return .startFailed("display \(id) is not connected")
            case .windowNotFound(let id): return .startFailed("window \(id) is no longer on screen")
            case .failed(let message): return .startFailed(message)
            }
        }
        return startError(for: StreamFailure(error))
    }

    /// The event for a stream that stopped by itself after it started. A missing capture source
    /// means the window closed (window filter) or the display went away (display filters).
    public static func sessionEvent(for failure: StreamFailure, filterKind: RecordingPlan.FilterKind) -> RecordingSessionEvent {
        guard failure.domain == streamErrorDomain else { return .failed(failure.description) }
        switch failure.code {
        case ErrorCode.userStopped:
            return .stoppedBySystem(.user)
        case ErrorCode.insufficientStorage:
            return .stoppedBySystem(.diskFull)
        case ErrorCode.systemStoppedStream:
            return .stoppedBySystem(.streamFailed)
        case ErrorCode.noCaptureSource, ErrorCode.noWindowList, ErrorCode.noDisplayList:
            switch filterKind {
            case .desktopIndependentWindow:
                return failure.code == ErrorCode.noDisplayList
                    ? .stoppedBySystem(.displayDisconnected) : .stoppedBySystem(.windowClosed)
            case .displayExcludingWindows, .wholeDisplay:
                return failure.code == ErrorCode.noWindowList
                    ? .failed(failure.description) : .stoppedBySystem(.displayDisconnected)
            }
        case ErrorCode.userDeclined:
            return .failed(RecordingSourceError.permissionDenied.description)
        default:
            return .failed(failure.description)
        }
    }
}

// MARK: - Filters from the screenshot source's cache

extension LiveCaptureSource {
    /// The content filter of the plan (design 20.6, D62), built from the cached shareable content,
    /// refetched once when it misses a window the filter names. Excluded panels that are still
    /// missing are not on screen, so they are left out of the list.
    func recordingFilter(for plan: RecordingPlan) async throws -> SCContentFilter {
        let named = plan.filterKind == .desktopIndependentWindow ? plan.windowID.map { [$0] } ?? [] : plan.excludedWindowIDs
        var content = try await cachedContent()
        if !LiveCaptureSource.containsAll(named, in: content) || !content.displays.contains(where: { $0.displayID == plan.displayID }) {
            content = try await fetchContent()
        }
        switch plan.filterKind {
        case .desktopIndependentWindow:
            guard let windowID = plan.windowID else { throw RecordingSourceError.startFailed("the plan names no window") }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowNotFound(windowID)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .displayExcludingWindows, .wholeDisplay:
            guard let display = content.displays.first(where: { $0.displayID == plan.displayID }) else {
                throw CaptureError.displayNotFound(plan.displayID)
            }
            let wanted = Set(plan.excludedWindowIDs)
            let excluded = content.windows.filter { wanted.contains($0.windowID) }
            return SCContentFilter(display: display, excludingWindows: excluded)
        }
    }

    func desktopIconWindowIDs(on displayID: DisplayID) async throws -> [WindowID] {
        let content = try await cachedContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        return desktopIconWindows(in: content, display: display).map(\.windowID)
    }
}

// MARK: - Heartbeat counter

/// Counts the sample buffers ScreenCaptureKit delivers for the heartbeat (design 20.6). Every
/// screen buffer counts, also the ones with an idle frame status, so a still screen is not taken
/// for a stall; the recording output writes the file on its own. Buffers are dropped at once.
final class LiveSampleCounter: NSObject, SCStreamOutput, Sendable {
    private let counts = Mutex(RecordingSampleCounts())
    let queue = DispatchQueue(label: "dev.sdusteric.snap.recording.heartbeat", qos: .utility)

    var current: RecordingSampleCounts { counts.withLock { $0 } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        counts.withLock { counts in
            switch type {
            case .screen: counts.videoFrames += 1
            case .audio: counts.systemAudio += 1
            case .microphone: counts.microphone += 1
            @unknown default: break
            }
        }
    }
}

// MARK: - Session

/// What the stream and recording output delegates report, in order.
enum LiveRecordingCallback: Sendable {
    case recordingStarted(at: TimeInterval)
    case recordingFinished
    case recordingFailed(StreamFailure)
    case streamStopped(StreamFailure)
}

/// The delegate of both the stream and its recording output. Callbacks arrive on
/// ScreenCaptureKit's queues and go to the session through an ordered stream.
final class LiveRecordingDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private let sink: AsyncStream<LiveRecordingCallback>.Continuation
    private let clock: any Clock

    init(sink: AsyncStream<LiveRecordingCallback>.Continuation, clock: any Clock) {
        self.sink = sink
        self.clock = clock
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        sink.yield(.recordingStarted(at: clock.now()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        sink.yield(.recordingFailed(StreamFailure(error)))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        sink.yield(.recordingFinished)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        sink.yield(.streamStopped(StreamFailure(error)))
    }
}

/// One running `SCStream` writing through `SCRecordingOutput` to the plan's file.
public actor LiveRecordingSession: RecordingSession {
    private enum Phase {
        case idle
        case starting
        case recording
        /// The stream stopped by itself; the file may still need finishing.
        case streamEnded
        case stopping
        case stopped
    }

    private enum StartOutcome {
        case started
        case failed(StreamFailure)
        case timedOut
    }

    private enum FinishOutcome {
        case finished
        case failed(String)
    }

    public nonisolated let events: AsyncStream<RecordingSessionEvent>
    private let eventSink: AsyncStream<RecordingSessionEvent>.Continuation
    private let callbacks: AsyncStream<LiveRecordingCallback>
    private let callbackSink: AsyncStream<LiveRecordingCallback>.Continuation
    private let delegate: LiveRecordingDelegate
    private let counter = LiveSampleCounter()
    private let countsAudio: Bool
    private let countsMicrophone: Bool
    private let stream: SCStream
    private let output: SCRecordingOutput
    private let outputURL: URL
    private let filterKind: RecordingPlan.FilterKind
    private let clock: any Clock
    private let log: Log?

    private var phase: Phase = .idle
    private var startOutcome: StartOutcome?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishOutcome: FinishOutcome?
    private var finishTimedOut = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var callbackTask: Task<Void, Never>?

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputConfiguration: SCRecordingOutputConfiguration,
        outputURL: URL,
        filterKind: RecordingPlan.FilterKind,
        clock: any Clock,
        log: Log?
    ) {
        (events, eventSink) = AsyncStream.makeStream(of: RecordingSessionEvent.self)
        (callbacks, callbackSink) = AsyncStream.makeStream(of: LiveRecordingCallback.self)
        delegate = LiveRecordingDelegate(sink: callbackSink, clock: clock)
        stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        countsAudio = configuration.capturesAudio
        countsMicrophone = configuration.captureMicrophone
        output = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
        self.outputURL = outputURL
        self.filterKind = filterKind
        self.clock = clock
        self.log = log
    }

    /// Adds the recording output before capture starts (so the first frame is in the file), starts
    /// the stream and waits until the output reports that it is writing.
    func begin() async throws {
        guard phase == .idle else { return }
        phase = .starting
        let callbacks = self.callbacks
        callbackTask = Task { [weak self] in
            for await callback in callbacks {
                guard let self else { return }
                await self.handle(callback)
            }
        }
        do {
            try stream.addRecordingOutput(output)
            try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: counter.queue)
            if countsAudio { try stream.addStreamOutput(counter, type: .audio, sampleHandlerQueue: counter.queue) }
            if countsMicrophone { try stream.addStreamOutput(counter, type: .microphone, sampleHandlerQueue: counter.queue) }
            try await stream.startCapture()
        } catch {
            close()
            throw LiveRecordingSource.startError(for: StreamFailure(error))
        }

        let timeout = Task { [weak self, clock] in
            do {
                try await clock.sleep(seconds: LiveRecordingSource.startTimeout)
            } catch {
                return
            }
            await self?.resolveStart(.timedOut)
        }
        await waitForStart()
        timeout.cancel()

        switch startOutcome {
        case .failed(let failure):
            do {
                try await stream.stopCapture()
            } catch {
                log?.warning("recording: stop after a failed start: \(StreamFailure(error))")
            }
            close()
            throw LiveRecordingSource.startError(for: failure)
        case .timedOut:
            // Frames may simply not have arrived yet (a still screen); the file decides later.
            log?.warning("recording: no start report after \(LiveRecordingSource.startTimeout) s, continuing")
            if phase == .starting { phase = .recording }
        case .started, nil:
            if phase == .starting { phase = .recording }
        }
    }

    public nonisolated var sampleCounts: RecordingSampleCounts { counter.current }

    public func stop() async throws -> URL {
        switch phase {
        case .stopping, .stopped, .idle:
            throw RecordingSourceError.notRecording
        case .starting, .recording, .streamEnded:
            break
        }
        let streamEnded = phase == .streamEnded
        phase = .stopping
        if streamEnded {
            if finishOutcome == nil {
                do {
                    try stream.removeRecordingOutput(output)
                } catch {
                    log?.warning("recording: remove output after the stream ended: \(StreamFailure(error))")
                }
            }
        } else {
            do {
                try await stream.stopCapture()
            } catch {
                log?.warning("recording: stopCapture failed: \(StreamFailure(error))")
            }
        }

        let timeout = Task { [weak self, clock] in
            do {
                try await clock.sleep(seconds: LiveRecordingSource.finishTimeout)
            } catch {
                return
            }
            await self?.finishTimeoutFired()
        }
        await waitForFinish()
        timeout.cancel()

        let outcome = finishOutcome
        close()
        if case .failed(let message) = outcome { throw LiveRecordingError.finishFailed(message) }
        if outcome == nil {
            log?.warning("recording: the file did not report finishing within \(LiveRecordingSource.finishTimeout) s")
        }
        return outputURL
    }

    // MARK: Callbacks

    private func handle(_ callback: LiveRecordingCallback) {
        switch callback {
        case .recordingStarted(let time):
            resolveStart(.started)
            eventSink.yield(.firstFrame(at: time))
        case .recordingFinished:
            resolveFinish(.finished)
        case .recordingFailed(let failure):
            log?.warning("recording: output failed: \(failure)")
            if startOutcome == nil {
                resolveStart(.failed(failure))
            } else if phase == .recording {
                eventSink.yield(.failed(failure.description))
            }
            resolveFinish(.failed(failure.description))
        case .streamStopped(let failure):
            log?.warning("recording: stream stopped: \(failure)")
            if startOutcome == nil {
                resolveStart(.failed(failure))
            } else if phase == .recording {
                phase = .streamEnded
                eventSink.yield(LiveRecordingSource.sessionEvent(for: failure, filterKind: filterKind))
            }
        }
    }

    private func resolveStart(_ outcome: StartOutcome) {
        guard startOutcome == nil else { return }
        startOutcome = outcome
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func waitForStart() async {
        if startOutcome != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func resolveFinish(_ outcome: FinishOutcome) {
        guard finishOutcome == nil else { return }
        finishOutcome = outcome
        releaseFinishWaiters()
    }

    private func finishTimeoutFired() {
        finishTimedOut = true
        releaseFinishWaiters()
    }

    private func releaseFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func waitForFinish() async {
        if finishOutcome != nil || finishTimedOut { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    private func close() {
        phase = .stopped
        eventSink.finish()
        callbackSink.finish()
        callbackTask?.cancel()
        callbackTask = nil
    }
}
