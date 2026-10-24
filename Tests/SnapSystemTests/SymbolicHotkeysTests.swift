import Foundation
import SnapCore
import SnapSystem
import Testing

// Only injected dictionaries: the live CopySymbolicHotKeys list is never read here.
@Suite struct SymbolicHotkeysTests {
    let command = KeyShortcut.Modifier.command
    let shift = KeyShortcut.Modifier.shift
    let control = KeyShortcut.Modifier.control

    /// The shape of this Mac's list: 28, 30 and 184 off, 31 on, plus an unrelated shortcut.
    var sample: [[String: Any]] {
        [
            entry(code: 20, modifiers: 768, enabled: false),
            entry(code: 21, modifiers: 768, enabled: false),
            entry(code: 21, modifiers: 768 | 4096, enabled: true),
            entry(code: 23, modifiers: 768, enabled: false),
            entry(code: 49, modifiers: 256, enabled: true),
        ]
    }

    func entry(code: Int, modifiers: Int, enabled: Bool) -> [String: Any] {
        [
            SymbolicHotkeys.Key.code: NSNumber(value: code),
            SymbolicHotkeys.Key.modifiers: NSNumber(value: modifiers),
            SymbolicHotkeys.Key.enabled: NSNumber(value: enabled),
        ]
    }

    @Test func parsesCodesModifiersAndEnabledFlags() {
        let entries = SymbolicHotkeys.entries(from: sample)
        #expect(entries.count == 5)
        #expect(entries[0].keyCode == 20)
        #expect(entries[0].modifiers == command | shift)
        #expect(entries[0].enabled == false)
        #expect(entries[2].modifiers == command | shift | control)
        #expect(entries[2].enabled)
        #expect(entries[4].combo == HotkeyCombo(keyCode: 49, modifiers: command))
    }

    @Test func recoversScreenshotIDsFromDefaultCombos() {
        let ids = SymbolicHotkeys.entries(from: sample).map(\.id)
        #expect(ids == [28, 30, 31, 184, nil])
    }

    @Test func acceptsCocoaEventFlags() {
        let cocoaCommandShift = Int(HotkeyCombo.EventFlag.command | HotkeyCombo.EventFlag.shift)
        let entries = SymbolicHotkeys.entries(from: [entry(code: 21, modifiers: cocoaCommandShift, enabled: true)])
        #expect(entries.first?.combo == HotkeyCombo(.commandShift4))
        #expect(entries.first?.id == 30)
    }

    @Test func skipsMalformedEntriesAndDefaultsToEnabled() {
        let list: [[String: Any]] = [
            [SymbolicHotkeys.Key.modifiers: NSNumber(value: 768)],
            [SymbolicHotkeys.Key.code: "not a number"],
            [SymbolicHotkeys.Key.code: NSNumber(value: 23), SymbolicHotkeys.Key.modifiers: NSNumber(value: 768)],
        ]
        let entries = SymbolicHotkeys.entries(from: list)
        #expect(entries.count == 1)
        #expect(entries.first?.enabled == true)
        #expect(entries.first?.id == 184)
    }

    @Test func parsedEntriesDriveTheConflictPlan() {
        let entries = SymbolicHotkeys.entries(from: sample)
        let plan = HotkeyConflicts.evaluate(shortcuts: ShortcutSettings(), systemEntries: entries, runningBundleIDs: [])
        // 28, 30 and 184 are disabled on this Mac, so Snap's defaults raise no system warning.
        #expect(!plan.warnings.contains { if case .systemShortcutEnabled = $0 { true } else { false } })
        #expect(plan.register.count == 3)

        let enabledArea = SymbolicHotkeys.entries(from: [entry(code: 21, modifiers: 768, enabled: true)])
        let warned = HotkeyConflicts.evaluate(shortcuts: ShortcutSettings(), systemEntries: enabledArea, runningBundleIDs: [])
        #expect(warned.warnings.contains(.systemShortcutEnabled(
            action: .captureArea, combo: HotkeyCombo(.commandShift4), systemName: "Save picture of selected area as a file"
        )))
    }

    @Test func registrationMessagesNameTheFailure() {
        #expect(HotkeyCenter.describe(0) == "Registered")
        #expect(HotkeyCenter.describe(-9878).contains("Another app"))
        #expect(HotkeyCenter.describe(-1).contains("-1"))
    }

    @Test func conflictingAppsMatchesOnlyCleanShot() {
        let running: [String?] = ["com.apple.finder", nil, "pl.maketheweb.cleanshotx", "dev.sdusteric.snap"]
        #expect(ConflictingApps.matching(running, watched: HotkeyConflicts.cleanShotBundleIDs) == ["pl.maketheweb.cleanshotx"])
        #expect(ConflictingApps.matching(["com.apple.finder"], watched: HotkeyConflicts.cleanShotBundleIDs).isEmpty)
    }
}
