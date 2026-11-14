import AppKit
import SnapCore
import SwiftUI

/// Fixed thumbnails for the shot scene: no files, no thumbnail work.
final class DemoThumbnails: HistoryThumbnailProviding {
    private let images: [URL: CGImage]

    init(_ images: [URL: CGImage]) {
        self.images = images
    }

    func cachedThumbnail(for url: URL) -> CGImage? { images[url] }
    func thumbnail(for url: URL) async -> CGImage? { images[url] }
}

/// The `history` and `history-empty` shots (mockup 9, design 20.11): the window content with the
/// toolbar, two day sections (one tile selected, a recording, an edited and an interrupted item)
/// and the footer; or the empty state. Dates are fixed: Saturday Oct 24 2026, 14:05 UTC.
public enum HistoryDemo {
    public static let size = Theme.History.windowSize
    /// Saturday 2026-10-24 14:05:00 UTC.
    public static let now = Date(timeIntervalSince1970: 1_792_850_700)
    static let timeZone = TimeZone(identifier: "UTC") ?? .current

    public static var context: HistoryDateContext {
        HistoryDateContext(now: now, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
    }

    private struct Entry {
        var id: String
        /// Hours and minutes before `now`'s day start (negative days go back).
        var day: Int
        var hour: Int
        var minute: Int
        var app: String
        var kind: CaptureKind = .image
        var state: CaptureState = .complete
        var edited = false
        var duration: Double?
        var art: Art
    }

    private enum Art {
        case notes, editedNotes, build, tests, palette, chat, form
    }

    private static let entries: [Entry] = [
        Entry(id: "d1", day: 0, hour: 14, minute: 3, app: "Notes", art: .notes),
        Entry(id: "d2", day: 0, hour: 13, minute: 41, app: "Notes", edited: true, art: .editedNotes),
        Entry(id: "d3", day: 0, hour: 11, minute: 48, app: "Terminal", kind: .video, duration: 42, art: .build),
        Entry(id: "d4", day: 0, hour: 9, minute: 15, app: "Figma", art: .palette),
        Entry(id: "d5", day: 0, hour: 8, minute: 52, app: "Messages", art: .chat),
        Entry(id: "d6", day: -1, hour: 17, minute: 20, app: "Still", art: .form),
        Entry(id: "d7", day: -1, hour: 16, minute: 2, app: "Safari", kind: .video, state: .interrupted, art: .notes),
        Entry(id: "d8", day: -1, hour: 10, minute: 31, app: "Terminal", art: .tests),
        Entry(id: "d9", day: -2, hour: 18, minute: 12, app: "Notes", art: .notes),
        Entry(id: "d10", day: -2, hour: 15, minute: 40, app: "Figma", art: .palette),
        Entry(id: "d11", day: -2, hour: 11, minute: 5, app: "Messages", art: .chat),
        Entry(id: "d12", day: -2, hour: 9, minute: 30, app: "Terminal", kind: .video, duration: 75, art: .build),
    ]

    /// Twelve captures over three days, 41 MB, with the newest selected.
    public static func makeModel(empty: Bool = false, dark: Bool = false) -> (HistoryWindowModel, any HistoryThumbnailProviding) {
        var images: [URL: CGImage] = [:]
        var items: [CaptureItem] = []
        if !empty {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let today = calendar.startOfDay(for: now)
            for entry in entries {
                let day = calendar.date(byAdding: .day, value: entry.day, to: today) ?? today
                let created = day.addingTimeInterval(Double(entry.hour * 3600 + entry.minute * 60))
                let folder = URL(filePath: "/demo/history/\(entry.id)", directoryHint: .isDirectory)
                let original = folder.appending(path: entry.kind == .video ? "Still.mp4" : "Still.png")
                let edited = entry.edited ? folder.appending(path: "Still (edited).png") : nil
                let poster = entry.kind == .video ? folder.appending(path: "Still poster.png") : nil
                let item = CaptureItem(
                    id: entry.id, createdAt: created, mode: .window, scale: 2, originalURL: original, editedURL: edited,
                    sourceApp: entry.app, kind: entry.kind, state: entry.state, durationSeconds: entry.duration,
                    posterURL: poster
                )
                if let url = item.thumbnailURL, let image = image(for: entry.art, dark: dark) { images[url] = image }
                items.append(item)
            }
        }
        let snapshot = HistorySnapshot(items: items, totalBytes: empty ? 0 : 41_000_000)
        let model = HistoryWindowModel(load: { snapshot }, context: { context })
        model.apply(.success(snapshot))
        if let first = model.orderedIDs.first { model.select(first) }
        return (model, DemoThumbnails(images))
    }

    private static func image(for art: Art, dark: Bool) -> CGImage? {
        switch art {
        case .notes: M2DemoArt.notes(dark: dark, scale: 1)
        case .editedNotes: M2DemoArt.notes(dark: dark, scale: 1).flatMap(QuickAccessDemo.backgroundImage(around:))
        case .build: M2DemoArt.terminal(M2DemoArt.buildLines, size: CGSize(width: 328, height: 224), dark: dark, bar: true, scale: 1)
        case .tests: M2DemoArt.terminal(M2DemoArt.testLines, size: CGSize(width: 328, height: 224), dark: dark, bar: true, scale: 1)
        case .palette: M2DemoArt.palette(size: CGSize(width: 246, height: 168), scale: 4.0 / 3)
        case .chat: M2DemoArt.chat(size: CGSize(width: 246, height: 168), scale: 4.0 / 3)
        case .form: M2DemoArt.form(size: CGSize(width: 246, height: 168), scale: 4.0 / 3)
        }
    }

    /// The window content in a hosting view of the window size, with the appearance set. No window.
    public static func makeView(empty: Bool = false, dark: Bool = false) -> NSView {
        let (model, thumbnails) = makeModel(empty: empty, dark: dark)
        let view = NSHostingView(rootView: HistoryView(
            model: model, thumbnails: thumbnails, drawsTrafficLights: true, interactive: false
        ))
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }
}
