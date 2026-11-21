import Foundation
import SnapCore
import Testing

/// A fresh directory under SNAP_HOME (or the temp dir), removed by its exact path when done.
private final class MigrationScratch {
    let url: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["SNAP_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        url = base.appending(path: "migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
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

@Suite struct SettingsMigrationTests {
    static let custom = KeyShortcut(keyCode: 13, modifiers: KeyShortcut.Modifier.control | KeyShortcut.Modifier.shift)

    /// The shortcuts block exactly as M1 wrote it, every key present.
    static func version1JSON(captureWindow: String) -> String {
        """
        {"version": 1, "capture": {"copyToClipboard": false},
         "shortcuts": {"captureArea": {"keyCode": 21, "modifiers": 768}, "captureFullscreen": {"keyCode": 20, "modifiers": 768},
                       "captureWindow": \(captureWindow), "applyBackground": null, "openInAnnotate": null}}
        """
    }

    func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func theMagnifierIsOffByDefaultAndAVersion2FileTurnsItOff() throws {
        #expect(!Settings().capture.showMagnifier)
        // Version 2 files stored the old default (on) without the user choosing it.
        let settings = try decode(#"{"version": 2, "capture": {"showMagnifier": true, "copyToClipboard": false}}"#)
        #expect(!settings.capture.showMagnifier)
        #expect(!settings.capture.copyToClipboard, "other settings are kept")
        #expect(settings.version == Settings.currentVersion)
        // Once saved as the current version, the user's choice stands.
        let chosen = try decode(#"{"version": \#(Settings.currentVersion), "capture": {"showMagnifier": true}}"#)
        #expect(chosen.capture.showMagnifier)
    }

    @Test func anUnchangedCommandShift5MovesFromCaptureWindowToAllInOne() throws {
        let settings = try decode(Self.version1JSON(captureWindow: #"{"keyCode": 23, "modifiers": 768}"#))
        #expect(settings.version == Settings.currentVersion)
        #expect(settings.shortcuts.allInOne == .commandShift5)
        #expect(settings.shortcuts.captureWindow == nil)
        #expect(settings.shortcuts.captureArea == .commandShift4)
        #expect(settings.shortcuts.captureFullscreen == .commandShift3)
        #expect(settings.capture.copyToClipboard == false, "other settings carry over")
        #expect(settings.recording == RecordingSettings())
        #expect(settings.annotate == AnnotateSettings())
    }

    @Test func aCustomCaptureWindowShortcutIsLeftAlone() throws {
        let settings = try decode(Self.version1JSON(captureWindow: #"{"keyCode": 13, "modifiers": 4608}"#))
        #expect(settings.shortcuts.captureWindow == Self.custom)
        #expect(settings.shortcuts.allInOne == nil)
    }

    @Test func aClearedCaptureWindowStaysClearedAndAllInOneStaysUnset() throws {
        let settings = try decode(Self.version1JSON(captureWindow: "null"))
        #expect(settings.shortcuts.captureWindow == nil)
        #expect(settings.shortcuts.allInOne == nil)
    }

    @Test func aVersion1FileWithoutShortcutsGetsTheVersion2Defaults() throws {
        let settings = try decode(#"{"version": 1}"#)
        #expect(settings.shortcuts == ShortcutSettings())
        #expect(settings == Settings())
    }

    @Test func theMigrationIsPureAndLeavesVersion2Alone() {
        var version1 = Settings(version: 1, shortcuts: ShortcutSettings.version1Defaults)
        version1.shortcuts.openInAnnotate = Self.custom
        let migrated = SettingsMigration.migrate(version1, from: 1)
        #expect(migrated.shortcuts.allInOne == .commandShift5)
        #expect(migrated.shortcuts.captureWindow == nil)
        #expect(migrated.shortcuts.openInAnnotate == Self.custom)
        #expect(migrated.version == Settings.currentVersion)
        #expect(SettingsMigration.migrate(migrated, from: 2) == migrated)

        var custom = Settings()
        custom.shortcuts.captureWindow = .commandShift5
        custom.shortcuts.allInOne = nil
        #expect(SettingsMigration.migrate(custom, from: 2) == custom, "a version 2 choice is never migrated")
    }

    @Test func aMigratedFileIsWrittenAsTheCurrentVersionOnTheNextChange() throws {
        let scratch = try MigrationScratch()
        let url = scratch.file("settings.json")
        try Data(Self.version1JSON(captureWindow: #"{"keyCode": 23, "modifiers": 768}"#).utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        #expect(try store.load() == .loaded)
        #expect(store.settings.shortcuts.allInOne == .commandShift5)
        try store.update { $0.recording.countdownSeconds = 5 }

        let reloaded = SettingsStore(fileURL: url)
        #expect(try reloaded.load() == .loaded)
        #expect(reloaded.settings == store.settings)
        #expect(reloaded.settings.shortcuts.captureWindow == nil, "the moved shortcut is not moved back")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""version" : \#(Settings.currentVersion)"#))
        #expect(text.contains(#""allInOne""#))
    }

    @Test func version2RecordingAndAnnotateDefaultsMatchTheDesign() {
        let recording = RecordingSettings()
        #expect(recording.format == .h264)
        #expect(recording.format.fourCC == "avc1")
        #expect(VideoFormat.hevc.fourCC == "hvc1")
        #expect(recording.fps == 30)
        #expect(recording.scale == .retina)
        #expect(recording.countdownSeconds == 3)
        #expect(recording.showCursor)
        #expect(recording.highlightClicks)
        #expect(!recording.systemAudio)
        #expect(!recording.microphone)
        #expect(recording.microphoneDeviceID == nil)
        #expect(recording.audioSources.isEmpty)
        let annotate = AnnotateSettings()
        #expect(annotate.redactStyle == .pixelate)
        #expect(annotate.highlightColor == RGBAColor(hex: "#FFD60A"))
        #expect(RedactStyle.pixelate.next == .blur)
        #expect(RedactStyle.blackout.next == .pixelate)
    }

    @Test func badRecordingValuesFallBackInsteadOfDiscardingTheFile() throws {
        let json = """
            {"version": 2, "recording": {"format": "prores", "fps": 24, "scale": "1x", "countdownSeconds": 4,
             "systemAudio": true, "microphone": true, "microphoneDeviceID": "BuiltInMic"},
             "annotate": {"redactStyle": "smudge"}}
            """
        let settings = try decode(json)
        #expect(settings.recording.format == .h264)
        #expect(settings.recording.fps == 30)
        #expect(settings.recording.scale == .oneX)
        #expect(settings.recording.countdownSeconds == 3)
        #expect(settings.recording.audioSources == [.system, .microphone])
        #expect(settings.recording.microphoneDeviceID == "BuiltInMic")
        #expect(settings.annotate.redactStyle == .pixelate)
        #expect(RecordingSettings(fps: 60, countdownSeconds: 5).fps == 60)
        #expect(RecordingSettings(countdownSeconds: 0).countdownSeconds == 0)
    }
}
