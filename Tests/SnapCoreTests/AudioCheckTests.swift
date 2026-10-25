import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (or the temp dir), removed by its exact path when done.
private final class AudioScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "audio-check-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
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
}

private func plan(audio: [AudioSource], output: URL? = nil) throws -> RecordingPlan {
    var settings = Settings()
    settings.recording.systemAudio = audio.contains(.system)
    settings.recording.microphone = audio.contains(.microphone)
    var plan = try RecordingPlan.make(
        target: .area(CGRect(x: 0, y: 0, width: 64, height: 40)), displays: [DisplayInfo(spec: "2560x1440@2")!],
        settings: settings
    )
    plan.outputURL = output
    return plan
}

/// Writes a generated mp4 with the fake recorder: 15 frames, audio as `options` says. No device.
private func makeFixture(at url: URL, audio: [AudioSource], options: FakeRecordingSource.Options) async throws {
    let source = FakeRecordingSource(clock: FakeClock(), options: options)
    let session = try #require(try await source.start(plan(audio: audio, output: url)) as? FakeRecordingSession)
    await session.waitUntilWritten()
    _ = try await session.stop()
}

@Suite struct AudioCheckTests {
    // MARK: The rule

    @Test func noAudioAskedForSaysNothing() {
        #expect(AudioCheck.evaluate(requested: [], audioTrackCount: 0, peakDBFS: nil) == nil)
        #expect(AudioCheck.evaluate(requested: [], audioTrackCount: 1, peakDBFS: -90) == nil)
    }

    @Test func audioAskedForButNoTrackIsNoAudioTrack() {
        #expect(AudioCheck.evaluate(requested: [.system], audioTrackCount: 0, peakDBFS: nil) == .noTrack)
        #expect(AudioCheck.evaluate(requested: [.microphone], audioTrackCount: 0, peakDBFS: nil)?.warning == "No audio track")
    }

    @Test func belowMinusSixtyForTheWholeFileIsSilent() {
        #expect(AudioCheck.evaluate(requested: [.microphone], audioTrackCount: 1, peakDBFS: -60.1) == .microphoneSilent)
        #expect(AudioCheck.evaluate(requested: [.system, .microphone], audioTrackCount: 1, peakDBFS: -160) == .microphoneSilent)
        #expect(AudioCheck.evaluate(requested: [.system], audioTrackCount: 1, peakDBFS: -75) == .systemSilent)
        #expect(AudioCheck.microphoneSilent.warning == "Microphone silent")
        #expect(AudioCheck.systemSilent.warning == "System audio silent")
    }

    @Test func soundAtOrAboveTheFloorIsCaptured() {
        #expect(AudioCheck.evaluate(requested: [.microphone], audioTrackCount: 1, peakDBFS: -60) == .captured)
        #expect(AudioCheck.evaluate(requested: [.system], audioTrackCount: 2, peakDBFS: -12) == .captured)
        #expect(AudioCheck.captured.warning == nil)
    }

    // MARK: Generated fixtures

    @Test func aToneAtMinusTwentyMeasuresNearMinusTwenty() async throws {
        let scratch = try AudioScratch()
        let url = scratch.url.appending(path: "tone.mp4")
        try await makeFixture(at: url, audio: [.microphone], options: FakeRecordingSource.Options(frames: 15, audioToneDBFS: -20))
        let peak = try #require(try await AudioLevelProbe.peakDBFS(of: url, stopAbove: 0))
        #expect(abs(peak + 20) < 3, "peak \(peak) dBFS")
        let probe = await VideoProbe.probe(url, measureAudio: true)
        #expect(probe.audioTrackCount == 1)
        let measured = try #require(probe.audioPeakDBFS)
        #expect(measured > AudioCheck.silenceFloorDBFS)
    }

    @Test func silenceMeasuresAsTheSilentFloor() async throws {
        let scratch = try AudioScratch()
        let url = scratch.url.appending(path: "silent.mp4")
        try await makeFixture(at: url, audio: [.system, .microphone], options: FakeRecordingSource.Options(frames: 15))
        let probe = await VideoProbe.probe(url, measureAudio: true)
        #expect(probe.audioTrackCount == 2)
        let peak = try #require(probe.audioPeakDBFS)
        #expect(peak < AudioCheck.silenceFloorDBFS)
        #expect(AudioCheck.evaluate(requested: [.system, .microphone], audioTrackCount: probe.audioTrackCount, peakDBFS: peak)
            == .microphoneSilent)
    }

    @Test func aFileWithoutAudioHasNoPeak() async throws {
        let scratch = try AudioScratch()
        let url = scratch.url.appending(path: "mute.mp4")
        try await makeFixture(
            at: url, audio: [.microphone], options: FakeRecordingSource.Options(frames: 15, writesAudioTracks: false)
        )
        #expect(try await AudioLevelProbe.peakDBFS(of: url) == nil)
        let probe = await VideoProbe.probe(url, measureAudio: true)
        #expect(probe.playable)
        #expect(probe.audioTrackCount == 0)
        #expect(probe.audioPeakDBFS == nil)
    }

    // MARK: Through the controller, into item.json

    @MainActor
    private func record(audio: [AudioSource], options: FakeRecordingSource.Options) async throws -> (RecordingResult, AudioScratch, HistoryStore) {
        let scratch = try AudioScratch()
        let clock = FakeClock()
        let history = HistoryStore(directory: scratch.history, clock: clock)
        let controller = RecordingController(
            clock: clock, history: history, source: FakeRecordingSource(clock: clock, options: options),
            diskSpace: FakeDiskSpace(), microphone: FakeMicrophoneAuthorization(status: .authorized)
        )
        let outcome = await controller.start(plan: try plan(audio: audio), countdownSeconds: 0)
        guard case .recording = outcome else {
            Issue.record("expected a recording, got \(outcome)")
            throw CancellationError()
        }
        let result = try #require(await controller.stop(reason: .user))
        return (result, scratch, history)
    }

    private func itemJSON(_ history: HistoryStore, _ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: history.folder(for: id).appending(path: HistoryStore.itemFileName))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @MainActor
    @Test func aRecordingWithSoundIsCapturedAndSaysSoInItemJSON() async throws {
        let (result, scratch, history) = try await record(audio: [.microphone], options: FakeRecordingSource.Options(frames: 15, audioToneDBFS: -20))
        #expect(result.audioCheck == .captured)
        #expect(result.item.audioCheck == .captured)
        #expect(try itemJSON(history, result.item.id)["audioCheck"] as? String == "captured")
        #expect(try history.item(id: result.item.id)?.audioCheck == .captured)
        withExtendedLifetime(scratch) {}
    }

    @MainActor
    @Test func aSilentMicrophoneIsReportedOnTheItem() async throws {
        let (result, scratch, history) = try await record(audio: [.microphone], options: FakeRecordingSource.Options(frames: 15))
        #expect(result.audioCheck == .microphoneSilent)
        #expect(try history.item(id: result.item.id)?.audioCheck == .microphoneSilent)
        #expect(result.note == nil, "the audio check has its own pill; the note stays for how the recording ended")
        withExtendedLifetime(scratch) {}
    }

    @MainActor
    @Test func aMissingAudioTrackIsReportedOnTheItem() async throws {
        let (result, scratch, history) = try await record(
            audio: [.system], options: FakeRecordingSource.Options(frames: 15, writesAudioTracks: false)
        )
        #expect(result.isComplete)
        #expect(result.audioCheck == .noTrack)
        #expect(try history.item(id: result.item.id)?.audioCheck?.warning == "No audio track")
        withExtendedLifetime(scratch) {}
    }

    @MainActor
    @Test func aRecordingWithoutAudioHasNoCheck() async throws {
        let (result, scratch, history) = try await record(audio: [], options: FakeRecordingSource.Options(frames: 15))
        #expect(result.audioCheck == nil)
        #expect(try itemJSON(history, result.item.id)["audioCheck"] == nil)
        withExtendedLifetime(scratch) {}
    }
}
