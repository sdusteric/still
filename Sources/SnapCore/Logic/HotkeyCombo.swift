import Foundation

/// A key code and a Carbon modifier mask, the pair `RegisterEventHotKey` takes (design 12.3).
/// It converts to and from the stored `KeyShortcut` and renders the string shown in menus and
/// settings, such as the Cmd+Shift+4 combo as the symbols for Command, Shift and 4.
public struct HotkeyCombo: Sendable, Hashable, Codable {
    /// Modifier bits that count; everything else (caps lock, function) is ignored when comparing.
    public static let modifierMask: UInt32 =
        KeyShortcut.Modifier.command | KeyShortcut.Modifier.shift | KeyShortcut.Modifier.option | KeyShortcut.Modifier.control

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & HotkeyCombo.modifierMask
    }

    public init(_ shortcut: KeyShortcut) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    public var shortcut: KeyShortcut { KeyShortcut(keyCode: keyCode, modifiers: modifiers) }

    public var hasCommand: Bool { modifiers & KeyShortcut.Modifier.command != 0 }
    public var hasShift: Bool { modifiers & KeyShortcut.Modifier.shift != 0 }
    public var hasOption: Bool { modifiers & KeyShortcut.Modifier.option != 0 }
    public var hasControl: Bool { modifiers & KeyShortcut.Modifier.control != 0 }

    /// The modifier symbols in the order macOS shows them (Control, Option, Shift, Command).
    public var modifierSymbols: String {
        var text = ""
        if hasControl { text += "\u{2303}" }
        if hasOption { text += "\u{2325}" }
        if hasShift { text += "\u{21E7}" }
        if hasCommand { text += "\u{2318}" }
        return text
    }

    /// The key on its own, such as "4", "A", "Space" or the arrow glyph; "Key 60" for an unknown code.
    public var keyName: String {
        HotkeyCombo.keyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// For example the symbols for Command and Shift followed by 4.
    public var displayString: String { modifierSymbols + keyName }

    /// Spelled out as the design writes it, for log lines and accessibility: "Cmd+Shift+4".
    public var plainString: String {
        var parts: [String] = []
        if hasControl { parts.append("Ctrl") }
        if hasOption { parts.append("Option") }
        if hasCommand { parts.append("Cmd") }
        if hasShift { parts.append("Shift") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    /// The character an `NSMenuItem` uses as its key equivalent (lower case), nil for keys without
    /// a printable character.
    public var keyEquivalent: String? {
        HotkeyCombo.keyEquivalents[keyCode]
    }

    // MARK: Event flag conversion

    /// Cocoa modifier flag bits, which `CopySymbolicHotKeys` and `NSEvent` use.
    public enum EventFlag {
        public static let shift: UInt32 = 1 << 17
        public static let control: UInt32 = 1 << 18
        public static let option: UInt32 = 1 << 19
        public static let command: UInt32 = 1 << 20
    }

    /// Converts Cocoa modifier flag bits (`NSEvent.ModifierFlags.rawValue`, the symbolic hotkey
    /// plist's modifiers) to the Carbon bits `RegisterEventHotKey` takes.
    public static func carbonModifiers(fromEventFlags flags: UInt) -> UInt32 {
        let value = UInt32(truncatingIfNeeded: flags)
        var result: UInt32 = 0
        if value & EventFlag.command != 0 { result |= KeyShortcut.Modifier.command }
        if value & EventFlag.shift != 0 { result |= KeyShortcut.Modifier.shift }
        if value & EventFlag.option != 0 { result |= KeyShortcut.Modifier.option }
        if value & EventFlag.control != 0 { result |= KeyShortcut.Modifier.control }
        return result
    }

    public static func eventFlags(fromCarbonModifiers modifiers: UInt32) -> UInt {
        var result: UInt32 = 0
        if modifiers & KeyShortcut.Modifier.command != 0 { result |= EventFlag.command }
        if modifiers & KeyShortcut.Modifier.shift != 0 { result |= EventFlag.shift }
        if modifiers & KeyShortcut.Modifier.option != 0 { result |= EventFlag.option }
        if modifiers & KeyShortcut.Modifier.control != 0 { result |= EventFlag.control }
        return UInt(result)
    }

    // MARK: Key tables (ANSI virtual key codes)

    private static let printableKeys: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`", 49: " ",
    ]

    private static let keyEquivalents: [UInt32: String] = printableKeys

    private static let keyNames: [UInt32: String] = {
        var names = printableKeys.mapValues { $0.uppercased() }
        names[49] = "Space"
        let special: [UInt32: String] = [
            36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "Forward Delete",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names.merging(special) { _, new in new }
    }()
}

extension KeyShortcut {
    public var combo: HotkeyCombo { HotkeyCombo(self) }
}
