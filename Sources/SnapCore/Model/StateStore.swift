import CoreGraphics
import Foundation

/// Remembered state, not settings (design sections 13, 14 and 20.10).
public struct SnapState: VersionedDocument {
    public static let currentVersion = 2
    /// Key hints show for this many captures, then the app turns them off (design D33).
    public static let keyHintCaptureLimit = 10

    public var version: Int
    /// When `CGRequestScreenCaptureAccess` was called. Set once per install; never called again.
    public var screenRecordingRequested: Date?
    /// The first-run window was finished or skipped.
    public var onboardingCompleted: Bool
    public var lastCaptureID: String?
    /// Captures taken so far, used for the first-10 key hints.
    public var captureCount: Int
    /// The last confirmed area, restored by the HUD only on the same display layout (design D58).
    public var lastArea: LastArea?
    public var hudMode: HUDMode
    public var hudTarget: CaptureMode
    /// The history window's frame in AppKit screen coordinates (bottom-left origin).
    public var historyWindowFrame: CGRect?
    /// When the microphone access request was made. Set once per install, only from a user action
    /// that turns the microphone on (design D65).
    public var microphoneRequested: Date?

    public init(
        version: Int = SnapState.currentVersion,
        screenRecordingRequested: Date? = nil,
        onboardingCompleted: Bool = false,
        lastCaptureID: String? = nil,
        captureCount: Int = 0,
        lastArea: LastArea? = nil,
        hudMode: HUDMode = .screenshot,
        hudTarget: CaptureMode = .area,
        historyWindowFrame: CGRect? = nil,
        microphoneRequested: Date? = nil
    ) {
        self.version = version
        self.screenRecordingRequested = screenRecordingRequested
        self.onboardingCompleted = onboardingCompleted
        self.lastCaptureID = lastCaptureID
        self.captureCount = max(captureCount, 0)
        self.lastArea = lastArea
        self.hudMode = hudMode
        self.hudTarget = hudTarget
        self.historyWindowFrame = historyWindowFrame
        self.microphoneRequested = microphoneRequested
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnapState()
        self.init(
            version: try container.value(.version, default: defaults.version),
            screenRecordingRequested: try container.decodeIfPresent(Date.self, forKey: .screenRecordingRequested),
            onboardingCompleted: try container.value(.onboardingCompleted, default: defaults.onboardingCompleted),
            lastCaptureID: try container.decodeIfPresent(String.self, forKey: .lastCaptureID),
            captureCount: try container.value(.captureCount, default: defaults.captureCount),
            lastArea: container.lenientValue(.lastArea, default: nil),
            hudMode: container.lenientValue(.hudMode, default: defaults.hudMode),
            hudTarget: container.lenientValue(.hudTarget, default: defaults.hudTarget),
            historyWindowFrame: container.lenientValue(.historyWindowFrame, default: nil),
            microphoneRequested: try container.decodeIfPresent(Date.self, forKey: .microphoneRequested)
        )
    }
}

/// `SNAP_HOME/state.json`. Written at once on every change: changes are a few per capture at most.
public final class StateStore: Sendable {
    private let store: DocumentStore<SnapState>

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        store = DocumentStore(fileURL: fileURL, defaultDocument: SnapState(), now: now)
    }

    public convenience init(paths: SnapPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(fileURL: paths.stateFile, now: now)
    }

    public var fileURL: URL { store.fileURL }
    public var state: SnapState { store.document }
    public var writeCount: Int { store.writeCount }

    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        try store.load()
    }

    /// Applies `change` and writes the file if anything changed.
    public func update(_ change: (inout SnapState) -> Void) throws {
        store.mutate { state in
            change(&state)
            state.captureCount = max(state.captureCount, 0)
        }
        try store.flush()
    }
}
