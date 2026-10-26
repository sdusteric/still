import Foundation
@testable import SnapCore
import Testing

@Suite struct RetentionTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "snap-recall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decodeGeneral(_ json: String) throws -> GeneralSettings {
        try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
    }

    @Test func missingKeysReadAsNewDefaults() throws {
        let general = try decodeGeneral(#"{"launchAtLogin":false,"fileNamePattern":"x","playSound":false,"showInShelf":true}"#)
        #expect(general.screenshotRetention == .thirtyDays)
        #expect(general.searchInShelf)
        #expect(general.searchPreviews)
        #expect(general.searchExcludedApps == ["Passwords", "Keychain Access", "1Password", "Bitwarden"])
        #expect(general.showInShelf)
    }

    @Test func retentionRoundTrips() throws {
        var general = GeneralSettings()
        general.screenshotRetention = .oneYear
        let data = try JSONEncoder().encode(general)
        #expect(String(decoding: data, as: UTF8.self).contains(#""screenshotRetention":"1y""#))
        #expect(try JSONDecoder().decode(GeneralSettings.self, from: data) == general)
    }

    @Test func unknownRetentionFallsBackTo30Days() throws {
        #expect(try decodeGeneral(#"{"screenshotRetention":"5d"}"#).screenshotRetention == .thirtyDays)
    }

    @Test func retentionIntervalsAndLabels() {
        #expect(ScreenshotRetention.threeDays.interval == 3 * 86_400)
        #expect(ScreenshotRetention.thirtyDays.interval == 30 * 86_400)
        #expect(ScreenshotRetention.oneYear.interval == 365 * 86_400)
        #expect(ScreenshotRetention.allCases.map(\.label) == ["3 days", "30 days", "1 year"])
    }

    @Test func sweepKeepsImagesFor30Days() throws {
        let home = try scratch()
        defer { RecallTestSupport.remove(home) }
        let store = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock(startDate: Self.now))
        let image = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2, createdAt: Self.now.addingTimeInterval(-10 * 86_400))
        let video = try store.add(video: NewVideo(fileName: "b.mp4", mode: .fullscreen, scale: 2), createdAt: Self.now.addingTimeInterval(-4 * 86_400))
        let removed = try store.sweep(now: Self.now, imageRetention: ScreenshotRetention.thirtyDays.interval)
        #expect(removed == [video.id])
        #expect(try store.item(id: image.id) != nil)
    }

    @Test func sweepHonorsThreeDays() throws {
        let home = try scratch()
        defer { RecallTestSupport.remove(home) }
        let store = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock(startDate: Self.now))
        let image = try store.add(pngData: png, fileName: "a.png", mode: .area, scale: 2, createdAt: Self.now.addingTimeInterval(-4 * 86_400))
        #expect(try store.sweep(now: Self.now, imageRetention: ScreenshotRetention.threeDays.interval) == [image.id])
    }

    /// A timing budget: run alone (`SNAP_BENCH=1`), since a parallel suite skews it and the 1,500
    /// folders it writes slow the suite's other timing tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNAP_BENCH"] == "1"))
    func listing1500ItemsWithinBudget() throws {
        let home = try scratch()
        defer { RecallTestSupport.remove(home) }
        let store = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock(startDate: Self.now))
        _ = try HistoryFixture.generate(into: store, options: .init(items: 1_500, days: 30, now: Self.now))
        var times: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            #expect(try store.allItems().count == 1_500)
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        times.sort()
        let p95 = times[Int(Double(times.count) * 0.95) - 1]
        print("history listing p95 ms \(p95)")
        #expect(p95 < 50)
    }
}


@Suite struct HistoryRecentTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recentReturnsTheNewestFirst() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let store = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock(startDate: Self.now))
        let ids = try (0..<20).map { index in
            try store.add(pngData: png, fileName: "\(index).png", mode: .area, scale: 2, createdAt: Self.now.addingTimeInterval(-Double(index) * 3_600)).id
        }
        #expect(try store.recent(limit: 3).map(\.id) == Array(ids.prefix(3)))
        #expect(try store.recent(limit: 50).count == 20)
    }

    /// The Shelf status reads `recent(limit: 12)` on the main actor after every capture.
    @Test func recentReadsOnlyTheNewestItems() throws {
        let home = try RecallTestSupport.makeHome()
        defer { RecallTestSupport.remove(home) }
        let store = HistoryStore(directory: home.appending(path: "history"), clock: FakeClock(startDate: Self.now))
        _ = try HistoryFixture.generate(into: store, options: .init(items: 1_000, days: 300, now: Self.now))
        var times: [Double] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            _ = try store.recent(limit: 12)
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        #expect(times.sorted()[8] < 8, "recent(limit: 12) p90 \(times.sorted()[8]) ms")
        let all = try store.allItems()
        #expect(try store.recent(limit: 12).map(\.id) == Array(all.prefix(12)).map(\.id))
    }
}
