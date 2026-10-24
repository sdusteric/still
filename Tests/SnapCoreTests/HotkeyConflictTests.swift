import Foundation
import SnapCore
import Testing

@Suite struct HotkeyConflictTests {
    static let cleanShot = "com.getcleanshot.app-setapp"
    static let cleanShotDirect = "pl.maketheweb.cleanshotx"

    /// This Mac: the macOS shortcuts for Cmd+Shift+3, 4 and 5 are off, Ctrl+Cmd+Shift+4 is on.
    static let thisMac: [SymbolicHotkeyEntry] = [
        SymbolicHotkeyEntry(id: 28, keyCode: 20, modifiers: shiftCommand, enabled: false),
        SymbolicHotkeyEntry(id: 30, keyCode: 21, modifiers: shiftCommand, enabled: false),
        SymbolicHotkeyEntry(id: 184, keyCode: 23, modifiers: shiftCommand, enabled: false),
        SymbolicHotkeyEntry(id: 31, keyCode: 21, modifiers: shiftCommand | KeyShortcut.Modifier.control, enabled: true),
    ]
    static let shiftCommand = KeyShortcut.Modifier.command | KeyShortcut.Modifier.shift

    private func evaluate(
        entries: [SymbolicHotkeyEntry] = thisMac,
        running: Set<String> = ["com.apple.finder"],
        shortcuts: ShortcutSettings = ShortcutSettings()
    ) -> HotkeyPlan {
        HotkeyConflicts.evaluate(shortcuts: shortcuts, systemEntries: entries, runningBundleIDs: running)
    }

    @Test func allDefaultCombosRegisterWhenNothingConflicts() {
        let plan = evaluate()
        #expect(plan.register[.captureArea] == HotkeyCombo(.commandShift4))
        #expect(plan.register[.captureWindow] == HotkeyCombo(.commandShift5))
        #expect(plan.register[.captureFullscreen] == HotkeyCombo(.commandShift3))
        #expect(plan.register.count == 3)
        #expect(plan.deferred.isEmpty)
        #expect(plan.warnings.isEmpty)
        #expect(plan.statusLine == nil)
    }

    @Test func unsetShortcutsAreNotRegistered() {
        var shortcuts = ShortcutSettings()
        shortcuts.captureWindow = nil
        let plan = evaluate(shortcuts: shortcuts)
        #expect(plan.register[.captureWindow] == nil)
        #expect(plan.register.count == 2)
    }

    @Test func disabledSystemShortcutsProduceNoWarning() {
        // Ctrl+Cmd+Shift+4 is enabled but Snap does not use it.
        #expect(evaluate().warnings.isEmpty)
    }

    @Test func enabledSystemShortcutWarnsButStillRegisters() {
        var entries = Self.thisMac
        entries[1].enabled = true
        let plan = evaluate(entries: entries)
        #expect(plan.register[.captureArea] == HotkeyCombo(.commandShift4))
        #expect(plan.warnings == [
            .systemShortcutEnabled(
                action: .captureArea, combo: HotkeyCombo(.commandShift4),
                systemName: "Save picture of selected area as a file"
            ),
        ])
        let message = plan.warnings[0].message
        #expect(message.contains("System Settings > Keyboard > Keyboard Shortcuts > Screenshots"))
        #expect(message.contains("Save picture of selected area as a file"))
    }

    @Test func systemShortcutIsMatchedByComboNotById() {
        let entries = [SymbolicHotkeyEntry(id: nil, keyCode: 20, modifiers: Self.shiftCommand, enabled: true)]
        let plan = evaluate(entries: entries)
        #expect(plan.warnings.count == 1)
        #expect(plan.warnings.first?.action == .captureFullscreen)
    }

    @Test func extraModifierBitsDoNotHideAConflict() {
        // Caps lock or function bits in the entry are ignored.
        let entries = [SymbolicHotkeyEntry(id: 30, keyCode: 21, modifiers: Self.shiftCommand | (1 << 10), enabled: true)]
        #expect(evaluate(entries: entries).warnings.count == 1)
    }

    @Test func runningCleanShotDefersItsCombos() {
        for bundleID in [Self.cleanShot, Self.cleanShotDirect] {
            let plan = evaluate(running: ["com.apple.finder", bundleID])
            #expect(plan.register.isEmpty)
            #expect(plan.deferred.count == 3)
            #expect(plan.isWaitingForCleanShot)
            #expect(plan.statusLine == "Waiting for CleanShot X to quit to take over its shortcuts")
            #expect(plan.warnings.count == 3)
        }
    }

    @Test func shortcutsCleanShotDoesNotUseRegisterWhileItRuns() {
        var shortcuts = ShortcutSettings()
        shortcuts.applyBackground = KeyShortcut(keyCode: 11, modifiers: Self.shiftCommand | KeyShortcut.Modifier.option)
        let plan = evaluate(running: [Self.cleanShot], shortcuts: shortcuts)
        #expect(plan.register.keys.contains(.applyBackground))
        #expect(plan.register.count == 1)
        #expect(plan.deferred.count == 3)
    }

    @Test func registrationFollowsWhenCleanShotQuits() {
        let running = evaluate(running: [Self.cleanShot])
        let quit = evaluate(running: [])
        #expect(running.register.isEmpty)
        #expect(quit.register.count == 3)
        #expect(quit.deferred.isEmpty)
    }

    @Test func otherAppsNeverDeferAnything() {
        let plan = evaluate(running: ["com.apple.Safari", "com.getcleanshot.other", "dev.sdusteric.snap"])
        #expect(plan.deferred.isEmpty)
        #expect(plan.register.count == 3)
    }

    @Test func customCleanShotCombosAreHonoured() {
        let custom: Set<HotkeyCombo> = [HotkeyCombo(.commandShift4)]
        let plan = HotkeyConflicts.evaluate(
            shortcuts: ShortcutSettings(), systemEntries: [], runningBundleIDs: [Self.cleanShot],
            cleanShotCombos: custom
        )
        #expect(plan.deferred.keys.contains(.captureArea))
        #expect(plan.register.count == 2)
    }

    @Test func systemWarningAndCleanShotDeferralCombine() {
        var entries = Self.thisMac
        entries[0].enabled = true
        let plan = evaluate(entries: entries, running: [Self.cleanShot])
        let forFullscreen = plan.warnings(for: .captureFullscreen)
        #expect(forFullscreen.count == 2)
        #expect(plan.deferred[.captureFullscreen] != nil)
    }

    @Test func duplicateCombosKeepTheFirstActionOnly() {
        var shortcuts = ShortcutSettings()
        shortcuts.applyBackground = .commandShift4
        let plan = evaluate(shortcuts: shortcuts)
        #expect(plan.register[.applyBackground] == nil)
        #expect(plan.register[.captureArea] != nil)
        #expect(plan.warnings == [
            .duplicate(action: .applyBackground, combo: HotkeyCombo(.commandShift4), sameAs: .captureArea),
        ])
    }

    @Test func menuStatusPrefersPermissionThenCleanShotThenSystemOverlap() {
        let waiting = evaluate(running: [Self.cleanShot])
        var entries = Self.thisMac
        entries[1].enabled = true
        let overlap = evaluate(entries: entries)

        #expect(MenuModel(MenuInput(permissionNeeded: true, plan: waiting)).status == .permissionNeeded)
        #expect(MenuModel(MenuInput(plan: waiting)).status == .waitingForCleanShot)
        #expect(MenuModel(MenuInput(plan: overlap)).status == .systemShortcutOverlap)
        #expect(MenuModel(MenuInput(plan: evaluate())).status == nil)
    }
}

@Suite struct HotkeyComboTests {
    @Test func displayStringUsesMacModifierOrder() {
        #expect(HotkeyCombo(.commandShift4).displayString == "\u{21E7}\u{2318}4")
        let all = HotkeyCombo(
            keyCode: 0,
            modifiers: KeyShortcut.Modifier.command | KeyShortcut.Modifier.shift
                | KeyShortcut.Modifier.option | KeyShortcut.Modifier.control
        )
        #expect(all.displayString == "\u{2303}\u{2325}\u{21E7}\u{2318}A")
        #expect(all.plainString == "Ctrl+Option+Cmd+Shift+A")
        #expect(HotkeyCombo(.commandShift5).plainString == "Cmd+Shift+5")
    }

    @Test func specialKeysHaveNames() {
        #expect(HotkeyCombo(keyCode: 49, modifiers: 0).displayString == "Space")
        #expect(HotkeyCombo(keyCode: 122, modifiers: KeyShortcut.Modifier.command).displayString == "\u{2318}F1")
        #expect(HotkeyCombo(keyCode: 124, modifiers: 0).keyName == "\u{2192}")
        #expect(HotkeyCombo(keyCode: 250, modifiers: 0).keyName == "Key 250")
    }

    @Test func comboIgnoresUnrelatedModifierBitsAndRoundTripsShortcuts() {
        let noisy = HotkeyCombo(keyCode: 21, modifiers: KeyShortcut.Modifier.command | (1 << 10) | (1 << 4))
        #expect(noisy == HotkeyCombo(keyCode: 21, modifiers: KeyShortcut.Modifier.command))
        #expect(HotkeyCombo(.commandShift3).shortcut == .commandShift3)
        #expect(KeyShortcut.commandShift4.combo == HotkeyCombo(.commandShift4))
    }

    @Test func menuKeyEquivalentsComeFromTheKeyCode() {
        #expect(HotkeyCombo(.commandShift4).keyEquivalent == "4")
        #expect(HotkeyCombo(keyCode: 122, modifiers: 0).keyEquivalent == nil)
        let equivalent = MenuKeyEquivalent(HotkeyCombo(.commandShift4))
        #expect(equivalent == MenuKeyEquivalent(key: "4", command: true, shift: true))
        #expect(equivalent?.displayString == "\u{21E7}\u{2318}4")
    }

    @Test func cocoaFlagsConvertToCarbonBitsAndBack() {
        // 1179648 is what the symbolic hotkey plist stores for Shift+Command.
        let carbon = HotkeyCombo.carbonModifiers(fromEventFlags: 1_179_648)
        #expect(carbon == KeyShortcut.Modifier.command | KeyShortcut.Modifier.shift)
        #expect(HotkeyCombo.eventFlags(fromCarbonModifiers: carbon) == 1_179_648)
        #expect(HotkeyCombo.carbonModifiers(fromEventFlags: 0) == 0)
        let control = HotkeyCombo.carbonModifiers(fromEventFlags: 1_179_648 | 262_144)
        #expect(control & KeyShortcut.Modifier.control != 0)
    }
}
