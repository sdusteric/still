import Foundation

/// Why a recording stopped (design 20.6). The first three are the user's; the rest come from the
/// system, the disk check, quitting or sleep.
public enum RecordingStopReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The status item timer or the Stop Recording menu item.
    case user
    /// Cmd+Shift+5 or the Stop Recording shortcut.
    case hotkey
    /// The recorded window closed.
    case windowClosed
    /// The recorded display was disconnected.
    case displayDisconnected
    /// The stream stopped with an error.
    case streamFailed
    /// Free space fell below 500 MB while recording.
    case diskFull
    /// Snap is quitting (`applicationShouldTerminate` returns `.terminateLater`).
    case quit
    /// The Mac is going to sleep.
    case sleep

    /// The note the video card shows, nil when the user or Snap stopped on purpose.
    public var cardNote: String? {
        switch self {
        case .user, .hotkey, .quit, .sleep: nil
        case .windowClosed: "Stopped: the window closed"
        case .displayDisconnected: "Stopped: the display was disconnected"
        case .streamFailed: "Stopped: the recording failed"
        case .diskFull: "Stopped: disk almost full"
        }
    }
}

/// What a running recording reports after `start` returned.
public enum RecordingSessionEvent: Sendable, Hashable {
    /// The first frame reached the file, at this clock time.
    case firstFrame(at: TimeInterval)
    /// The system ended the stream (window closed, display removed). The file is still open:
    /// the controller calls `stop()` to finish it.
    case stoppedBySystem(RecordingStopReason)
    /// The stream failed mid-recording. The controller still calls `stop()` to keep what was written.
    case failed(String)
}

/// Errors a source throws from `start`.
public enum RecordingSourceError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Screen Recording was denied or lapsed (`SCStreamErrorUserDeclined`, -3801).
    case permissionDenied
    /// The stream could not start for another reason.
    case startFailed(String)
    /// The plan has no output URL.
    case missingOutputURL
    /// `stop()` was called on a session that already stopped.
    case notRecording

    public var description: String {
        switch self {
        case .permissionDenied: "Screen Recording permission is off"
        case .startFailed(let message): "Recording could not start: \(message)"
        case .missingOutputURL: "the recording plan has no output file"
        case .notRecording: "the recording already stopped"
        }
    }
}

/// One running recording. Live: `SCStream` with `SCRecordingOutput` (SnapSystem). Fake: an
/// `AVAssetWriter` fed with synthetic frames.
public protocol RecordingSession: AnyObject, Sendable {
    /// Events after `start` returned. One consumer: the controller.
    var events: AsyncStream<RecordingSessionEvent> { get }
    /// Stops the stream, finishes the file and returns its URL.
    func stop() async throws -> URL
}

/// Starts recordings. `start` returns once the stream is running and writing to `plan.outputURL`.
public protocol RecordingSource: Sendable {
    func start(_ plan: RecordingPlan) async throws -> any RecordingSession
}
