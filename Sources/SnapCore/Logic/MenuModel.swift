import Foundation

/// A menu key equivalent: the character and the modifiers `NSMenuItem` shows.
public struct MenuKeyEquivalent: Sendable, Hashable {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Nil when the combo's key has no printable character.
    public init?(_ combo: HotkeyCombo) {
        guard let key = combo.keyEquivalent else { return nil }
        self.init(
            key: key, command: combo.hasCommand, shift: combo.hasShift, option: combo.hasOption,
            control: combo.hasControl
        )
    }

    public var displayString: String {
        HotkeyCombo(keyCode: 0, modifiers: modifierBits).modifierSymbols + key.uppercased()
    }

    var modifierBits: UInt32 {
        (command ? KeyShortcut.Modifier.command : 0) | (shift ? KeyShortcut.Modifier.shift : 0)
            | (option ? KeyShortcut.Modifier.option : 0) | (control ? KeyShortcut.Modifier.control : 0)
    }
}

public enum MenuItemID: Sendable, Hashable {
    case captureArea, captureWindow, captureFullscreen
    case applyBackground, openInAnnotate
    case recentCapturesHeader
    case recentCapture(String)
    case noRecentCaptures
    case openHistoryFolder
    case status
    case checkForUpdates
    case settings, quit
    case separator(Int)

    /// The shortcut action behind a capture or editing item, if any.
    public var shortcutAction: ShortcutAction? {
        switch self {
        case .captureArea: .captureArea
        case .captureWindow: .captureWindow
        case .captureFullscreen: .captureFullscreen
        case .applyBackground: .applyBackground
        case .openInAnnotate: .openInAnnotate
        default: nil
        }
    }
}

public struct MenuItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case action
        case separator
        /// The line that appears when something needs attention.
        case status
        /// A section heading ("Recent Captures"), not clickable.
        case header
    }

    public var id: MenuItemID
    public var kind: Kind
    public var title: String
    public var keyEquivalent: MenuKeyEquivalent?
    /// How the shortcut reads in a menu preview, for example Command, Shift and 4. Also set when
    /// the key has no key equivalent character.
    public var shortcutText: String?
    public var isEnabled: Bool
    /// Second line of a Recent Captures entry, such as "2 minutes ago".
    public var subtitle: String?
    /// The capture a Recent Captures entry stands for.
    public var captureID: String?

    public init(
        id: MenuItemID,
        kind: Kind = .action,
        title: String,
        keyEquivalent: MenuKeyEquivalent? = nil,
        shortcutText: String? = nil,
        isEnabled: Bool = true,
        subtitle: String? = nil,
        captureID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.shortcutText = shortcutText
        self.isEnabled = isEnabled
        self.subtitle = subtitle
        self.captureID = captureID
    }
}

/// The one status line the menu can show (design 12.1 item 9), in priority order. The CleanShot
/// text is the mockup's short form so it fits the 280 pt menu; settings carry the full sentence.
public enum MenuStatus: Sendable, Hashable {
    case permissionNeeded
    case waitingForCleanShot
    /// An enabled macOS shortcut uses one of Snap's combos.
    case systemShortcutOverlap

    public var title: String {
        switch self {
        case .permissionNeeded: "Screen Recording permission needed"
        case .waitingForCleanShot: "Waiting for CleanShot X to quit"
        case .systemShortcutOverlap: "A macOS shortcut overlaps Snap's. See Settings."
        }
    }

    /// Whether clicking the line does something (opens the System Settings pane or Snap's settings).
    public var isClickable: Bool { self != .waitingForCleanShot }
}

/// Everything the menu depends on.
public struct MenuInput: Sendable {
    public var shortcuts: ShortcutSettings
    /// Newest first; the menu shows the first three.
    public var recentCaptures: [CaptureItem]
    /// Enables "Apply Background to Last Capture" and "Open Last Capture in Annotate".
    public var hasLastCapture: Bool
    public var permissionNeeded: Bool
    public var plan: HotkeyPlan?
    /// Shows "Check for Updates..." above Settings. Only the app's updater turns it on.
    public var offersUpdates: Bool
    public var now: Date
    public var timeZone: TimeZone

    public init(
        shortcuts: ShortcutSettings = ShortcutSettings(),
        recentCaptures: [CaptureItem] = [],
        hasLastCapture: Bool? = nil,
        permissionNeeded: Bool = false,
        plan: HotkeyPlan? = nil,
        offersUpdates: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        self.shortcuts = shortcuts
        self.recentCaptures = recentCaptures
        self.hasLastCapture = hasLastCapture ?? !recentCaptures.isEmpty
        self.permissionNeeded = permissionNeeded
        self.plan = plan
        self.offersUpdates = offersUpdates
        self.now = now
        self.timeZone = timeZone
    }
}

/// The menu bar menu as data (design 12.1). `StatusMenuController` builds an `NSMenu` from it and
/// `MenuPreviewView` draws the same items in shot mode.
public struct MenuModel: Sendable, Hashable {
    public static let recentLimit = 3

    public let items: [MenuItem]
    public let status: MenuStatus?

    public init(_ input: MenuInput) {
        let status = MenuModel.status(for: input)
        self.status = status

        var items: [MenuItem] = [
            MenuModel.actionItem(.captureArea, title: "Capture Area", input),
            MenuModel.actionItem(.captureWindow, title: "Capture Window", input),
            MenuModel.actionItem(.captureFullscreen, title: "Capture Fullscreen", input),
            MenuItem(id: .separator(1), kind: .separator, title: ""),
            MenuModel.actionItem(
                .applyBackground, title: "Apply Background to Last Capture", input, enabled: input.hasLastCapture
            ),
            MenuModel.actionItem(
                .openInAnnotate, title: "Open Last Capture in Annotate", input, enabled: input.hasLastCapture
            ),
            MenuItem(id: .separator(2), kind: .separator, title: ""),
        ]
        items.append(contentsOf: MenuModel.recentItems(input))
        items.append(MenuItem(id: .separator(3), kind: .separator, title: ""))
        if let status {
            items.append(MenuItem(id: .status, kind: .status, title: status.title, isEnabled: status.isClickable))
            items.append(MenuItem(id: .separator(4), kind: .separator, title: ""))
        }
        if input.offersUpdates {
            items.append(MenuItem(id: .checkForUpdates, title: "Check for Updates\u{2026}"))
        }
        items.append(MenuItem(
            id: .settings, title: "Settings\u{2026}",
            keyEquivalent: MenuKeyEquivalent(key: ",", command: true), shortcutText: "\u{2318},"
        ))
        items.append(MenuItem(
            id: .quit, title: "Quit Snap",
            keyEquivalent: MenuKeyEquivalent(key: "q", command: true), shortcutText: "\u{2318}Q"
        ))
        self.items = items
    }

    public func item(_ id: MenuItemID) -> MenuItem? {
        items.first { $0.id == id }
    }

    static func status(for input: MenuInput) -> MenuStatus? {
        if input.permissionNeeded { return .permissionNeeded }
        guard let plan = input.plan else { return nil }
        if plan.isWaitingForCleanShot { return .waitingForCleanShot }
        let overlaps = plan.warnings.contains {
            if case .systemShortcutEnabled = $0 { return true }
            return false
        }
        return overlaps ? .systemShortcutOverlap : nil
    }

    private static func actionItem(_ id: MenuItemID, title: String, _ input: MenuInput, enabled: Bool = true) -> MenuItem {
        var item = MenuItem(id: id, title: title, isEnabled: enabled)
        if let action = id.shortcutAction, let shortcut = input.shortcuts[action] {
            let combo = HotkeyCombo(shortcut)
            item.keyEquivalent = MenuKeyEquivalent(combo)
            item.shortcutText = combo.displayString
        }
        return item
    }

    private static func recentItems(_ input: MenuInput) -> [MenuItem] {
        let recent = Array(input.recentCaptures.prefix(recentLimit))
        var result = [MenuItem(id: .recentCapturesHeader, kind: .header, title: "Recent Captures", isEnabled: false)]
        if recent.isEmpty {
            result.append(MenuItem(id: .noRecentCaptures, title: "No Recent Captures", isEnabled: false))
        } else {
            for capture in recent {
                result.append(MenuItem(
                    id: .recentCapture(capture.id),
                    title: capture.originalURL.deletingPathExtension().lastPathComponent,
                    subtitle: relativeTime(capture.createdAt, now: input.now, timeZone: input.timeZone),
                    captureID: capture.id
                ))
            }
        }
        result.append(MenuItem(id: .openHistoryFolder, title: "Open History Folder"))
        return result
    }

    /// "Just now", "2 minutes ago", "Today, 11:48", "Yesterday, 09:15" or "Oct 22, 16:30".
    public static func relativeTime(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let age = now.timeIntervalSince(date)
        if age >= 0 && age < 60 { return "Just now" }
        if age >= 60 && age < 3600 {
            let minutes = Int(age / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(time)" }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month = months[min(max((parts.month ?? 1) - 1, 0), 11)]
        return "\(month) \(parts.day ?? 1), \(time)"
    }
}
