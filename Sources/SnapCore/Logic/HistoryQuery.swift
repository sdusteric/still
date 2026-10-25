import Foundation

/// The history window's filter and search (design 20.3). The search text is split into words; an
/// item matches when every word matches its app name, its file name or one of its date words:
/// "today", "yesterday", the weekday ("thursday", "thu"), the month day ("oct 22", "22 oct") or a
/// time prefix ("14", "14:0"). Matching ignores case and diacritics. The clock and calendar are
/// injected, so "today" and the day sections are testable across midnight and DST.
public struct HistoryQuery: Sendable, Hashable {
    /// The segmented filter: All | Screenshots | Recordings.
    public enum KindFilter: String, Sendable, Hashable, CaseIterable {
        case all, images, videos

        public var title: String {
            switch self {
            case .all: "All"
            case .images: "Screenshots"
            case .videos: "Recordings"
            }
        }

        public func includes(_ kind: CaptureKind) -> Bool {
            switch self {
            case .all: true
            case .images: kind == .image
            case .videos: kind == .video
            }
        }
    }

    public var kind: KindFilter
    public var text: String

    public init(kind: KindFilter = .all, text: String = "") {
        self.kind = kind
        self.text = text
    }

    /// The search words, folded for case and diacritics.
    public var words: [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { HistoryQuery.fold(String($0)) }.filter { !$0.isEmpty }
    }

    public var isSearching: Bool { !words.isEmpty }

    /// The matching items, in the given order.
    public func filter(_ items: [CaptureItem], context: HistoryDateContext) -> [CaptureItem] {
        let words = words
        return items.filter { matches($0, words: words, context: context) }
    }

    public func matches(_ item: CaptureItem, context: HistoryDateContext) -> Bool {
        matches(item, words: words, context: context)
    }

    private func matches(_ item: CaptureItem, words: [String], context: HistoryDateContext) -> Bool {
        guard kind.includes(item.kind) else { return false }
        guard !words.isEmpty else { return true }
        let app = HistoryQuery.fold(item.sourceApp ?? "")
        let file = HistoryQuery.fold(item.fileName)
        let dates = context.dateWords(for: item.createdAt)
        return words.allSatisfy { word in
            app.contains(word) || file.contains(word) || dates.matches(word)
        }
    }

    /// Items grouped by local day, newest day first, items newest first within a day.
    public static func group(_ items: [CaptureItem], context: HistoryDateContext) -> [HistoryDaySection] {
        var buckets: [Date: [CaptureItem]] = [:]
        for item in items {
            buckets[context.calendar.startOfDay(for: item.createdAt), default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { day in
            let dayItems = (buckets[day] ?? []).sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id > rhs.id : lhs.createdAt > rhs.createdAt
            }
            return HistoryDaySection(day: day, title: context.sectionTitle(for: day), items: dayItems)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}

/// One day of the history grid: "Today", "Yesterday", then "Thursday, Oct 22".
public struct HistoryDaySection: Sendable, Hashable, Identifiable {
    /// Start of the local day.
    public var day: Date
    public var title: String
    public var items: [CaptureItem]

    public var id: Date { day }
}

/// The date words of one item.
public struct HistoryDateWords: Sendable, Hashable {
    /// Matched by prefix: today, yesterday, weekday full and short, month full and short.
    public var names: [String]
    /// Matched exactly, with or without a leading zero: the day of the month.
    public var day: Int
    /// Matched by prefix of at least two characters (a whole hour): `14:03:22`.
    public var time: String

    public func matches(_ word: String) -> Bool {
        if names.contains(where: { $0.hasPrefix(word) }) { return true }
        if let number = Int(word), number == day, word.count <= 2 { return true }
        return word.count >= 2 && time.hasPrefix(word)
    }
}

/// "Now", the calendar and the time zone the history window judges dates by.
public struct HistoryDateContext: Sendable, Hashable {
    public var now: Date
    public var calendar: Calendar

    /// - Parameter calendar: its time zone decides local days; Gregorian with English names.
    public init(now: Date, calendar: Calendar = .current, timeZone: TimeZone? = nil) {
        self.now = now
        var calendar = calendar
        if let timeZone { calendar.timeZone = timeZone }
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    public init(clock: any Clock, calendar: Calendar = .current, timeZone: TimeZone? = nil) {
        self.init(now: clock.date(), calendar: calendar, timeZone: timeZone)
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let months = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    public func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: now) }

    public func isYesterday(_ date: Date) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }

    public func dateWords(for date: Date) -> HistoryDateWords {
        let parts = calendar.dateComponents([.weekday, .month, .day, .hour, .minute, .second], from: date)
        var names: [String] = []
        if isToday(date) { names.append("today") }
        if isYesterday(date) { names.append("yesterday") }
        if let weekday = parts.weekday, (1...7).contains(weekday) {
            let name = HistoryDateContext.weekdays[weekday - 1]
            names.append(name)
            names.append(String(name.prefix(3)))
        }
        if let month = parts.month, (1...12).contains(month) {
            let name = HistoryDateContext.months[month - 1]
            names.append(name)
            names.append(String(name.prefix(3)))
        }
        let time = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return HistoryDateWords(names: names, day: parts.day ?? 0, time: time)
    }

    /// "Today", "Yesterday", else "Thursday, Oct 22".
    public func sectionTitle(for day: Date) -> String {
        if isToday(day) { return "Today" }
        if isYesterday(day) { return "Yesterday" }
        let parts = calendar.dateComponents([.weekday, .month, .day], from: day)
        let weekday = parts.weekday.flatMap { (1...7).contains($0) ? HistoryDateContext.weekdays[$0 - 1] : nil } ?? ""
        let month = parts.month.flatMap { (1...12).contains($0) ? HistoryDateContext.months[$0 - 1] : nil } ?? ""
        return "\(weekday.capitalized), \(month.prefix(3).capitalized) \(parts.day ?? 0)"
    }

    /// The tile caption time, `14:03` (24 hour, tabular in the UI).
    public func timeText(for date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
