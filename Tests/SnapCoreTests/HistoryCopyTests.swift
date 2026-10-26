import Testing
@testable import SnapCore

@Suite struct HistoryCopyTests {
    @Test func historyCopyFollowsRetention() {
        #expect(ScreenshotRetention.allCases.map(HistoryCopy.subtitle) == ["Last 3 days", "Last 30 days", "Last year"])
        #expect(ScreenshotRetention.allCases.map(HistoryCopy.emptyTitle) == [
            "No captures in the last 3 days", "No captures in the last 30 days", "No captures in the last year",
        ])
        #expect(HistoryCopy.emptyBody(.threeDays) == "Snap keeps every screenshot and recording here for 3 days. ")
        #expect(HistoryCopy.emptyBody(.thirtyDays) == "Snap keeps every screenshot here for 30 days and recordings for 3 days. ")
        #expect(HistoryCopy.emptyBody(.oneYear) == "Snap keeps every screenshot here for 1 year and recordings for 3 days. ")
        #expect(HistoryCopy.footerKept(.threeDays) == "kept for 3 days")
        #expect(HistoryCopy.footerKept(.thirtyDays) == "screenshots kept for 30 days")
        #expect(HistoryCopy.footerKept(.oneYear) == "screenshots kept for 1 year")
        #expect(HistoryCopy.filterEmpty(videos: true, .thirtyDays) == "No recordings in the last 3 days")
        #expect(HistoryCopy.filterEmpty(videos: false, .thirtyDays) == "No screenshots in the last 30 days")
        #expect(HistoryCopy.filterEmpty(videos: false, .oneYear) == "No screenshots in the last year")
    }

    @Test func settingsCopy() {
        #expect(HistoryCopy.searchHelp == "Snap reads the text in your screenshots on this Mac. It skips likely passwords and keys. Nothing is uploaded.")
        #expect(HistoryCopy.recordingsNote == "Recordings are kept for 3 days.")
    }
}
