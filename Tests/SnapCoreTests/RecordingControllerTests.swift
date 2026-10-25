import CoreGraphics
import Foundation
import SnapCore
import Synchronization
import Testing

/// A fresh SNAP_HOME-like directory with history and a fake Trash, removed by its exact path.
private final class RecordingScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "recording-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A leftover scratch dir inside a temp dir is harmless.
        }
    }

    var history: URL { url.appending(path: "history", directoryHint: .isDirectory) }
    var trash: URL { url.appending(path: "fake-trash", directoryHint: .isDirectory) }

    func historyFolders() throws -> [String] {
        guard FileManager.default.fileExists(atPath: history.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: history.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }.sorted()
    }
}

/// Reads `item.json` when the recorder starts, to prove the history-first rule.
private final class ItemCheckingSource: RecordingSource {
    let inner: FakeRecordingSource
    private let seen = Mutex<Data?>(nil)

    init(inner: FakeRecordingSource) {
        self.inner = inner
    }

    var itemAtStart: [String: Any]? {
        guard let data = seen.withLock({ $0 }) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    func start(_ plan: RecordingPlan) async throws -> any RecordingSession {
        if let output = plan.outputURL {
            let file = output.deletingLastPathComponent().appending(path: HistoryStore.itemFileName)
            let data = try Data(contentsOf: file)
            seen.withLock { $0 = data }
        }
        return try await inner.start(plan)
    }
}

/// Holds `start` until `release()`, so a test can stop while the controller is `.starting`.
private final class GatedSource: RecordingSource {
    let inner: FakeRecordingSource
    private let gate = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    init(inner: FakeRecordingSource) {
        self.inner = inner
    }

    func release() {
        let waiters = gate.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func start(_ plan: RecordingPlan) async throws -> any RecordingSession {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let open = gate.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(waiter)
                return false
            }
            if open { waiter.resume() }
        }
        return try await inner.start(plan)
    }
}

@MainActor
private final class Harness {
    let scratch: RecordingScratch
    let clock = FakeClock()
    let history: HistoryStore
    let trasher: FakeTrasher
    let source: FakeRecordingSource
    let disk: FakeDiskSpace
    let microphone: FakeMicrophoneAuthorization
    let controller: RecordingController
    var states: [RecordingController.State] = []

    init(
        options: FakeRecordingSource.Options = FakeRecordingSource.Options(frames: 6),
        disk: Int64 = FakeDiskSpace.plenty,
        microphone: MicrophoneAccess = .authorized,
        wrap: ((FakeRecordingSource) -> any RecordingSource)? = nil
    ) throws {
        scratch = try RecordingScratch()
        trasher = FakeTrasher(directory: scratch.trash)
        history = HistoryStore(directory: scratch.history, clock: clock, trasher: trasher)
        source = FakeRecordingSource(clock: clock, options: options)
        self.disk = FakeDiskSpace(availableBytes: disk)
        self.microphone = FakeMicrophoneAuthorization(status: microphone)
        controller = RecordingController(
            clock: clock, history: history, source: wrap?(source) ?? source, diskSpace: self.disk,
            microphone: self.microphone
        )
        controller.onStateChange = { [weak self] state in self?.states.append(state) }
    }

    /// A 64 x 40 point area at 2x: 128 x 80 px, small enough to encode in a few milliseconds.
    func plan(_ change: (inout Settings) -> Void = { _ in }) throws -> RecordingPlan {
        var settings = Settings()
        change(&settings)
        return try RecordingPlan.make(
            target: .area(CGRect(x: 100, y: 100, width: 64, height: 40)), displays: [DisplayInfo(spec: "2560x1440@2")!],
            settings: settings, excludedWindowIDs: [11]
        )
    }

    var kinds: [RecordingEvent.Kind] { controller.events.map(\.kind) }

    func events(_ kind: RecordingEvent.Kind) -> [RecordingEvent] { controller.events.filter { $0.kind == kind } }

    /// Starts with no countdown and waits until the fake source has written its frames.
    func startRecording(_ plan: RecordingPlan) async throws -> CaptureItem {
        let outcome = await controller.start(plan: plan, countdownSeconds: 0)
        guard case .recording(let item) = outcome else {
            Issue.record("expected a recording, got \(outcome)")
            throw CancellationError()
        }
        await source.lastSession?.waitUntilWritten()
        try await waitUntil { !self.events(.firstFrame).isEmpty }
        return item
    }
}

/// Polls on the main actor until `condition` holds, up to 10 s of wall time.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("condition did not hold in time")
}

@MainActor
@Suite struct RecordingControllerTests {
    @Test func theCountdownTicksOncePerSecondOfTheClockThenRecords() async throws {
        let harness = try Harness()
        let plan = try harness.plan()
        let start = Task { await harness.controller.start(plan: plan, countdownSeconds: 3) }
        for _ in 0..<3 {
            try await waitUntil { harness.clock.sleeperCount > 0 }
            harness.clock.advance(by: 1)
        }
        let outcome = await start.value
        guard case .recording = outcome else {
            Issue.record("expected recording, got \(outcome)")
            return
        }
        let ticks = harness.events(.countdownTick)
        #expect(ticks.map(\.detail) == ["3", "2", "1"])
        #expect(ticks.map(\.time) == [0, 1, 2])
        #expect(harness.states.prefix(5) == [.countdown(3), .countdown(2), .countdown(1), .starting, .recording(since: 3)])
        await harness.source.lastSession?.waitUntilWritten()
        try await waitUntil { !harness.events(.firstFrame).isEmpty }
        #expect(try #require(harness.events(.firstFrame).first).time >= 3)
        await harness.controller.stop(reason: .user)
    }

    @Test func returnSkipsTheRestOfTheCountdown() async throws {
        let harness = try Harness()
        let plan = try harness.plan()
        let start = Task { await harness.controller.start(plan: plan, countdownSeconds: 5) }
        try await waitUntil { harness.clock.sleeperCount > 0 }
        harness.controller.skipCountdown()
        let outcome = await start.value
        guard case .recording = outcome else {
            Issue.record("expected recording, got \(outcome)")
            return
        }
        #expect(harness.events(.countdownTick).count == 1)
        #expect(harness.kinds.contains(.countdownSkipped))
        #expect(harness.clock.now() == 0)
        await harness.source.lastSession?.waitUntilWritten()
        await harness.controller.stop(reason: .user)
    }

    @Test func escDuringTheCountdownCancelsAndWritesNothing() async throws {
        let harness = try Harness()
        let plan = try harness.plan()
        let start = Task { await harness.controller.start(plan: plan, countdownSeconds: 3) }
        try await waitUntil { harness.clock.sleeperCount > 0 }
        harness.clock.advance(by: 1)
        try await waitUntil { harness.controller.state == .countdown(2) && harness.clock.sleeperCount > 0 }
        harness.controller.cancelCountdown()
        #expect(await start.value == .cancelled)
        #expect(harness.controller.state == .idle)
        #expect(try harness.scratch.historyFolders().isEmpty)
        #expect(harness.source.startCount == 0)
        #expect(harness.kinds == [.countdownTick, .countdownTick, .cancelled])
    }

    @Test func itemJSONIsWrittenInStateRecordingBeforeTheSourceStarts() async throws {
        var checking: ItemCheckingSource?
        let harness = try Harness { inner in
            let source = ItemCheckingSource(inner: inner)
            checking = source
            return source
        }
        let item = try await harness.startRecording(try harness.plan())
        let seen = try #require(checking?.itemAtStart)
        #expect(seen["kind"] as? String == "video")
        #expect(seen["state"] as? String == "recording")
        #expect(seen["id"] as? String == item.id)
        #expect(item.kind == .video)
        #expect(item.state == .recording)
        #expect(item.originalURL.pathExtension == "mp4")
        #expect(harness.controller.activeItemID == item.id)
        let kinds = harness.kinds
        let written = try #require(kinds.firstIndex(of: .itemWritten))
        let started = try #require(kinds.firstIndex(of: .started))
        #expect(written < started)
        await harness.controller.stop(reason: .user)
    }

    @Test func stopFromTheStatusItemWritesThePosterAndMarksComplete() async throws {
        let harness = try Harness(options: FakeRecordingSource.Options(frames: 30))
        let item = try await harness.startRecording(try harness.plan())
        let result = try #require(await harness.controller.stop(reason: .user))
        #expect(result.item.id == item.id)
        #expect(result.item.state == .complete)
        #expect(result.stopReason == .user)
        #expect(result.note == nil)
        #expect(!result.noMicrophone)
        #expect(abs((result.item.durationSeconds ?? 0) - 1) < 0.01)
        #expect(result.item.pixelSize == PixelSize(width: 128, height: 80))
        #expect(result.item.codec == "avc1")
        #expect(result.item.fps == 30)
        #expect(result.item.screenRect == CGRect(x: 100, y: 100, width: 64, height: 40))
        let poster = try #require(result.item.posterURL)
        let image = try PNGReader.read(poster)
        #expect(image.pixelWidth == 128)
        #expect(image.pixelHeight == 80)
        #expect(try harness.history.item(id: item.id)?.state == .complete)
        #expect(harness.controller.state == .done(result))
        #expect(harness.controller.activeItemID == nil)
        let kinds = harness.kinds
        #expect(kinds == [.itemWritten, .started, .firstFrame, .stopRequested, .finished, .posterWritten, .complete])
    }

    @Test func cmdShiftFiveStopsWithTheHotkeyReason() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording(try harness.plan())
        let result = try #require(await harness.controller.stop(reason: .hotkey))
        #expect(result.stopReason == .hotkey)
        #expect(result.isComplete)
        #expect(harness.events(.stopRequested).first?.detail == "hotkey")
        // A second stop after finishing has nothing to do.
        #expect(await harness.controller.stop(reason: .hotkey) == nil)
    }

    @Test func aStartFailureRemovesTheEmptyFolder() async throws {
        let harness = try Harness(options: FakeRecordingSource.Options(failOnStart: true))
        let outcome = await harness.controller.start(plan: try harness.plan(), countdownSeconds: 0)
        guard case .failed(.startFailed) = outcome else {
            Issue.record("expected startFailed, got \(outcome)")
            return
        }
        #expect(try harness.scratch.historyFolders().isEmpty)
        #expect(harness.kinds == [.itemWritten, .failed])

        harness.source.options = FakeRecordingSource.Options(failOnStart: true, startError: .permissionDenied)
        #expect(await harness.controller.start(plan: try harness.plan(), countdownSeconds: 0) == .failed(.permissionDenied))
        #expect(try harness.scratch.historyFolders().isEmpty)
        #expect(harness.controller.state == .failed(.permissionDenied))
    }

    @Test func aMidStreamSystemStopKeepsTheFileAndSaysWhy() async throws {
        let harness = try Harness(
            options: FakeRecordingSource.Options(frames: 30, stopAfterFrames: 9, systemStopReason: .windowClosed)
        )
        let item = try await harness.startRecording(try harness.plan())
        try await waitUntil {
            if case .done = harness.controller.state { return true }
            return false
        }
        guard case .done(let result) = harness.controller.state else { return }
        #expect(result.item.id == item.id)
        #expect(result.item.state == .complete)
        #expect(result.stopReason == .windowClosed)
        #expect(result.note == "Stopped: the window closed")
        #expect(abs((result.item.durationSeconds ?? 0) - 0.3) < 0.01)
        #expect(RecordingStopReason.displayDisconnected.cardNote == "Stopped: the display was disconnected")
    }

    @Test func lessThanTwoGigabytesFreeRefusesToStart() async throws {
        let harness = try Harness(disk: 1_900 * 1024 * 1024)
        #expect(harness.controller.preflight() == .notEnoughDisk(availableBytes: 1_900 * 1024 * 1024))
        let outcome = await harness.controller.start(plan: try harness.plan(), countdownSeconds: 3)
        #expect(outcome == .failed(.notEnoughDisk(availableBytes: 1_900 * 1024 * 1024)))
        #expect(harness.source.startCount == 0)
        #expect(try harness.scratch.historyFolders().isEmpty)
        #expect(harness.events(.countdownTick).isEmpty)
        #expect(RecordingFailure.notEnoughDisk(availableBytes: 0).description == "Not enough disk space")
    }

    @Test func lowDiskWhileRecordingStopsCleanlyAtTheNextFiveSecondCheck() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording(try harness.plan())
        try await waitUntil { harness.clock.sleeperCount > 0 }
        // 600 MB is still enough: the check passes and the recording goes on.
        harness.disk.available = 600 * 1024 * 1024
        harness.clock.advance(by: 4.9)
        #expect(harness.disk.checkCount == 1)
        harness.clock.advance(by: 0.1)
        try await waitUntil { harness.disk.checkCount == 2 && harness.clock.sleeperCount > 0 }
        #expect(harness.controller.state == .recording(since: 0))
        harness.disk.available = 400 * 1024 * 1024
        harness.clock.advance(by: 5)
        try await waitUntil {
            if case .done = harness.controller.state { return true }
            return false
        }
        guard case .done(let result) = harness.controller.state else { return }
        #expect(result.stopReason == .diskFull)
        #expect(result.note == "Stopped: disk almost full")
        #expect(result.item.state == .complete)
    }

    @Test func microphoneDeniedRecordsWithoutItAndReportsNoMicrophone() async throws {
        let harness = try Harness(microphone: .denied)
        let plan = try harness.plan {
            $0.recording.microphone = true
            $0.recording.microphoneDeviceID = "BuiltInMicrophoneDevice"
        }
        _ = try await harness.startRecording(plan)
        let started = try #require(harness.source.lastSession?.plan)
        #expect(!started.capturesMicrophone)
        #expect(started.microphoneDeviceID == nil)
        let result = try #require(await harness.controller.stop(reason: .user))
        #expect(result.noMicrophone)
        #expect(result.item.audio.isEmpty)
        #expect(result.probe.audioTrackCount == 0)
        #expect(harness.kinds.contains(.noMicrophone))
        // A recording start never asks for access.
        #expect(harness.microphone.requestCount == 0)
    }

    @Test func systemAudioAndMicrophoneEndInOneMixedTrack() async throws {
        let harness = try Harness(options: FakeRecordingSource.Options(frames: 15))
        let plan = try harness.plan {
            $0.recording.systemAudio = true
            $0.recording.microphone = true
        }
        _ = try await harness.startRecording(plan)
        let result = try #require(await harness.controller.stop(reason: .user))
        #expect(result.item.audio == [.system, .microphone])
        #expect(result.probe.audioTrackCount == 1)
        #expect(harness.kinds.contains(.audioMixed))
        #expect(await VideoProbe.probe(result.item.originalURL).audioTrackCount == 1)
    }

    @Test func quitAndSleepFinishTheFile() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording(try harness.plan())
        let quit = try #require(await harness.controller.stop(reason: .quit))
        #expect(quit.item.state == .complete)
        #expect(quit.note == nil)

        _ = try await harness.startRecording(try harness.plan())
        let sleep = try #require(await harness.controller.stop(reason: .sleep))
        #expect(sleep.item.state == .complete)
        #expect(sleep.item.id != quit.item.id)
        #expect(try harness.history.allItems().filter { $0.state == .complete }.count == 2)
    }

    @Test func quitWhileTheSourceIsStartingWaitsForTheStartThenFinishesTheFile() async throws {
        var gated: GatedSource?
        let harness = try Harness { source in
            let wrapper = GatedSource(inner: source)
            gated = wrapper
            return wrapper
        }
        let gate = try #require(gated)
        let plan = try harness.plan()
        let start = Task { await harness.controller.start(plan: plan, countdownSeconds: 0) }
        try await waitUntil { harness.controller.state == .starting && !harness.events(.itemWritten).isEmpty }
        let quit = Task { await harness.controller.stop(reason: .quit) }
        // The quit is waiting: nothing has finished while the source is still starting.
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(harness.controller.state == .starting)
        gate.release()
        guard case .recording(let item) = await start.value else {
            Issue.record("expected the start to succeed")
            return
        }
        let result = try #require(await quit.value)
        #expect(result.item.id == item.id)
        #expect(result.item.state == .complete)
        #expect(result.stopReason == .quit)
        #expect(try harness.history.item(id: item.id)?.state == .complete)
        #expect(harness.kinds.filter { $0 == .stopRequested }.count == 1)
    }

    @Test func sleepWhileTheSourceIsStartingReturnsNilWhenTheStartFails() async throws {
        var gated: GatedSource?
        let harness = try Harness(options: FakeRecordingSource.Options(frames: 6, failOnStart: true)) { source in
            let wrapper = GatedSource(inner: source)
            gated = wrapper
            return wrapper
        }
        let gate = try #require(gated)
        let plan = try harness.plan()
        let start = Task { await harness.controller.start(plan: plan, countdownSeconds: 0) }
        try await waitUntil { harness.controller.state == .starting && !harness.events(.itemWritten).isEmpty }
        let sleep = Task { await harness.controller.stop(reason: .sleep) }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.release()
        guard case .failed = await start.value else {
            Issue.record("expected the start to fail")
            return
        }
        #expect(await sleep.value == nil)
        #expect(try harness.scratch.historyFolders().isEmpty)
    }

    @Test func aKilledRecordingStaysRecordingAndRecoversAsInterrupted() async throws {
        let harness = try Harness(options: FakeRecordingSource.Options(frames: 30, killAfterFrames: 5))
        let item = try await harness.startRecording(try harness.plan())
        #expect(harness.source.lastSession?.phase == .killed)
        #expect(try harness.history.item(id: item.id)?.state == .recording)
        #expect(try harness.history.markInterrupted() == [item.id])
        #expect(try harness.history.item(id: item.id)?.state == .interrupted)
        #expect(await VideoProbe.probe(item.originalURL).playable == false)
    }

    @Test func cancelRecordingMovesTheItemToTheTrash() async throws {
        let harness = try Harness()
        let item = try await harness.startRecording(try harness.plan())
        await harness.controller.cancelRecording()
        #expect(harness.controller.state == .idle)
        #expect(harness.trasher.trashed.map(\.lastPathComponent) == [item.id])
        #expect(try harness.scratch.historyFolders().isEmpty)
        #expect(harness.kinds.last == .cancelled)
    }

    @Test func aSecondStartWhileRecordingIsRefused() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording(try harness.plan())
        #expect(await harness.controller.start(plan: try harness.plan(), countdownSeconds: 0) == .failed(.busy))
        #expect(harness.controller.state == .recording(since: 0))
        #expect(await harness.controller.stop(reason: .user)?.isComplete == true)
    }

    @Test func theTimerTextGrowsAnHourField() {
        #expect(RecordingController.elapsedText(0) == "0:00")
        #expect(RecordingController.elapsedText(42.9) == "0:42")
        #expect(RecordingController.elapsedText(725) == "12:05")
        #expect(RecordingController.elapsedText(3725) == "1:02:05")
    }
}
