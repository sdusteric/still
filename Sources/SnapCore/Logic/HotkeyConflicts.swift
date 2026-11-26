import Foundation

/// One entry of `CopySymbolicHotKeys()`: a macOS system shortcut and whether it is switched on.
/// `modifiers` are Carbon bits; `SnapSystem` converts the plist's Cocoa flags with
/// `HotkeyCombo.carbonModifiers(fromEventFlags:)`.
public struct SymbolicHotkeyEntry: Sendable, Hashable {
    public var id: Int?
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var enabled: Bool

    public init(id: Int? = nil, keyCode: UInt32, modifiers: UInt32, enabled: Bool) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }

    public var combo: HotkeyCombo { HotkeyCombo(keyCode: keyCode, modifiers: modifiers) }
}

/// What `HotkeyConflicts` found wrong with a combo, shown in settings and the menu.
public enum HotkeyWarning: Sendable, Hashable {
    /// An enabled macOS shortcut uses the combo. Snap still registers it; the user turns the
    /// system one off.
    case systemShortcutEnabled(action: ShortcutAction, combo: HotkeyCombo, systemName: String)
    /// CleanShot X is running, so the combo is not registered yet.
    case waitingForCleanShot(action: ShortcutAction, combo: HotkeyCombo)
    /// Two actions use the same combo; the later action in `ShortcutAction.allCases` order is skipped.
    case duplicate(action: ShortcutAction, combo: HotkeyCombo, sameAs: ShortcutAction)

    public var action: ShortcutAction {
        switch self {
        case .systemShortcutEnabled(let action, _, _), .waitingForCleanShot(let action, _),
             .duplicate(let action, _, _):
            action
        }
    }

    /// The text for settings. It names the exact place to turn a system shortcut off.
    public var message: String {
        switch self {
        case .systemShortcutEnabled(_, let combo, let systemName):
            "\(combo.displayString) is also the macOS shortcut \"\(systemName)\". Turn it off in "
                + "System Settings > Keyboard > Keyboard Shortcuts > Screenshots."
        case .waitingForCleanShot(_, let combo):
            "\(combo.displayString) is waiting for CleanShot X to quit."
        case .duplicate(_, let combo, let sameAs):
            "\(combo.displayString) is already used by \(sameAs.title)."
        }
    }
}

/// The outcome of checking Snap's shortcuts against macOS and CleanShot (design 12.3).
public struct HotkeyPlan: Sendable, Hashable {
    /// Combos to register now.
    public var register: [ShortcutAction: HotkeyCombo]
    /// Combos held back while CleanShot X runs; register them when it quits.
    public var deferred: [ShortcutAction: HotkeyCombo]
    public var warnings: [HotkeyWarning]

    public var isWaitingForCleanShot: Bool { !deferred.isEmpty }

    /// The registered action for a key press (Carbon modifier bits), for the time Still's own menu
    /// is open: macOS holds hotkey events until the menu closes, so the keys are matched here.
    public func action(keyCode: UInt32, modifiers: UInt32) -> ShortcutAction? {
        let pressed = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        return register.first { $0.value == pressed }?.key
    }

    /// The menu status line, nil when nothing needs attention.
    public var statusLine: String? {
        isWaitingForCleanShot ? HotkeyConflicts.waitingStatusLine : nil
    }

    public func warnings(for action: ShortcutAction) -> [HotkeyWarning] {
        warnings.filter { $0.action == action }
    }
}

/// Decides which of Snap's combos to register now. Pure: the symbolic hotkey entries and the
/// running bundle ids are injected.
public enum HotkeyConflicts {
    public static let cleanShotBundleIDs: Set<String> = ["com.getcleanshot.app-setapp", "pl.maketheweb.cleanshotx"]
    public static let waitingStatusLine = "Waiting for CleanShot X to quit to take over its shortcuts"

    /// CleanShot's fullscreen, area and all-in-one combos (key codes 20, 21 and 23, Cmd+Shift).
    public static let cleanShotDefaultCombos: Set<HotkeyCombo> = [
        HotkeyCombo(.commandShift3), HotkeyCombo(.commandShift4), HotkeyCombo(.commandShift5),
    ]

    /// Names of the macOS screenshot shortcuts, by symbolic hotkey id.
    static let systemNames: [Int: String] = [
        28: "Save picture of screen as a file",
        29: "Copy picture of screen to the clipboard",
        30: "Save picture of selected area as a file",
        31: "Copy picture of selected area to the clipboard",
        184: "Screenshot and recording options",
    ]
    static let genericSystemName = "Keyboard shortcut"

    public static func isCleanShotRunning(_ runningBundleIDs: Set<String>) -> Bool {
        !runningBundleIDs.isDisjoint(with: cleanShotBundleIDs)
    }

    public static func evaluate(
        shortcuts: ShortcutSettings,
        systemEntries: [SymbolicHotkeyEntry],
        runningBundleIDs: Set<String>,
        cleanShotCombos: Set<HotkeyCombo> = cleanShotDefaultCombos
    ) -> HotkeyPlan {
        let cleanShotRunning = isCleanShotRunning(runningBundleIDs)
        let enabledEntries = systemEntries.filter(\.enabled)
        var plan = HotkeyPlan(register: [:], deferred: [:], warnings: [])
        var claimed: [HotkeyCombo: ShortcutAction] = [:]

        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            let combo = HotkeyCombo(shortcut)
            if let owner = claimed[combo] {
                plan.warnings.append(.duplicate(action: action, combo: combo, sameAs: owner))
                continue
            }
            claimed[combo] = action

            if let entry = enabledEntries.first(where: { $0.combo == combo }) {
                let name = entry.id.flatMap { systemNames[$0] } ?? genericSystemName
                plan.warnings.append(.systemShortcutEnabled(action: action, combo: combo, systemName: name))
            }
            if cleanShotRunning && cleanShotCombos.contains(combo) {
                plan.deferred[action] = combo
                plan.warnings.append(.waitingForCleanShot(action: action, combo: combo))
            } else {
                plan.register[action] = combo
            }
        }
        return plan
    }
}
