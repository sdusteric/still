import Foundation

/// One capture in `SNAP_HOME/history/<id>/`, described by its `item.json` (design section 14).
public struct CaptureItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var mode: CaptureMode
    /// Pixels per point of the original PNG.
    public var scale: Double
    /// The original PNG in the history folder. Never deleted before retention ends.
    public var originalURL: URL
    /// The PNG with Background or annotations applied, nil until the user edits the capture.
    public var editedURL: URL?
    /// Name of the app that owned the captured window or the frontmost app, when known.
    public var sourceApp: String?

    public init(
        id: String,
        createdAt: Date,
        mode: CaptureMode,
        scale: Double,
        originalURL: URL,
        editedURL: URL? = nil,
        sourceApp: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.scale = scale
        self.originalURL = originalURL
        self.editedURL = editedURL
        self.sourceApp = sourceApp
    }

    /// What Copy, Save and drag-out use: the edited image when there is one.
    public var currentURL: URL { editedURL ?? originalURL }

    /// A sortable id such as `20261024-135501-3f9a1c2e`: local time to the second, then 8 random
    /// hex digits so two captures in the same second never collide.
    public static func makeID(date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(stamp)-\(suffix)"
    }
}
