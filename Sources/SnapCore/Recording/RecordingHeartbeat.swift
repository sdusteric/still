import Foundation

/// How many samples a running recording has delivered so far. The live session counts every
/// screen and audio sample buffer ScreenCaptureKit hands it; the fake counts its frames.
public struct RecordingSampleCounts: Sendable, Hashable {
    public var videoFrames: Int
    public var systemAudio: Int
    public var microphone: Int

    public init(videoFrames: Int = 0, systemAudio: Int = 0, microphone: Int = 0) {
        self.videoFrames = videoFrames
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
}

/// What stopped arriving while recording (design 20.6, heartbeat). The status item turns amber and
/// the recording menu shows `message`; nothing stops the recording.
public struct RecordingStall: Sendable, Hashable {
    public enum Track: String, Sendable, Hashable {
        case video
        case systemAudio
        case microphone
    }

    public var track: Track
    /// Whole seconds since the last sample of `track`.
    public var seconds: Int
    /// The recording's elapsed time when the last sample arrived, for the card note.
    public var lastSampleElapsed: TimeInterval

    public init(track: Track, seconds: Int, lastSampleElapsed: TimeInterval) {
        self.track = track
        self.seconds = seconds
        self.lastSampleElapsed = lastSampleElapsed
    }

    /// "Recording stalled: no new frames for 5 s".
    public var message: String {
        switch track {
        case .video: "Recording stalled: no new frames for \(seconds) s"
        case .systemAudio: "Recording stalled: no system audio for \(seconds) s"
        case .microphone: "Recording stalled: no microphone audio for \(seconds) s"
        }
    }

    /// The video card note when the recording ended stalled: "Frames stopped at 0:42".
    public var cardNote: String {
        let time = RecordingController.elapsedText(lastSampleElapsed)
        return switch track {
        case .video: "Frames stopped at \(time)"
        case .systemAudio: "System audio stopped at \(time)"
        case .microphone: "Microphone stopped at \(time)"
        }
    }
}

/// The recording heartbeat as a pure value: fed the sample counts once a second, it reports the
/// first track that has delivered nothing for `threshold` seconds, video before audio. Audio
/// tracks are watched only when the plan records them.
public struct RecordingHeartbeat: Sendable {
    /// No sample for this long is a stall.
    public static let threshold: TimeInterval = 3
    /// How often the controller reads the counts.
    public static let pollInterval: TimeInterval = 1

    private let start: TimeInterval
    private let watched: [RecordingStall.Track]
    private var last: [RecordingStall.Track: (count: Int, time: TimeInterval)] = [:]
    public private(set) var stall: RecordingStall?

    /// - Parameters:
    ///   - start: clock time the recording started; a track with no sample yet counts from here.
    ///   - audio: the audio sources the plan records.
    public init(start: TimeInterval, audio: [AudioSource]) {
        self.start = start
        var watched: [RecordingStall.Track] = [.video]
        if audio.contains(.system) { watched.append(.systemAudio) }
        if audio.contains(.microphone) { watched.append(.microphone) }
        self.watched = watched
        for track in watched { last[track] = (0, start) }
    }

    /// Records `counts` read at clock time `now` and returns the stall, nil when every watched
    /// track moved within the threshold.
    @discardableResult
    public mutating func observe(_ counts: RecordingSampleCounts, at now: TimeInterval) -> RecordingStall? {
        var found: RecordingStall?
        for track in watched {
            let count = Self.count(of: track, in: counts)
            guard let previous = last[track] else { continue }
            if count != previous.count {
                last[track] = (count, now)
                continue
            }
            let quiet = now - previous.time
            if found == nil, quiet >= Self.threshold {
                found = RecordingStall(
                    track: track, seconds: Int(quiet.rounded(.down)), lastSampleElapsed: max(previous.time - start, 0)
                )
            }
        }
        stall = found
        return found
    }

    static func count(of track: RecordingStall.Track, in counts: RecordingSampleCounts) -> Int {
        switch track {
        case .video: counts.videoFrames
        case .systemAudio: counts.systemAudio
        case .microphone: counts.microphone
        }
    }
}
