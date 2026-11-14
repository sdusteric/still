import Testing
@testable import SnapCore

@Suite struct HistoryCopyTests {
    @Test func historyCopyFollowsRetention() {
        #expect(ScreenshotRetention.allCases.map(HistoryCopy.subtitle) == ["Last 3 days", "Last 30 days", "Last year"])
        #expect(ScreenshotRetention.allCases.map(HistoryCopy.emptyTitle) == [
            "No captures in the last 3 days", "No captures in the last 30 days", "No captures in the last year",
        ])
        #expect(HistoryCopy.emptyBody(.threeDays) == "Every screenshot and recording stays here for 3 days. ")
        #expect(HistoryCopy.emptyBody(.thirtyDays) == "Screenshots stay here for 30 days and recordings for 3 days. ")
        #expect(HistoryCopy.emptyBody(.oneYear) == "Screenshots stay here for 1 year and recordings for 3 days. ")
        #expect(HistoryCopy.footerKept(.threeDays) == "kept for 3 days")
        #expect(HistoryCopy.footerKept(.thirtyDays) == "screenshots kept for 30 days")
        #expect(HistoryCopy.footerKept(.oneYear) == "screenshots kept for 1 year")
        #expect(HistoryCopy.filterEmpty(videos: true, .thirtyDays) == "No recordings in the last 3 days")
        #expect(HistoryCopy.filterEmpty(videos: false, .thirtyDays) == "No screenshots in the last 30 days")
        #expect(HistoryCopy.filterEmpty(videos: false, .oneYear) == "No screenshots in the last year")
    }

    @Test func settingsCopy() {
        #expect(HistoryCopy.searchHelp == "Search reads the text in your screenshots on this Mac. It skips likely passwords and keys. Nothing is uploaded.")
        #expect(HistoryCopy.recordingsNote == "Recordings are kept for 3 days.")
    }
}
