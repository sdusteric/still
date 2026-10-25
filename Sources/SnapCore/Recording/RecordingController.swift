import Foundation

/// Why a recording did not start or could not be finished.
public enum RecordingFailure: Error, Sendable, Hashable, CustomStringConvertible {
    /// The target cannot be recorded (too small, no display).
    case plan(RecordingPlanError)
    /// Less than 2 GB free on the volume holding SNAP_HOME (D68).
    case notEnoughDisk(availableBytes: Int64)
    /// A recording is already counting down, starting, running or finishing.
    case busy
    /// Screen Recording was denied or lapsed at start.
    case permissionDenied
    /// The stream did not start for another reason.
    case startFailed(String)
    /// `item.json` could not be written.
    case history(String)

    public var description: String {
        switch self {
        case .plan(let error): error.description
        case .notEnoughDisk: "Not enough disk space"
        case .busy: "Already recording"
        case .permissionDenied: "Screen Recording permission is off"
        case .startFailed: "Recording could not start"
        case .history(let message): "Recording could not be saved: \(message)"
        }
    }
}

/// One entry of the controller's ordered event log (tests and `snapctl record`).
public struct RecordingEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case countdownTick
        case countdownSkipped
        case cancelled
        case noMicrophone
        case itemWritten
        case started
        case firstFrame
        case stopRequested
        case finished
        case audioMixed
        case posterWritten
        case complete
        case interrupted
        case failed
    }

    public var kind: Kind
    /// Clock time (`Clock.now()`).
    public var time: TimeInterval
    /// The tick number, the item id, the stop reason or an error message.
    public var detail: String?

    public init(kind: Kind, time: TimeInterval, detail: String? = nil) {
        self.kind = kind
        self.time = time
        self.detail = detail
    }
}

/// A finished recording: what the video card shows (design 20.6, D67).
public struct RecordingResult: Sendable, Hashable {
    public var item: CaptureItem
    public var stopReason: RecordingStopReason
    /// The microphone was requested but access is off: the card shows "No microphone" for 4 s.
    public var noMicrophone: Bool
    public var probe: VideoProbeResult

    /// "Stopped: the window closed" and the like, nil for a normal stop.
    public var note: String? { stopReason.cardNote }
    public var isComplete: Bool { item.state == .complete }
}

/// What `start` ended with.
public enum RecordingStartOutcome: Sendable, Hashable {
    case recording(CaptureItem)
    /// Esc during the countdown: nothing was written.
    case cancelled
    case failed(RecordingFailure)
}

/// Runs one screen recording at a time (design 20.4 and 20.6): the countdown, history-first
/// `item.json`, the source, the disk checks, and finishing (probe, audio mix, poster, `complete`
/// or `interrupted`). Every collaborator is injected, so tests and `snapctl record` drive it with
/// `FakeClock`, `FakeRecordingSource`, `FakeDiskSpace` and `FakeMicrophoneAuthorization`.
@MainActor
public final class RecordingController {
    public enum State: Sendable, Hashable {
        case idle
        /// Seconds left, shown in the countdown disc.
        case countdown(Int)
        case starting
        /// Recording since this clock time (the status item timer counts from it).
        case recording(since: TimeInterval)
        /// The timer shows "Saving".
        case finishing
        case done(RecordingResult)
        case failed(RecordingFailure)

        /// Counting down, starting, recording or finishing: a second request stops instead.
        public var isBusy: Bool {
            switch self {
            case .countdown, .starting, .recording, .finishing: true
            case .idle, .done, .failed: false
            }
        }
    }

    private enum CountdownDecision {
        case skip
        case cancel
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Called on every state change, on the main actor.
    public var onStateChange: ((State) -> Void)?
    /// Called for every event as it is logged.
    public var onEvent: ((RecordingEvent) -> Void)?
    /// The ordered event log since the controller was made or `clearEvents()`.
    public private(set) var events: [RecordingEvent] = []
    /// The item being recorded or finished; the sweep must skip it.
    public private(set) var activeItem: CaptureItem?
    /// The plan of the current recording, with the microphone removed when access is off.
    public private(set) var activePlan: RecordingPlan?

    private let clock: any Clock
    private let history: HistoryStore
    private let source: any RecordingSource
    private let diskSpace: any DiskSpaceProbe
    private let microphone: any MicrophoneAuthorizing
    private let fileNamer: FileNamer
    private let log: Log?

    private var session: (any RecordingSession)?
    private var noMicrophone = false
    private var countdownSleep: Task<Void, any Error>?
    private var countdownDecision: CountdownDecision?
    /// `stop()` calls made while the source was starting, resumed once the start succeeds or fails.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventsTask: Task<Void, Never>?
    private var diskTask: Task<Void, Never>?
    private var finishTask: Task<RecordingResult?, Never>?

    public init(
        clock: any Clock,
        history: HistoryStore,
        source: any RecordingSource,
        diskSpace: any DiskSpaceProbe,
        microphone: any MicrophoneAuthorizing,
        fileNamer: FileNamer = FileNamer(),
        log: Log? = nil
    ) {
        self.clock = clock
        self.history = history
        self.source = source
        self.diskSpace = diskSpace
        self.microphone = microphone
        self.fileNamer = fileNamer
        self.log = log
    }

    /// The id the retention sweep must skip, while a recording runs or finishes.
    public var activeItemID: String? { activeItem?.id }

    public func clearEvents() {
        events = []
    }

    // MARK: Starting

    /// The check the HUD runs before Record is offered: nil when a recording may start.
    public func preflight() -> RecordingFailure? {
        if state.isBusy { return .busy }
        do {
            let available = try diskSpace.availableBytes(at: history.directory)
            if available < DiskSpaceLimits.minimumToStart { return .notEnoughDisk(availableBytes: available) }
        } catch {
            // An unreadable volume size does not block a recording; the poll keeps checking.
            log?.warning("recording: cannot read free disk space: \(error)")
        }
        return nil
    }

    /// Counts down (`countdownSeconds` ticks, one per second; 0 starts at once), writes
    /// `item.json` in state `recording`, and starts the source. Returns once the source runs, or
    /// when the countdown was cancelled or the start failed. Return during the countdown is
    /// `skipCountdown()`, Esc is `cancelCountdown()`.
    public func start(plan: RecordingPlan, countdownSeconds: Int, sourceApp: String? = nil) async -> RecordingStartOutcome {
        if let failure = preflight() {
            if failure != .busy { state = .failed(failure) }
            return .failed(failure)
        }
        countdownDecision = nil
        noMicrophone = false

        var remaining = max(countdownSeconds, 0)
        while remaining > 0, countdownDecision == nil {
            state = .countdown(remaining)
            record(.countdownTick, detail: String(remaining))
            let sleep = Task { [clock] in try await clock.sleep(seconds: 1) }
            countdownSleep = sleep
            do {
                try await sleep.value
            } catch {
                // Cancelled by Return or Esc; the decision says which.
            }
            countdownSleep = nil
            remaining -= 1
        }
        if countdownDecision == .cancel {
            record(.cancelled)
            state = .idle
            return .cancelled
        }
        if countdownDecision == .skip { record(.countdownSkipped) }
        countdownDecision = nil
        let outcome = await begin(plan: plan, sourceApp: sourceApp ?? plan.target.sourceApp)
        // A quit or sleep during the start waits for this outcome, then finishes the file.
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
        return outcome
    }

    /// Return during the countdown: start now.
    public func skipCountdown() {
        guard case .countdown = state else { return }
        countdownDecision = .skip
        countdownSleep?.cancel()
    }

    /// Esc during the countdown: cancel, writing nothing.
    public func cancelCountdown() {
        guard case .countdown = state else { return }
        countdownDecision = .cancel
        countdownSleep?.cancel()
    }

    private func begin(plan requested: RecordingPlan, sourceApp: String?) async -> RecordingStartOutcome {
        state = .starting
        var plan = requested
        if plan.capturesMicrophone, !microphone.status().isAuthorized {
            // Recordings proceed without the microphone; access is only asked for from Settings or the HUD.
            plan.capturesMicrophone = false
            plan.microphoneDeviceID = nil
            noMicrophone = true
            record(.noMicrophone)
        }

        let date = clock.date()
        let fileName = fileNamer.fileName(date: date, app: sourceApp, fileExtension: "mp4") { _ in false }
        let video = NewVideo(
            fileName: fileName, mode: plan.target.mode, scale: plan.scale, sourceApp: sourceApp,
            screenRect: plan.screenRect, pixelSize: plan.pixelSize, codec: plan.codec.fourCC,
            fps: Double(plan.fps), audio: plan.audioSources
        )
        let item: CaptureItem
        do {
            item = try history.add(video: video, createdAt: date)
        } catch {
            log?.error("recording: cannot write item.json: \(error)")
            return fail(.history(String(describing: error)))
        }
        record(.itemWritten, detail: item.id)
        plan.outputURL = item.originalURL
        activeItem = item
        activePlan = plan

        let session: any RecordingSession
        do {
            session = try await source.start(plan)
        } catch {
            // A recording that never got a frame leaves nothing behind (design 20.4 step 5).
            removeFolder(of: item)
            activeItem = nil
            activePlan = nil
            log?.error("recording: start failed id=\(item.id): \(error)")
            if let sourceError = error as? RecordingSourceError, sourceError == .permissionDenied {
                return fail(.permissionDenied)
            }
            return fail(.startFailed(String(describing: error)))
        }
        self.session = session
        let started = clock.now()
        state = .recording(since: started)
        record(.started, detail: item.id)
        log?.info("recording start id=\(item.id) \(plan.logSummary)")
        watch(session)
        watchDisk()
        return .recording(item)
    }

    private func fail(_ failure: RecordingFailure) -> RecordingStartOutcome {
        record(.failed, detail: failure.description)
        state = .failed(failure)
        return .failed(failure)
    }

    // MARK: Stopping

    /// Stops and finishes the recording: by the status item (`.user`), Cmd+Shift+5 (`.hotkey`),
    /// the system, low disk, quit or sleep. During the countdown it cancels. While the source is
    /// starting it waits for the start, then finishes the file (nil when the start failed). A
    /// second call while finishing waits for the same result. Returns nil when there was nothing
    /// to finish.
    @discardableResult
    public func stop(reason: RecordingStopReason) async -> RecordingResult? {
        if let finishTask { return await finishTask.value }
        switch state {
        case .countdown:
            cancelCountdown()
            return nil
        case .starting:
            await withCheckedContinuation { startWaiters.append($0) }
            return await stop(reason: reason)
        case .recording:
            break
        case .idle, .finishing, .done, .failed:
            return nil
        }
        guard let session, let item = activeItem, let plan = activePlan else { return nil }
        let task = Task { [weak self] () -> RecordingResult? in
            guard let self else { return nil }
            return await self.finish(session: session, item: item, plan: plan, reason: reason)
        }
        finishTask = task
        return await task.value
    }

    /// Cancel Recording from the status menu: stops the stream and moves the item to the Trash
    /// (design 20.4 step 6). During the countdown it is Esc.
    public func cancelRecording() async {
        if case .countdown = state {
            cancelCountdown()
            return
        }
        guard finishTask == nil, case .recording = state, let session, let item = activeItem else { return }
        let task = Task { [weak self] () -> RecordingResult? in
            guard let self else { return nil }
            await self.discard(session: session, item: item)
            return nil
        }
        finishTask = task
        _ = await task.value
    }

    private func finish(
        session: any RecordingSession,
        item: CaptureItem,
        plan: RecordingPlan,
        reason: RecordingStopReason
    ) async -> RecordingResult? {
        state = .finishing
        record(.stopRequested, detail: reason.rawValue)
        stopWatching()

        var url = item.originalURL
        do {
            url = try await session.stop()
            record(.finished, detail: url.lastPathComponent)
        } catch {
            // Keep whatever reached the file; the probe decides complete or interrupted.
            record(.failed, detail: String(describing: error))
            log?.warning("recording: stop failed id=\(item.id): \(error)")
        }

        var probe = await VideoProbe.probe(url, countFrames: false)
        if probe.playable, probe.audioTrackCount >= 2 {
            do {
                if try await AudioMixExport.mixAudioIfNeeded(at: url) {
                    record(.audioMixed)
                    probe = await VideoProbe.probe(url, countFrames: false)
                }
            } catch {
                log?.warning("recording: audio mix failed id=\(item.id), keeping both tracks: \(error)")
            }
        }

        var finished = FinishedVideo(durationSeconds: probe.durationSeconds, state: .interrupted)
        if probe.playable {
            var poster: Data?
            do {
                poster = try await PosterWriter.posterPNG(of: url, duration: probe.durationSeconds, scale: plan.scale)
            } catch {
                log?.warning("recording: no poster for id=\(item.id): \(error)")
            }
            finished = FinishedVideo(
                durationSeconds: probe.durationSeconds, pixelSize: probe.pixelSize ?? plan.pixelSize,
                codec: probe.codec ?? plan.codec.fourCC, fps: Double(plan.fps), audio: plan.audioSources,
                posterPNGData: poster, state: .complete
            )
        }

        let stored: CaptureItem
        do {
            stored = try history.finishVideo(id: item.id, finished)
        } catch {
            log?.error("recording: cannot finish item.json id=\(item.id): \(error)")
            record(.failed, detail: String(describing: error))
            reset()
            state = .failed(.history(String(describing: error)))
            return nil
        }
        if finished.posterPNGData != nil { record(.posterWritten, detail: stored.posterURL?.lastPathComponent) }
        record(stored.state == .complete ? .complete : .interrupted, detail: stored.id)
        log?.info(
            "recording stop id=\(stored.id) duration=\(String(format: "%.1f", probe.durationSeconds)) "
                + "bytes=\(VideoProbe.fileSize(url)) reason=\(reason.rawValue) state=\(stored.state.rawValue)"
        )
        let result = RecordingResult(item: stored, stopReason: reason, noMicrophone: noMicrophone, probe: probe)
        reset()
        state = .done(result)
        return result
    }

    private func discard(session: any RecordingSession, item: CaptureItem) async {
        state = .finishing
        record(.stopRequested, detail: "cancel")
        stopWatching()
        do {
            _ = try await session.stop()
        } catch {
            log?.warning("recording: stop before cancel failed id=\(item.id): \(error)")
        }
        do {
            try history.trash(id: item.id)
        } catch {
            log?.error("recording: cannot move id=\(item.id) to the Trash: \(error)")
        }
        record(.cancelled, detail: item.id)
        log?.info("recording cancel id=\(item.id)")
        reset()
        state = .idle
    }

    private func reset() {
        session = nil
        activeItem = nil
        activePlan = nil
        finishTask = nil
    }

    // MARK: Watching

    private func watch(_ session: any RecordingSession) {
        let events = session.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .firstFrame(let time):
                    self.record(.firstFrame, time: time)
                    if case .recording(let since) = self.state {
                        self.log?.info("recording first frame after \(String(format: "%.3f", time - since)) s")
                    }
                case .stoppedBySystem(let reason):
                    Task { [weak self] in _ = await self?.stop(reason: reason) }
                case .failed(let message):
                    self.record(.failed, detail: message)
                    Task { [weak self] in _ = await self?.stop(reason: .streamFailed) }
                }
            }
        }
    }

    private func watchDisk() {
        diskTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(seconds: DiskSpaceLimits.pollInterval)
                } catch {
                    return
                }
                guard let self else { return }
                if self.diskIsLow() {
                    _ = await self.stop(reason: .diskFull)
                    return
                }
            }
        }
    }

    private func diskIsLow() -> Bool {
        do {
            return try diskSpace.availableBytes(at: history.directory) < DiskSpaceLimits.minimumWhileRecording
        } catch {
            log?.warning("recording: cannot read free disk space: \(error)")
            return false
        }
    }

    private func stopWatching() {
        diskTask?.cancel()
        diskTask = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    // MARK: Helpers

    private func record(_ kind: RecordingEvent.Kind, time: TimeInterval? = nil, detail: String? = nil) {
        let event = RecordingEvent(kind: kind, time: time ?? clock.now(), detail: detail)
        events.append(event)
        onEvent?(event)
    }

    private func removeFolder(of item: CaptureItem) {
        do {
            try history.remove(id: item.id)
        } catch {
            log?.error("recording: cannot remove the empty folder of id=\(item.id): \(error)")
        }
    }

    /// The status item timer text: `0:42`, `12:05`, `1:02:05` after an hour.
    public nonisolated static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
