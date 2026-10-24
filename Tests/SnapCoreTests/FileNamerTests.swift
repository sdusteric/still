import Foundation
import SnapCore
import Testing

@Suite struct FileNamerTests {
    static let paris = TimeZone(identifier: "Europe/Paris") ?? .gmt

    /// 2026-10-24 14:03:22 in `zone`.
    static func date(_ zone: TimeZone = paris, hour: Int = 14) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: 2026, month: 10, day: 24, hour: hour, minute: 3, second: 22)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    @Test func defaultPatternGivesTheDesignExample() {
        let namer = FileNamer(timeZone: Self.paris)
        #expect(namer.baseName(date: Self.date()) == "Snap 2026-10-24 at 14.03.22")
        #expect(namer.fileName(date: Self.date()) { _ in false } == "Snap 2026-10-24 at 14.03.22.png")
    }

    @Test func everyDateTokenIsZeroPadded() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.paris
        let early = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5))
            ?? .distantPast
        let namer = FileNamer(pattern: "{yyyy}/{MM}/{dd} {HH}:{mm}:{ss}", timeZone: Self.paris)
        #expect(namer.baseName(date: early) == "2026-01-02 03.04.05")
    }

    @Test func timeZoneDecidesTheClockTokens() {
        let instant = Self.date(Self.paris)
        let utc = FileNamer(pattern: "{HH}", timeZone: .gmt).baseName(date: instant)
        let paris = FileNamer(pattern: "{HH}", timeZone: Self.paris).baseName(date: instant)
        #expect(paris == "14")
        #expect(utc == "12")
    }

    @Test func counterAndAppTokensAreReplaced() {
        let namer = FileNamer(pattern: "{app} {counter}", timeZone: Self.paris)
        #expect(namer.baseName(date: Self.date(), counter: 42, app: "Notes") == "Notes 42")
        #expect(namer.baseName(date: Self.date(), counter: 7, app: nil) == "7")
    }

    @Test func unknownTokensStayAsWritten() {
        let namer = FileNamer(pattern: "Shot {nope} {HH}", timeZone: Self.paris)
        #expect(namer.baseName(date: Self.date()) == "Shot {nope} 14")
        let unclosed = FileNamer(pattern: "Shot {HH", timeZone: Self.paris)
        #expect(unclosed.baseName(date: Self.date()) == "Shot {HH")
    }

    @Test func collisionsGetNumericSuffixesStartingAtTwo() {
        let namer = FileNamer(timeZone: Self.paris)
        let taken: Set<String> = [
            "Snap 2026-10-24 at 14.03.22.png",
            "Snap 2026-10-24 at 14.03.22 2.png",
        ]
        let name = namer.fileName(date: Self.date()) { taken.contains($0) }
        #expect(name == "Snap 2026-10-24 at 14.03.22 3.png")

        let onlyFirst = namer.fileName(date: Self.date()) { $0 == "Snap 2026-10-24 at 14.03.22.png" }
        #expect(onlyFirst == "Snap 2026-10-24 at 14.03.22 2.png")
    }

    @Test func collisionCheckSeesTheFullFileNameWithExtension() {
        var asked: [String] = []
        _ = FileNamer(pattern: "A", timeZone: Self.paris).fileName(date: Self.date(), fileExtension: "jpg") {
            asked.append($0)
            return asked.count < 2
        }
        #expect(asked == ["A.jpg", "A 2.jpg"])
    }

    @Test func noColonsOrSlashesSurviveFromPatternOrAppName() {
        let namer = FileNamer(pattern: "{app}: {HH}:{mm}/{ss}", timeZone: Self.paris)
        let name = namer.fileName(date: Self.date(), app: "AC/DC: Live") { _ in false }
        #expect(name.contains(":") == false)
        #expect(name.contains("/") == false)
        #expect(name == "AC-DC. Live. 14.03-22.png")
    }

    @Test func emptyOrBlankResultsFallBackToSnap() {
        #expect(FileNamer(pattern: "", timeZone: Self.paris).baseName(date: Self.date()) == "Snap 2026-10-24 at 14.03.22")
        #expect(FileNamer(pattern: "{app}", timeZone: Self.paris).baseName(date: Self.date()) == "Snap")
        #expect(FileNamer(pattern: "...", timeZone: Self.paris).baseName(date: Self.date()) == "Snap")
    }

    @Test func leadingDotsAndRepeatedSpacesAreTidied() {
        let namer = FileNamer(pattern: ".hidden   {app}   name", timeZone: Self.paris)
        #expect(namer.baseName(date: Self.date()) == "hidden name")
    }

    @Test func veryLongPatternsAreCapped() {
        let namer = FileNamer(pattern: String(repeating: "x", count: 400), timeZone: Self.paris)
        #expect(namer.baseName(date: Self.date()).count == FileNamer.maximumBaseLength)
    }

    @Test func fileSystemCheckSkipsExistingFiles() throws {
        let base = ProcessInfo.processInfo.environment["SNAP_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        let folder = base.appending(path: "namer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("cleanup failed: \(error)") }
        }
        let namer = FileNamer(pattern: "Shot", timeZone: Self.paris)
        #expect(namer.fileName(in: folder, date: Self.date()) == "Shot.png")
        try Data().write(to: folder.appending(path: "Shot.png", directoryHint: .notDirectory))
        #expect(namer.fileName(in: folder, date: Self.date()) == "Shot 2.png")
    }
}
