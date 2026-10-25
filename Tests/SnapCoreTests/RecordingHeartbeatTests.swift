import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (or the temp dir), removed by its exact path when done.
private final class HeartbeatScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "heartbeat-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A leftover scratch dir inside a temp dir is harmless.
        }
    }
}

/// The recording controller with the fake recorder and a fake clock, stepped one heartbeat at a time.
@MainActor
private final class HeartbeatHarness {
    let scratch: HeartbeatScratch
    let clock = FakeClock()
    let source: FakeRecordingSource
    let controller: RecordingController
    var stalls: [RecordingStall?] = []

    init() throws {
        scratch = try HeartbeatScratch()
        let history = HistoryStore(
            directory: scratch.url.appending(path: "history", directoryHint: .isDirectory), clock: clock,
            trasher: FakeTrasher(directory: scratch.url.appending(path: "trash", directoryHint: .isDirectory))
        )
        source = FakeRecordingSource(clock: clock, options: FakeRecordingSource.Options(frames: 6))
        controller = RecordingController(
            clock: clock, history: history, source: source, diskSpace: FakeDiskSpace(),
            microphone: FakeMicrophoneAuthorization(status: .authorized)
        )
        controller.onStallChange = { [weak self] stall in self?.stalls.append(stall) }
    }

    func plan(audio: [AudioSource] = []) throws -> RecordingPlan {
        var settings = Settings()
        settings.recording.systemAudio = audio.contains(.system)
        settings.recording.microphone = audio.contains(.microphone)
        return try RecordingPlan.make(
            target: .area(CGRect(x: 100, y: 100, width: 64, height: 40)), displays: [DisplayInfo(spec: "2560x1440@2")!],
            settings: settings
        )
    }

    var session: FakeRecordingSession? { source.lastSession }

    /// Starts with no countdown and waits until the frames are written and both the disk poll and
    /// the heartbeat are asleep on the clock.
    func start(audio: [AudioSource] = []) async throws {
        let outcome = await controller.start(plan: try plan(audio: audio), countdownSeconds: 0)
        guard case .recording = outcome else {
            Issue.record("expected a recording, got \(outcome)")
            throw CancellationError()
        }
        await session?.waitUntilWritten()
        try await waitUntil { self.clock.sleeperCount == 2 }
    }

    /// One second of recording: `deliver` runs first (the samples of that second), then the clock
    /// moves and the heartbeat reads the counts.
    func second(_ deliver: (FakeRecordingSession) -> Void = { _ in }) async throws {
        if let session { deliver(session) }
        clock.advance(by: 1)
        try await waitUntil { self.clock.sleeperCount == 2 }
        // The heartbeat has run once it is asleep again; give its main-actor hop a turn.
        await Task.yield()
    }

    func events(_ kind: RecordingEvent.Kind) -> [RecordingEvent] { controller.events.filter { $0.kind == kind } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("condition did not hold in time")
}

@Suite struct RecordingHeartbeatTests {
    // MARK: The pure heartbeat

    @Test func frameCountsThatKeepMovingNeverStall() {
        var heartbeat = RecordingHeartbeat(start: 0, audio: [.system, .microphone])
        for second in 1...20 {
            let counts = RecordingSampleCounts(videoFrames: second * 30, systemAudio: second * 50, microphone: second * 50)
            #expect(heartbeat.observe(counts, at: Double(second)) == nil)
        }
    }

    @Test func threeSecondsWithoutAFrameIsAStallAndTheSecondsGrow() {
        var heartbeat = RecordingHeartbeat(start: 10, audio: [])
        #expect(heartbeat.observe(RecordingSampleCounts(videoFrames: 30), at: 11) == nil)
        #expect(heartbeat.observe(RecordingSampleCounts(videoFrames: 60), at: 12) == nil)
        #expect(heartbeat.observe(RecordingSampleCounts(videoFrames: 60), at: 14) == nil, "2 s is under the threshold")
        let stall = heartbeat.observe(RecordingSampleCounts(videoFrames: 60), at: 15)
        #expect(stall?.track == .video)
        #expect(stall?.seconds == 3)
        #expect(stall?.lastSampleElapsed == 2)
        #expect(heartbeat.observe(RecordingSampleCounts(videoFrames: 60), at: 17)?.message
            == "Recording stalled: no new frames for 5 s")
        #expect(heartbeat.observe(RecordingSampleCounts(videoFrames: 61), at: 18) == nil, "a new frame ends the stall")
    }

    @Test func aStreamThatNeverDeliversStallsThreeSecondsAfterTheStart() {
        var heartbeat = RecordingHeartbeat(start: 0, audio: [])
        #expect(heartbeat.observe(RecordingSampleCounts(), at: 2) == nil)
        #expect(heartbeat.observe(RecordingSampleCounts(), at: 3)?.cardNote == "Frames stopped at 0:00")
    }

    @Test func audioIsWatchedOnlyWhenThePlanRecordsIt() {
        var silent = RecordingHeartbeat(start: 0, audio: [])
        var withMicrophone = RecordingHeartbeat(start: 0, audio: [.microphone])
        for second in 1...6 {
            let counts = RecordingSampleCounts(videoFrames: second * 30, systemAudio: 0, microphone: min(second, 2) * 50)
            #expect(silent.observe(counts, at: Double(second)) == nil)
            let stall = withMicrophone.observe(counts, at: Double(second))
            if second < 5 {
                #expect(stall == nil)
            } else {
                #expect(stall?.track == .microphone)
                #expect(stall?.message == "Recording stalled: no microphone audio for \(second - 2) s")
                #expect(stall?.cardNote == "Microphone stopped at 0:02")
            }
        }
    }

    @Test func videoIsReportedBeforeAudioWhenBothStop() {
        var heartbeat = RecordingHeartbeat(start: 0, audio: [.system])
        let stall = heartbeat.observe(RecordingSampleCounts(videoFrames: 0, systemAudio: 0), at: 4)
        #expect(stall?.track == .video)
        let audioOnly = heartbeat.observe(RecordingSampleCounts(videoFrames: 9, systemAudio: 0), at: 5)
        #expect(audioOnly?.track == .systemAudio)
        #expect(audioOnly?.message == "Recording stalled: no system audio for 5 s")
    }

    // MARK: Through the controller and the fake recorder

    @MainActor
    @Test func theControllerWarnsAfterThreeSilentSecondsAndKeepsRecording() async throws {
        let harness = try HeartbeatHarness()
        try await harness.start()
        for _ in 0..<3 { try await harness.second { $0.deliver(video: 30) } }
        #expect(harness.controller.stall == nil)
        #expect(harness.events(.stalled).isEmpty)

        // No frames from here on: the warning comes at the third quiet second and then counts up.
        try await harness.second()
        try await harness.second()
        #expect(harness.controller.stall == nil, "2 s without a frame is not a stall yet")
        try await harness.second()
        #expect(harness.controller.stall?.message == "Recording stalled: no new frames for 3 s")
        try await harness.second()
        try await harness.second()
        #expect(harness.controller.stall?.message == "Recording stalled: no new frames for 5 s")
        #expect(harness.events(.stalled).count == 1, "the stall is logged once, not every second")
        #expect(harness.controller.state == .recording(since: 0), "a stall never stops the recording")

        try await harness.second { $0.deliver(video: 30) }
        #expect(harness.controller.stall == nil)
        #expect(harness.events(.resumed).count == 1)
        #expect(harness.stalls.last == .some(nil))
    }

    @MainActor
    @Test func stoppingWhileStalledKeepsTheFileAndNotesWhereFramesStopped() async throws {
        let harness = try HeartbeatHarness()
        try await harness.start()
        try await harness.second { $0.deliver(video: 30) }
        try await harness.second { $0.deliver(video: 30) }
        for _ in 0..<4 { try await harness.second() }
        #expect(harness.controller.stall?.track == .video)

        let result = try #require(await harness.controller.stop(reason: .user))
        #expect(result.isComplete, "whatever was written is kept and plays")
        #expect(result.stall?.track == .video)
        #expect(result.note == "Frames stopped at 0:02")
        #expect(harness.controller.stall == nil, "the warning ends with the recording")
        let file = result.item.originalURL.path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @MainActor
    @Test func aMicrophoneThatStopsIsReportedWhileFramesKeepComing() async throws {
        let harness = try HeartbeatHarness()
        try await harness.start(audio: [.microphone])
        try await harness.second { $0.deliver(video: 30, microphone: 40) }
        for _ in 0..<3 { try await harness.second { $0.deliver(video: 30, microphone: 0) } }
        #expect(harness.controller.stall?.track == .microphone)
        #expect(harness.controller.stall?.message == "Recording stalled: no microphone audio for 3 s")
        let result = try #require(await harness.controller.stop(reason: .user))
        #expect(result.note == "Microphone stopped at 0:01")
    }

    @MainActor
    @Test func withoutAudioOnlyFramesAreWatched() async throws {
        let harness = try HeartbeatHarness()
        try await harness.start()
        for _ in 0..<6 { try await harness.second { $0.deliver(video: 30, systemAudio: 0, microphone: 0) } }
        #expect(harness.controller.stall == nil)
        #expect(harness.events(.stalled).isEmpty)
        _ = await harness.controller.stop(reason: .user)
    }

    @Test func theRecordingMenuShowsTheStallFirst() {
        let stall = RecordingStall(track: .video, seconds: 5, lastSampleElapsed: 12)
        let model = RecordingMenuModel(RecordingMenuInput(target: .area, size: CGSize(width: 640, height: 400), fps: 30,
                                                          format: .h264, stall: stall))
        #expect(model.items.first?.kind == .status)
        #expect(model.items.first?.title == "Recording stalled: no new frames for 5 s")
        #expect(model.items.first?.isEnabled == false)
        #expect(model.item(.stopRecording) != nil)
        let calm = RecordingMenuModel(RecordingMenuInput(target: .area, size: CGSize(width: 640, height: 400), fps: 30, format: .h264))
        #expect(calm.items.first?.id == .stopRecording)
    }
}
