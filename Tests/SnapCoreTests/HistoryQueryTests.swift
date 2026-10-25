import Foundation
import SnapCore
import Testing

@Suite struct HistoryQueryTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .gmt

    /// A local date in `zone`.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0,
                     in zone: TimeZone = berlin) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    static func item(_ id: String, _ date: Date, app: String?, kind: CaptureKind = .image, file: String? = nil) -> CaptureItem {
        let name = file ?? "Snap \(id).\(kind == .video ? "mp4" : "png")"
        return CaptureItem(
            id: id, createdAt: date, mode: .area, scale: 2,
            originalURL: URL(filePath: "/tmp/history/\(id)/\(name)"), sourceApp: app, kind: kind
        )
    }

    /// Now is Saturday 2026-10-24 15:00 in Berlin.
    let context = HistoryDateContext(
        now: date(2026, 10, 24, 15, 0), calendar: Calendar(identifier: .gregorian), timeZone: berlin
    )

    var items: [CaptureItem] {
        [
            Self.item("a", Self.date(2026, 10, 24, 14, 3, 22), app: "Notes"),
            Self.item("b", Self.date(2026, 10, 24, 9, 5), app: "Safari", kind: .video),
            Self.item("c", Self.date(2026, 10, 23, 21, 40), app: "Notes"),
            Self.item("d", Self.date(2026, 10, 22, 14, 10), app: "Café Menu"),
            Self.item("e", Self.date(2026, 10, 2, 8, 0), app: nil, file: "Quarterly report.png"),
        ]
    }

    func ids(_ text: String, kind: HistoryQuery.KindFilter = .all) -> [String] {
        HistoryQuery(kind: kind, text: text).filter(items, context: context).map(\.id)
    }

    @Test func theKindFilterPicksScreenshotsOrRecordings() {
        #expect(ids("", kind: .all) == ["a", "b", "c", "d", "e"])
        #expect(ids("", kind: .images) == ["a", "c", "d", "e"])
        #expect(ids("", kind: .videos) == ["b"])
        #expect(ids("safari", kind: .images).isEmpty)
    }

    @Test func wordsMatchTheAppNameIgnoringCaseAndDiacritics() {
        #expect(ids("notes") == ["a", "c"])
        #expect(ids("NOTES") == ["a", "c"])
        #expect(ids("cafe") == ["d"])
        #expect(ids("CAFÉ") == ["d"])
        #expect(ids("menu") == ["d"])
    }

    @Test func wordsMatchTheFileName() {
        #expect(ids("quarterly") == ["e"])
        #expect(ids("report.png") == ["e"])
    }

    @Test func todayYesterdayAndWeekdaysAreDateWords() {
        #expect(ids("today") == ["a", "b"])
        #expect(ids("yesterday") == ["c"])
        #expect(ids("friday") == ["c", "e"])
        #expect(ids("fri") == ["c", "e"])
        #expect(ids("thursday") == ["d"])
        #expect(ids("thu") == ["d"])
        #expect(ids("saturday") == ["a", "b"])
    }

    @Test func monthDayMatchesInBothOrdersAndTheDayExactly() {
        #expect(ids("oct 22") == ["d"])
        #expect(ids("22 oct") == ["d"])
        #expect(ids("october 2") == ["e"])
        #expect(ids("oct 02") == ["e"])
        #expect(ids("nov 22").isEmpty)
        #expect(ids("2") == ["e"], "one digit is a day, not a time prefix")
    }

    @Test func aTimePrefixMatchesTheLocalTime() {
        #expect(ids("14") == ["a", "d"])
        #expect(ids("14:0") == ["a"])
        #expect(ids("14:03:22") == ["a"])
        #expect(ids("21:4") == ["c"])
        #expect(ids("21") == ["c"])
    }

    @Test func everyWordMustMatch() {
        #expect(ids("notes today") == ["a"])
        #expect(ids("today notes") == ["a"])
        #expect(ids("notes thursday").isEmpty)
        #expect(ids("  notes   yesterday ") == ["c"])
        #expect(HistoryQuery(text: "   ").isSearching == false)
    }

    @Test func groupingIsByLocalDayNewestFirstWithDayTitles() {
        let sections = HistoryQuery.group(items, context: context)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Thursday, Oct 22", "Friday, Oct 2"])
        #expect(sections.map { $0.items.map(\.id) } == [["a", "b"], ["c"], ["d"], ["e"]])
    }

    @Test func groupingFollowsTheInjectedTimeZoneAcrossMidnight() {
        // 23:30 and 00:30 in Berlin are the same UTC day but different local days.
        let late = Self.item("late", Self.date(2026, 10, 23, 23, 30), app: "Mail")
        let early = Self.item("early", Self.date(2026, 10, 24, 0, 30), app: "Mail")
        let berlin = HistoryQuery.group([late, early], context: context)
        #expect(berlin.map { $0.items.map(\.id) } == [["early"], ["late"]])
        #expect(berlin.map(\.title) == ["Today", "Yesterday"])

        let utc = HistoryDateContext(now: context.now, calendar: Calendar(identifier: .gregorian), timeZone: .gmt)
        let grouped = HistoryQuery.group([late, early], context: utc)
        #expect(grouped.count == 1)
        #expect(grouped.first?.items.map(\.id) == ["early", "late"])
    }

    @Test func groupingHandlesTheDaylightSavingChange() {
        // Los Angeles falls back on Sunday 2026-11-01: that day has 25 hours.
        let la = HistoryDateContext(
            now: Self.date(2026, 11, 2, 9, 0, in: Self.losAngeles), calendar: Calendar(identifier: .gregorian),
            timeZone: Self.losAngeles
        )
        let first = Self.item("first", Self.date(2026, 11, 1, 0, 30, in: Self.losAngeles), app: "Xcode")
        let last = Self.item("last", Self.date(2026, 11, 1, 23, 30, in: Self.losAngeles), app: "Xcode")
        let before = Self.item("before", Self.date(2026, 10, 31, 23, 59, in: Self.losAngeles), app: "Xcode")
        let sections = HistoryQuery.group([first, last, before], context: la)
        #expect(sections.map { $0.items.map(\.id) } == [["last", "first"], ["before"]])
        #expect(sections.map(\.title) == ["Yesterday", "Saturday, Oct 31"])
        #expect(HistoryQuery(text: "yesterday").filter([first, last, before], context: la).map(\.id) == ["first", "last"])
    }
}
