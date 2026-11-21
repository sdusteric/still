import CoreGraphics
import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (check.sh exports a mktemp one) or the temp dir, removed by
/// its exact path when the test ends.
private final class StoreScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let home = environment["SNAP_HOME"], !home.isEmpty {
            base = URL(filePath: home, directoryHint: .isDirectory)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        url = base.appending(path: "store-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A leftover scratch dir inside a temp dir is harmless.
        }
    }

    func file(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }
}

@Suite struct StoreTests {
    @Test func settingsRoundTripThroughJSON() throws {
        let scratch = try StoreScratch()
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        #expect(try store.load() == .missing)
        #expect(store.settings == Settings())

        try store.update { settings in
            settings.capture.copyToClipboard = false
            settings.capture.instantCapture = false
            settings.quickAccess.corner = .bottomRight
            settings.quickAccess.size = .large
            settings.quickAccess.autoCloseSeconds = 30
            settings.general.fileNamePattern = "Shot {HH}.{mm}"
            settings.shortcuts.applyBackground = KeyShortcut(keyCode: 11, modifiers: KeyShortcut.Modifier.option)
        }

        let reloaded = SettingsStore(fileURL: scratch.file("settings.json"))
        #expect(try reloaded.load() == .loaded)
        #expect(reloaded.settings == store.settings)
        #expect(reloaded.settings.capture.copyToClipboard == false)
        #expect(reloaded.settings.quickAccess.corner == .bottomRight)
        #expect(reloaded.settings.shortcuts.applyBackground?.keyCode == 11)

        let text = try String(contentsOf: scratch.file("settings.json"), encoding: .utf8)
        #expect(text.contains("\"autoCloseSeconds\" : 30"))
    }

    @Test func defaultSettingsMatchTheDesign() {
        let settings = Settings()
        #expect(settings.capture.showQuickAccess)
        #expect(settings.capture.copyToClipboard)
        #expect(!settings.capture.saveToFolder)
        #expect(!settings.capture.openInAnnotate)
        #expect(settings.capture.instantCapture)
        #expect(settings.capture.hideDesktopIcons)
        #expect(settings.capture.includeWindowShadow)
        #expect(settings.quickAccess.corner == .bottomLeft)
        #expect(settings.quickAccess.size == .medium)
        #expect(settings.quickAccess.size.thumbnailWidth == 240)
        #expect(settings.quickAccess.autoCloseSeconds == 15)
        #expect(!settings.general.playSound)
        #expect(!settings.general.launchAtLogin)
        #expect(settings.general.fileNamePattern == "Still {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}")
        #expect(settings.shortcuts.captureFullscreen == .commandShift3)
        #expect(settings.shortcuts.captureArea == .commandShift4)
        #expect(settings.shortcuts.allInOne == .commandShift5)
        #expect(settings.shortcuts.captureWindow == nil)
        #expect(settings.shortcuts.captureArea?.modifiers == 768)
        #expect(settings.shortcuts.applyBackground == nil)
        #expect(settings.shortcuts.openInAnnotate == nil)
        for action in [ShortcutAction.recordScreen, .stopRecording, .pinLastCapture, .openHistory] {
            #expect(settings.shortcuts[action] == nil)
        }
        #expect(settings.version == Settings.currentVersion)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let json = #"{"version": 1, "capture": {"copyToClipboard": false}, "quickAccess": {"autoCloseSeconds": 500}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.capture.copyToClipboard == false)
        #expect(settings.capture.showQuickAccess)
        #expect(settings.quickAccess.autoCloseSeconds == 60)
        #expect(settings.shortcuts == ShortcutSettings())
        #expect(settings.general == GeneralSettings())
    }

    @Test func clearedShortcutStaysClearedAfterRoundTrip() throws {
        let scratch = try StoreScratch()
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        try store.update { $0.shortcuts[.captureArea] = nil }
        let reloaded = SettingsStore(fileURL: scratch.file("settings.json"))
        try reloaded.load()
        #expect(reloaded.settings.shortcuts.captureArea == nil)
        #expect(reloaded.settings.shortcuts.allInOne == .commandShift5)
    }

    @Test func updateClampsAutoCloseSeconds() throws {
        let scratch = try StoreScratch()
        let store = SettingsStore(fileURL: scratch.file("settings.json"))
        try store.update { $0.quickAccess.autoCloseSeconds = 1 }
        #expect(store.settings.quickAccess.autoCloseSeconds == 3)
        try store.update { $0.quickAccess.autoCloseSeconds = 90 }
        #expect(store.settings.quickAccess.autoCloseSeconds == 60)
    }

    @Test func stateRoundTripThroughJSON() throws {
        let scratch = try StoreScratch()
        let store = StateStore(fileURL: scratch.file("state.json"))
        #expect(try store.load() == .missing)
        #expect(store.state.screenRecordingRequested == nil)
        let requested = Date(timeIntervalSince1970: 1_792_843_200)
        try store.update { state in
            state.screenRecordingRequested = requested
            state.onboardingCompleted = true
            state.lastCaptureID = "20261024-120000-abcdef12"
            state.captureCount = 4
        }
        #expect(store.writeCount == 1)
        try store.update { $0.captureCount = 4 }
        #expect(store.writeCount == 1, "an unchanged state is not written again")

        let reloaded = StateStore(fileURL: scratch.file("state.json"))
        #expect(try reloaded.load() == .loaded)
        #expect(reloaded.state == store.state)
        #expect(reloaded.state.screenRecordingRequested == requested)
        #expect(reloaded.state.captureCount == 4)
    }

    @Test func stateM2FieldsRoundTripAndAVersion1StateStillLoads() throws {
        let scratch = try StoreScratch()
        let url = scratch.file("state.json")
        try Data(#"{"version": 1, "captureCount": 7, "onboardingCompleted": true}"#.utf8).write(to: url)
        let store = StateStore(fileURL: url)
        #expect(try store.load() == .loaded)
        #expect(store.state.captureCount == 7)
        #expect(store.state.lastArea == nil)
        #expect(store.state.hudMode == .screenshot)
        #expect(store.state.hudTarget == .area)
        #expect(store.state.historyWindowFrame == nil)
        #expect(store.state.microphoneRequested == nil)

        let area = LastArea(
            displayID: 3, displayFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            rect: CGRect(x: 330.5, y: 150, width: 640, height: 400)
        )
        let requested = Date(timeIntervalSince1970: 1_792_843_200)
        try store.update { state in
            state.lastArea = area
            state.hudMode = .record
            state.hudTarget = .window
            state.historyWindowFrame = CGRect(x: 100, y: 200, width: 760, height: 560)
            state.microphoneRequested = requested
        }
        let reloaded = StateStore(fileURL: url)
        #expect(try reloaded.load() == .loaded)
        #expect(reloaded.state == store.state)
        #expect(reloaded.state.lastArea == area)
        #expect(reloaded.state.hudMode == .record)
        #expect(reloaded.state.microphoneRequested == requested)
    }

    @Test func anUnknownHUDModeFallsBackInsteadOfDiscardingTheState() throws {
        let json = #"{"version": 2, "captureCount": 2, "hudMode": "video", "hudTarget": "area"}"#
        let state = try JSONDecoder().decode(SnapState.self, from: Data(json.utf8))
        #expect(state.hudMode == .screenshot)
        #expect(state.captureCount == 2)
    }

    @Test func corruptFileIsMovedAsideNotDeleted() throws {
        let scratch = try StoreScratch()
        let url = scratch.file("settings.json")
        try Data("{ not json".utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        let outcome = try store.load()
        guard case .recovered(let movedTo) = outcome else {
            Issue.record("expected recovered, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: movedTo.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(store.settings == Settings())
    }

    @Test func newerVersionIsMovedAside() throws {
        let scratch = try StoreScratch()
        let url = scratch.file("state.json")
        try Data(#"{"version": 99, "captureCount": 3}"#.utf8).write(to: url)
        let store = StateStore(fileURL: url)
        let outcome = try store.load()
        guard case .newerVersion = outcome else {
            Issue.record("expected newerVersion, got \(outcome)")
            return
        }
        #expect(store.state == SnapState())
    }

    @Test func atomicWriteReplacesFileAndLeavesNoTempFiles() throws {
        let scratch = try StoreScratch()
        let url = scratch.url.appending(path: "nested/dir/file.json", directoryHint: .notDirectory)
        try AtomicFile.write(Data("first".utf8), to: url)
        try AtomicFile.write(Data("second".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false))
        #expect(siblings == ["file.json"])
    }

    @Test func atomicWriteKeepsOldContentWhenRenameFails() throws {
        let scratch = try StoreScratch()
        // The target is a non-empty directory, so rename(2) fails after the temp file is written.
        let target = scratch.url.appending(path: "occupied", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appending(path: "inside.txt", directoryHint: .notDirectory))
        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("new".utf8), to: target)
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path(percentEncoded: false))
        #expect(siblings == ["occupied"], "the temp file is removed after a failed rename")
    }

    @Test func defaultSaveFolderMovesInsideNonDefaultSnapHome() throws {
        let scratch = try StoreScratch()
        let userHome = "/Users/example"
        let custom = SnapPaths(environment: ["SNAP_HOME": scratch.url.path(percentEncoded: false), "HOME": userHome])
        #expect(!custom.isDefaultHome)
        // Both sides normalized: under /private/tmp the existing home loses its /private prefix.
        #expect(SnapPaths.normalizedPath(custom.defaultSaveFolder).hasPrefix(SnapPaths.normalizedPath(scratch.url)))
        #expect(custom.defaultSaveFolder.lastPathComponent == "Saved")
        #expect(!custom.defaultSaveFolder.path(percentEncoded: false).contains("Downloads"))

        let unset = SnapPaths(environment: ["HOME": userHome])
        #expect(unset.isDefaultHome)
        #expect(unset.home.path(percentEncoded: false).hasPrefix("/Users/example/Library/Application Support/Snap"))
        #expect(unset.defaultSaveFolder.path(percentEncoded: false).hasPrefix("/Users/example/Downloads"))

        let explicitDefault = SnapPaths(environment: [
            "SNAP_HOME": "~/Library/Application Support/Snap/", "HOME": userHome,
        ])
        #expect(explicitDefault.isDefaultHome)
        #expect(explicitDefault.defaultSaveFolder.lastPathComponent == "Downloads")

        let empty = SnapPaths(environment: ["SNAP_HOME": "", "HOME": userHome])
        #expect(empty.isDefaultHome)
    }

    @Test func pathsUnderPrivateTmpCompareEqualToTheirTmpForm() {
        let existing = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
        let missing = URL(filePath: "/private/tmp/snap-\(UUID().uuidString)/Saved", directoryHint: .isDirectory)
        #expect(SnapPaths.normalizedPath(existing) == "/tmp/")
        #expect(SnapPaths.normalizedPath(missing).hasPrefix("/tmp/snap-"))
        #expect(SnapPaths.normalizedPath(URL(filePath: "/private/tmpfoo")) == "/private/tmpfoo")
        let paths = SnapPaths(environment: ["SNAP_HOME": "/private/tmp/snap-home-x", "HOME": "/Users/example"])
        var settings = Settings()
        settings.general.saveFolderPath = "/tmp/snap-home-x/Elsewhere"
        #expect(paths.saveFolder(for: settings).lastPathComponent == "Elsewhere")
    }

    @Test func storedSaveFolderOutsideTestHomeIsIgnored() throws {
        let scratch = try StoreScratch()
        let paths = SnapPaths(environment: ["SNAP_HOME": scratch.url.path(percentEncoded: false), "HOME": "/Users/example"])
        var settings = Settings()
        settings.general.saveFolderPath = "~/Downloads"
        #expect(paths.saveFolder(for: settings) == paths.defaultSaveFolder)

        let inside = scratch.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
        settings.general.saveFolderPath = inside.path(percentEncoded: false)
        #expect(paths.saveFolder(for: settings).lastPathComponent == "Elsewhere")

        let defaultPaths = SnapPaths(environment: ["HOME": "/Users/example"])
        settings.general.saveFolderPath = "~/Pictures/Shots"
        #expect(defaultPaths.saveFolder(for: settings).path(percentEncoded: false).hasPrefix("/Users/example/Pictures/Shots"))
    }

    @Test func pathsLayoutUnderSnapHome() throws {
        let scratch = try StoreScratch()
        let paths = SnapPaths(home: scratch.url)
        #expect(paths.settingsFile.lastPathComponent == "settings.json")
        #expect(paths.presetsFile.lastPathComponent == "presets.json")
        #expect(paths.stateFile.lastPathComponent == "state.json")
        #expect(paths.logFile.path(percentEncoded: false).hasSuffix("logs/snap.log"))
        #expect(paths.historyDirectory(for: "abc").path(percentEncoded: false).hasSuffix("history/abc/"))
        try paths.createDirectories()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.historyDirectory.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func logRotatesAtTheSizeLimit() throws {
        let scratch = try StoreScratch()
        let log = Log(fileURL: scratch.file("logs/snap.log"), maxBytes: 2048)
        let line = String(repeating: "x", count: 200)
        for index in 0..<30 { log.info("\(index) \(line)") }
        let current = try Data(contentsOf: log.fileURL)
        let rotated = try Data(contentsOf: log.rotatedURL)
        #expect(current.count <= 2048)
        #expect(rotated.count <= 2048)
        #expect(rotated.count > 1024)
        let lastLine = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(lastLine.contains("29 "))
        #expect(lastLine.contains(" info "))
    }

    @Test func captureItemRoundTripsAndPrefersEditedImage() throws {
        let original = URL(filePath: "/tmp/history/a/Snap.png")
        var item = CaptureItem(
            id: CaptureItem.makeID(date: FakeClock.defaultStartDate, timeZone: TimeZone(identifier: "UTC") ?? .gmt),
            createdAt: FakeClock.defaultStartDate, mode: .area, scale: 2, originalURL: original
        )
        #expect(item.id.hasPrefix("20261024-120000-"))
        #expect(item.currentURL == original)
        item.editedURL = URL(filePath: "/tmp/history/a/Snap (edited).png")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CaptureItem.self, from: encoder.encode(item))
        #expect(decoded == item)
        #expect(decoded.currentURL.lastPathComponent == "Snap (edited).png")
    }
}

@Suite struct FakesTests {
    @Test func fakeCaptureSourceReturnsNativePixelSizes() async throws {
        let source = FakeCaptureSource(displays: DisplayInfo.fakeSideBySide)
        let images = try await source.captureDisplays([1, 2], options: CaptureOptions())
        #expect(images.count == 2)
        #expect(images[0].pixelWidth == 5120 && images[0].pixelHeight == 2880 && images[0].scale == 2)
        #expect(images[1].pixelWidth == 3440 && images[1].pixelHeight == 1440 && images[1].scale == 1)
        #expect(images[0].pointSize == CGSize(width: 2560, height: 1440))
        let first = try #require(SyntheticImages.pixel(of: images[0].cgImage, x: 10, y: 10))
        let last = try #require(SyntheticImages.pixel(of: images[0].cgImage, x: 5100, y: 2870))
        #expect(first != last, "the fake desktop is a gradient, not a flat fill")
    }

    @Test func fakeCaptureSourceFailsOnDemand() async throws {
        let source = FakeCaptureSource(displays: [.fakeUltrawide], prerender: false)
        source.setFailure(.permissionDenied)
        await #expect(throws: CaptureError.permissionDenied) {
            _ = try await source.captureDisplay(2, options: CaptureOptions())
        }
        source.setFailure(nil)
        await #expect(throws: CaptureError.displayNotFound(9)) {
            _ = try await source.captureDisplay(9, options: CaptureOptions())
        }
    }

    @Test func fakeWindowCaptureGrowsByTheShadow() async throws {
        let source = FakeCaptureSource(displays: [.fake5K], prerender: false)
        let plain = try await source.captureWindow(202, options: CaptureOptions(includeWindowShadow: false))
        let shadowed = try await source.captureWindow(202, options: CaptureOptions(includeWindowShadow: true))
        #expect(plain.pixelWidth == 842 * 2 && plain.pixelHeight == 516 * 2)
        #expect(shadowed.pixelWidth > plain.pixelWidth)
        let corner = try #require(SyntheticImages.pixel(of: plain.cgImage, x: 0, y: 0))
        #expect(corner.alpha == 0, "window captures keep transparent corners")
    }

    @Test func fakeCaptureSourceWaitsOnItsClock() async throws {
        let clock = FakeClock()
        let source = FakeCaptureSource(displays: [.fakeUltrawide], delay: 0.5, clock: clock, prerender: false)
        let task = Task { try await source.captureDisplay(2, options: CaptureOptions()) }
        while clock.sleeperCount == 0 { await Task.yield() }
        clock.advance(by: 0.5)
        let image = try await task.value
        #expect(image.pixelWidth == 3440)
    }

    @Test func fakeClockWakesSleepersInOrderAndHonorsCancellation() async throws {
        let clock = FakeClock()
        let start = clock.date()
        let sleeper = Task { try await clock.sleep(seconds: 15) }
        while clock.sleeperCount == 0 { await Task.yield() }
        clock.advance(by: 10)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: 5)
        try await sleeper.value
        #expect(clock.now() == 15)
        #expect(clock.date().timeIntervalSince(start) == 15)

        let cancelled = Task { try await clock.sleep(seconds: 1) }
        while clock.sleeperCount == 0 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func fakeWindowSourceListsFrontToBack() async throws {
        let source = FakeWindowSource()
        let windows = try await source.snapshot()
        #expect(windows.map(\.order) == Array(0..<windows.count))
        #expect(windows.contains { $0.alpha == 0 && $0.ownerName == "Finder" })
        #expect(windows.contains { $0.layer == WindowLayer.desktopIcons })
        #expect(source.snapshotCount == 1)
    }

    @Test func displaySpecParses() throws {
        let display = try #require(DisplayInfo(spec: "5120x2880@2"))
        #expect(display.pointSize == CGSize(width: 2560, height: 1440))
        #expect(display.pixelWidth == 5120)
        #expect(DisplayInfo(spec: "3440x1440")?.scale == 1)
        #expect(DisplayInfo(spec: "axb@2") == nil)
        #expect(DisplayInfo(spec: "100x100@0") == nil)
    }

    @Test func fixturesHaveTheDesignSizes() throws {
        let block = try #require(SyntheticFixture.block2x.makeImage())
        #expect(block.width == 1200 && block.height == 800)
        #expect(SyntheticImages.pixel(of: block, x: 100, y: 100) == .red)
        #expect(SyntheticImages.pixel(of: block, x: 699, y: 499) == .red)
        #expect(SyntheticImages.pixel(of: block, x: 700, y: 500) == .white)
        #expect(SyntheticImages.pixel(of: block, x: 99, y: 99) == .white)
        let noise = try #require(SyntheticFixture.noise2x.makeImage())
        #expect(noise.width == 1200 && noise.height == 800)
        let window = try #require(SyntheticFixture.window2x.makeImage())
        #expect(SyntheticImages.pixel(of: window, x: 0, y: 0)?.alpha == 0)
        #expect(SyntheticImages.pixel(of: window, x: 600, y: 400)?.alpha == 255)
    }
}
