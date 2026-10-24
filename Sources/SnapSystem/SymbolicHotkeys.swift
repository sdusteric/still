import Carbon
import Foundation
import SnapCore

/// Reads the macOS system shortcuts through `CopySymbolicHotKeys` (design 12.3) so
/// `HotkeyConflicts` can warn about enabled ones that match Snap's combos. Read only: Snap never
/// rewrites `com.apple.symbolichotkeys`.
public enum SymbolicHotkeys {
    /// Dictionary keys of each entry, the values of the `kHISymbolicHotKey*` constants.
    public enum Key {
        public static let code = "kHISymbolicHotKeyCode"
        public static let modifiers = "kHISymbolicHotKeyModifiers"
        public static let enabled = "kHISymbolicHotKeyEnabled"
    }

    /// `CopySymbolicHotKeys` entries carry no id, so the screenshot ids are recovered from their
    /// macOS default combos (Carbon modifier bits), which name the exact setting to turn off.
    static let defaultIDs: [HotkeyCombo: Int] = {
        let command = KeyShortcut.Modifier.command
        let shift = KeyShortcut.Modifier.shift
        let control = KeyShortcut.Modifier.control
        return [
            HotkeyCombo(keyCode: KeyShortcut.KeyCode.ansi3, modifiers: command | shift): 28,
            HotkeyCombo(keyCode: KeyShortcut.KeyCode.ansi3, modifiers: command | shift | control): 29,
            HotkeyCombo(keyCode: KeyShortcut.KeyCode.ansi4, modifiers: command | shift): 30,
            HotkeyCombo(keyCode: KeyShortcut.KeyCode.ansi4, modifiers: command | shift | control): 31,
            HotkeyCombo(keyCode: KeyShortcut.KeyCode.ansi5, modifiers: command | shift): 184,
        ]
    }()

    /// Parses the array `CopySymbolicHotKeys` returns. Entries without a key code are skipped.
    /// Modifiers may come as Carbon bits or as Cocoa event flags (bit 16 and up); both are
    /// normalized to Carbon bits.
    public static func entries(from list: [[String: Any]]) -> [SymbolicHotkeyEntry] {
        list.compactMap { dictionary in
            guard let code = number(dictionary[Key.code]) else { return nil }
            let rawModifiers = number(dictionary[Key.modifiers]) ?? 0
            let modifiers = rawModifiers >= 1 << 16
                ? HotkeyCombo.carbonModifiers(fromEventFlags: UInt(rawModifiers))
                : UInt32(truncatingIfNeeded: rawModifiers) & HotkeyCombo.modifierMask
            let enabled = bool(dictionary[Key.enabled]) ?? true
            let combo = HotkeyCombo(keyCode: UInt32(truncatingIfNeeded: code), modifiers: modifiers)
            return SymbolicHotkeyEntry(
                id: defaultIDs[combo], keyCode: combo.keyCode, modifiers: combo.modifiers, enabled: enabled
            )
        }
    }

    /// The live system list. Empty (and logged by the caller) when the call fails.
    public static func read() -> Result<[SymbolicHotkeyEntry], SymbolicHotkeysError> {
        guard let copy = copyFunction else { return .failure(.unavailable) }
        var unmanaged: Unmanaged<CFArray>?
        let status = copy(&unmanaged)
        guard status == noErr, let array = unmanaged?.takeRetainedValue() else {
            return .failure(.status(status))
        }
        let list = (array as NSArray).compactMap { $0 as? [String: Any] }
        return .success(entries(from: list))
    }

    // MARK: Helpers

    private typealias CopyFunction = @convention(c) (UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus

    /// The function is exported by HIToolbox but no longer declared in the SDK headers.
    private static let copyFunction: CopyFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CopySymbolicHotKeys") else { return nil }
        return unsafeBitCast(symbol, to: CopyFunction.self)
    }()

    private static func number(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let int as Int: int
        case let uint as UInt32: Int(uint)
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        default: nil
        }
    }
}

public enum SymbolicHotkeysError: Error, Hashable, CustomStringConvertible {
    case unavailable
    case status(OSStatus)

    public var description: String {
        switch self {
        case .unavailable: "CopySymbolicHotKeys is not available"
        case .status(let status): "CopySymbolicHotKeys failed with OSStatus \(status)"
        }
    }
}
