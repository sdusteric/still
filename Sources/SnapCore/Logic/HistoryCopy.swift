import Foundation

/// History and settings text that names how long captures are kept (Recall design 7.4 and 7.7).
public enum HistoryCopy {
    public static let searchHelp = "Search reads the text in your screenshots on this Mac. It skips likely passwords and keys. Nothing is uploaded."
    public static let recordingsNote = "Recordings are kept for 3 days."

    public static func subtitle(_ retention: ScreenshotRetention) -> String {
        retention == .oneYear ? "Last year" : "Last \(retention.label)"
    }

    public static func emptyTitle(_ retention: ScreenshotRetention) -> String {
        "No captures in \(span(retention))"
    }

    public static func emptyBody(_ retention: ScreenshotRetention) -> String {
        retention == .threeDays
            ? "Every screenshot and recording stays here for 3 days. "
            : "Screenshots stay here for \(retention.label) and recordings for 3 days. "
    }

    public static func footerKept(_ retention: ScreenshotRetention) -> String {
        retention == .threeDays ? "kept for 3 days" : "screenshots kept for \(retention.label)"
    }

    public static func filterEmpty(videos: Bool, _ retention: ScreenshotRetention) -> String {
        videos ? "No recordings in the last 3 days" : "No screenshots in \(span(retention))"
    }

    private static func span(_ retention: ScreenshotRetention) -> String {
        retention == .oneYear ? "the last year" : "the last \(retention.label)"
    }
}
