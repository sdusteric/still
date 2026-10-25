import CoreGraphics
import Foundation

/// One capture in `SNAP_HOME/history/<id>/`, described by its `item.json` (design sections 14
/// and 20.4). A screenshot or a screen recording; the video fields are nil for screenshots.
public struct CaptureItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var mode: CaptureMode
    /// Pixels per point of the original PNG or of the recording.
    public var scale: Double
    /// The original PNG, or the mp4 of a recording, in the history folder. Never deleted before
    /// retention ends.
    public var originalURL: URL
    /// The PNG with Background or annotations applied, nil until the user edits the capture.
    /// Always nil for a recording.
    public var editedURL: URL?
    /// Name of the app that owned the captured window or the frontmost app, when known.
    public var sourceApp: String?
    public var kind: CaptureKind
    public var state: CaptureState
    /// Where the capture was on screen, in global top-left points, for area and window captures
    /// (pin placement, design D47).
    public var screenRect: CGRect?
    public var pixelSize: PixelSize?
    /// Video only.
    public var durationSeconds: Double?
    /// Video only: the poster PNG next to the mp4.
    public var posterURL: URL?
    /// Video only: the FourCC of the video track, `avc1` or `hvc1`.
    public var codec: String?
    /// Video only.
    public var fps: Double?
    /// Video only: the audio sources the recording asked for. Empty for a silent recording.
    public var audio: [AudioSource]

    public init(
        id: String,
        createdAt: Date,
        mode: CaptureMode,
        scale: Double,
        originalURL: URL,
        editedURL: URL? = nil,
        sourceApp: String? = nil,
        kind: CaptureKind = .image,
        state: CaptureState = .complete,
        screenRect: CGRect? = nil,
        pixelSize: PixelSize? = nil,
        durationSeconds: Double? = nil,
        posterURL: URL? = nil,
        codec: String? = nil,
        fps: Double? = nil,
        audio: [AudioSource] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.scale = scale
        self.originalURL = originalURL
        self.editedURL = editedURL
        self.sourceApp = sourceApp
        self.kind = kind
        self.state = state
        self.screenRect = screenRect
        self.pixelSize = pixelSize
        self.durationSeconds = durationSeconds
        self.posterURL = posterURL
        self.codec = codec
        self.fps = fps
        self.audio = audio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            mode: try container.decode(CaptureMode.self, forKey: .mode),
            scale: try container.decode(Double.self, forKey: .scale),
            originalURL: try container.decode(URL.self, forKey: .originalURL),
            editedURL: try container.decodeIfPresent(URL.self, forKey: .editedURL),
            sourceApp: try container.decodeIfPresent(String.self, forKey: .sourceApp),
            kind: try container.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .image,
            state: try container.decodeIfPresent(CaptureState.self, forKey: .state) ?? .complete,
            screenRect: try container.decodeIfPresent(CGRect.self, forKey: .screenRect),
            pixelSize: try container.decodeIfPresent(PixelSize.self, forKey: .pixelSize),
            durationSeconds: try container.decodeIfPresent(Double.self, forKey: .durationSeconds),
            posterURL: try container.decodeIfPresent(URL.self, forKey: .posterURL),
            codec: try container.decodeIfPresent(String.self, forKey: .codec),
            fps: try container.decodeIfPresent(Double.self, forKey: .fps),
            audio: try container.decodeIfPresent([AudioSource].self, forKey: .audio) ?? []
        )
    }

    /// What Copy, Save and drag-out use: the edited image when there is one, else the original
    /// PNG or the mp4.
    public var currentURL: URL { editedURL ?? originalURL }

    /// The image a thumbnail is made from: the current PNG, or the poster of a recording.
    public var thumbnailURL: URL? { kind == .video ? posterURL : currentURL }

    public var isVideo: Bool { kind == .video }
    public var isEdited: Bool { editedURL != nil }

    /// The file name shown and searched: the original PNG or mp4 name.
    public var fileName: String { originalURL.lastPathComponent }

    /// A sortable id such as `20261024-135501-3f9a1c2e`: local time to the second, then 8 random
    /// hex digits so two captures in the same second never collide.
    public static func makeID(date: Date, timeZone: TimeZone = .current) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return makeID(date: date, suffix: String(suffix), timeZone: timeZone)
    }

    /// The same id with a given suffix, for deterministic fixtures.
    public static func makeID(date: Date, suffix: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "\(stamp)-\(suffix)"
    }
}
