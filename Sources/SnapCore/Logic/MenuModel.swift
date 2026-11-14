import CoreGraphics
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
    case capturePreviousArea
    /// Copies the text in the last screenshot (read on this Mac with Vision).
    case copyLastCaptureText
    /// An image file, or the clipboard's image, becomes a capture with its card.
    case openImage, openClipboardImage
    /// Under the permission status line: quits and reopens Snap so macOS applies a new grant.
    case relaunch
    /// "All-in-One..." opens the HUD (design 20.5).
    case allInOne
    /// "Record Screen..." opens the HUD in Record mode; it reads "Stop Recording" while recording.
    case recordScreen
    case applyBackground, openInAnnotate
    case pinLastCapture
    case recentCapturesHeader
    case recentCapture(String)
    case noRecentCaptures
    /// M1's history folder item; in M2 the folder opens from the history window's footer.
    case openHistoryFolder
    /// "Capture History..." opens the history window (design 20.3).
    case captureHistory
    /// "Pinned Captures (n)", a submenu, only while pins exist (design 20.2).
    case pinnedCaptures
    /// One pin's row in the submenu, by pin id.
    case pinnedCapture(Int)
    case unlockPin(Int)
    case closePin(Int)
    case closeAllPins
    case status
    case checkForUpdates
    case settings, quit
    /// The recording menu (Option-click or right-click on the timer, design 20.6).
    case stopRecording, cancelRecording
    /// An information row of the recording menu: target, microphone, system audio.
    case recordingInfo(Int)
    case separator(Int)

    /// The shortcut action behind a capture or editing item, if any.
    public var shortcutAction: ShortcutAction? {
        switch self {
        case .captureArea: .captureArea
        case .capturePreviousArea: .capturePreviousArea
        case .captureWindow: .captureWindow
        case .captureFullscreen: .captureFullscreen
        case .allInOne: .allInOne
        case .recordScreen: .recordScreen
        case .applyBackground: .applyBackground
        case .openInAnnotate: .openInAnnotate
        case .pinLastCapture: .pinLastCapture
        case .captureHistory: .openHistory
        case .stopRecording: .stopRecording
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
        /// A quiet line with a symbol in the recording menu, not clickable.
        case info
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
    /// A submenu: the Pinned Captures rows.
    public var children: [MenuItem]
    /// An SF Symbol for an info row.
    public var symbolName: String?
    /// Indented one level (a pin's Unlock and Close rows).
    public var indented: Bool

    public init(
        id: MenuItemID,
        kind: Kind = .action,
        title: String,
        keyEquivalent: MenuKeyEquivalent? = nil,
        shortcutText: String? = nil,
        isEnabled: Bool = true,
        subtitle: String? = nil,
        captureID: String? = nil,
        children: [MenuItem] = [],
        symbolName: String? = nil,
        indented: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.shortcutText = shortcutText
        self.isEnabled = isEnabled
        self.subtitle = subtitle
        self.captureID = captureID
        self.children = children
        self.symbolName = symbolName
        self.indented = indented
    }
}

/// One pin as the menu lists it (design 20.2): the Pinned Captures submenu shows a thumbnail of
/// `itemID`, the time it was taken, Unlock for a click-through pin and Close.
public struct PinnedCaptureEntry: Sendable, Hashable, Identifiable {
    public var id: Int
    public var itemID: String
    public var createdAt: Date
    public var clickThrough: Bool

    public init(id: Int, itemID: String, createdAt: Date, clickThrough: Bool) {
        self.id = id
        self.itemID = itemID
        self.createdAt = createdAt
        self.clickThrough = clickThrough
    }

    public init(_ entry: PinMenuEntry) {
        self.init(id: entry.id, itemID: entry.itemID, createdAt: entry.createdAt, clickThrough: entry.clickThrough)
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
        case .permissionNeeded: "Screen Recording needs your OK"
        case .waitingForCleanShot: "Waiting for CleanShot X to quit"
        case .systemShortcutOverlap: "A macOS shortcut overlaps Still's. See Settings."
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
    /// Adds "Relaunch Still" under the permission line (`PermissionState.offersRelaunchFromMenu`).
    public var offersRelaunch: Bool
    /// Enables "Capture Previous Area": an area was captured before on a current display.
    public var hasPreviousArea: Bool
    /// Shows "Open Clipboard Image": the clipboard holds an image.
    public var hasClipboardImage: Bool
    public var plan: HotkeyPlan?
    /// Shows "Check for Updates..." above Settings. Only the app's updater turns it on.
    public var offersUpdates: Bool
    /// Enables "Pin Last Capture": the last capture is a screenshot (recordings cannot be pinned).
    public var canPinLastCapture: Bool
    /// The pins on screen, oldest first.
    public var pins: [PinnedCaptureEntry]
    /// A recording is counting down, running or finishing: "Record Screen..." reads "Stop Recording".
    public var isRecording: Bool
    public var now: Date
    public var timeZone: TimeZone

    public init(
        shortcuts: ShortcutSettings = ShortcutSettings(),
        recentCaptures: [CaptureItem] = [],
        hasLastCapture: Bool? = nil,
        permissionNeeded: Bool = false,
        offersRelaunch: Bool = false,
        hasPreviousArea: Bool = false,
        hasClipboardImage: Bool = false,
        plan: HotkeyPlan? = nil,
        offersUpdates: Bool = false,
        canPinLastCapture: Bool? = nil,
        pins: [PinnedCaptureEntry] = [],
        isRecording: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        self.shortcuts = shortcuts
        self.recentCaptures = recentCaptures
        self.hasLastCapture = hasLastCapture ?? !recentCaptures.isEmpty
        self.permissionNeeded = permissionNeeded
        self.offersRelaunch = offersRelaunch
        self.hasPreviousArea = hasPreviousArea
        self.hasClipboardImage = hasClipboardImage
        self.plan = plan
        self.offersUpdates = offersUpdates
        self.canPinLastCapture = canPinLastCapture ?? (recentCaptures.first.map { $0.kind == .image } ?? false)
        self.pins = pins
        self.isRecording = isRecording
        self.now = now
        self.timeZone = timeZone
    }
}

/// The menu bar menu as data (design 12.1 and 20.10). `StatusMenuController` builds an `NSMenu`
/// from it and `MenuPreviewView` draws the same items in shot mode.
public struct MenuModel: Sendable, Hashable {
    public static let recentLimit = 3

    public let items: [MenuItem]
    public let status: MenuStatus?

    public init(_ input: MenuInput) {
        let status = MenuModel.status(for: input)
        self.status = status

        var items: [MenuItem] = [
            MenuModel.actionItem(.captureArea, title: "Capture Area", input),
            MenuModel.actionItem(
                .capturePreviousArea, title: "Capture Previous Area", input, enabled: input.hasPreviousArea
            ),
            MenuModel.actionItem(.captureWindow, title: "Capture Window", input),
            MenuModel.actionItem(.captureFullscreen, title: "Capture Fullscreen", input),
            MenuModel.actionItem(.allInOne, title: "All-in-One\u{2026}", input),
            MenuModel.recordItem(input),
            MenuItem(id: .separator(1), kind: .separator, title: ""),
            MenuModel.actionItem(
                .applyBackground, title: "Apply Background to Last Capture", input, enabled: input.hasLastCapture
            ),
            MenuModel.actionItem(
                .openInAnnotate, title: "Open Last Capture in Annotate", input, enabled: input.hasLastCapture
            ),
            MenuModel.actionItem(.pinLastCapture, title: "Pin Last Capture", input, enabled: input.canPinLastCapture),
            MenuModel.actionItem(
                .copyLastCaptureText, title: "Copy Text from Last Capture", input, enabled: input.canPinLastCapture
            ),
            MenuItem(id: .separator(2), kind: .separator, title: ""),
        ]
        items.append(contentsOf: MenuModel.recentItems(input))
        items.append(MenuModel.actionItem(.captureHistory, title: "Capture History\u{2026}", input))
        if !input.pins.isEmpty { items.append(MenuModel.pinnedItem(input)) }
        items.append(MenuItem(id: .openImage, title: "Open Image\u{2026}"))
        if input.hasClipboardImage { items.append(MenuItem(id: .openClipboardImage, title: "Open Clipboard Image")) }
        items.append(MenuItem(id: .separator(3), kind: .separator, title: ""))
        if let status {
            items.append(MenuItem(id: .status, kind: .status, title: status.title, isEnabled: status.isClickable))
            if status == .permissionNeeded, input.offersRelaunch {
                items.append(MenuItem(id: .relaunch, title: "Relaunch Still"))
            }
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
            id: .quit, title: "Quit Still",
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

    /// "Record Screen..." or, while recording, "Stop Recording" with Cmd+Shift+5, which always
    /// stops (design 20.6).
    private static func recordItem(_ input: MenuInput) -> MenuItem {
        guard input.isRecording else { return actionItem(.recordScreen, title: "Record Screen\u{2026}", input) }
        let combo = HotkeyCombo(input.shortcuts.stopRecording ?? .commandShift5)
        return MenuItem(
            id: .recordScreen, title: "Stop Recording", keyEquivalent: MenuKeyEquivalent(combo),
            shortcutText: combo.displayString
        )
    }

    /// "Pinned Captures (n)" with, per pin, its row, Unlock (click-through pins) and Close, then
    /// Close All Pins (design 20.2, D50).
    private static func pinnedItem(_ input: MenuInput) -> MenuItem {
        var children: [MenuItem] = []
        for (index, pin) in input.pins.enumerated() {
            if index > 0 { children.append(MenuItem(id: .separator(100 + index), kind: .separator, title: "")) }
            children.append(MenuItem(
                id: .pinnedCapture(pin.id), title: "Pinned \(clockTitle(pin.createdAt, timeZone: input.timeZone))",
                isEnabled: false, subtitle: relativeTime(pin.createdAt, now: input.now, timeZone: input.timeZone),
                captureID: pin.itemID
            ))
            children.append(MenuItem(id: .unlockPin(pin.id), title: "Unlock", isEnabled: pin.clickThrough, indented: true))
            children.append(MenuItem(id: .closePin(pin.id), title: "Close", indented: true))
        }
        children.append(MenuItem(id: .separator(99), kind: .separator, title: ""))
        children.append(MenuItem(id: .closeAllPins, title: "Close All Pins"))
        return MenuItem(id: .pinnedCaptures, title: "Pinned Captures (\(input.pins.count))", children: children)
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
                    title: recentTitle(capture, timeZone: input.timeZone),
                    subtitle: relativeTime(capture.createdAt, now: input.now, timeZone: input.timeZone),
                    captureID: capture.id
                ))
            }
        }
        return result
    }

    /// "Screenshot 14.03.22", or "Recording 11.48.09 · 0:42" with the duration (design 20.10).
    public static func recentTitle(_ capture: CaptureItem, timeZone: TimeZone) -> String {
        let time = clockTitle(capture.createdAt, timeZone: timeZone)
        guard capture.kind == .video else { return "Screenshot \(time)" }
        guard let duration = capture.durationSeconds else { return "Recording \(time)" }
        return "Recording \(time) \u{00B7} \(RecordingController.elapsedText(duration))"
    }

    /// `HH.mm.ss` in `timeZone`, as file names write the time.
    static func clockTitle(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
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

/// What the recording menu shows (design 20.6): Option-click or right-click on the red timer.
public struct RecordingMenuInput: Sendable, Hashable {
    public var target: CaptureMode
    /// The recorded size in points.
    public var size: CGSize
    public var fps: Int
    public var format: VideoFormat
    /// The microphone being recorded, nil when it is off or access is denied.
    public var microphoneName: String?
    public var systemAudio: Bool
    public var stopShortcut: KeyShortcut?
    /// The heartbeat's warning, shown as the first row while a track has stopped.
    public var stall: RecordingStall?

    public init(
        target: CaptureMode, size: CGSize, fps: Int, format: VideoFormat, microphoneName: String? = nil,
        systemAudio: Bool = false, stopShortcut: KeyShortcut? = nil, stall: RecordingStall? = nil
    ) {
        self.target = target
        self.size = size
        self.fps = fps
        self.format = format
        self.microphoneName = microphoneName
        self.systemAudio = systemAudio
        self.stopShortcut = stopShortcut
        self.stall = stall
    }
}

/// The recording menu as data: the stall warning when there is one, Stop Recording
/// (Cmd+Shift+5), Cancel Recording, then three quiet rows: target, size, fps and codec; the
/// microphone or "Microphone off"; system audio on or off.
public struct RecordingMenuModel: Sendable, Hashable {
    public let items: [MenuItem]

    public init(_ input: RecordingMenuInput) {
        // Cmd+Shift+5 always stops a recording; an extra Stop Recording shortcut is shown instead
        // only when the user set one.
        let combo = HotkeyCombo(input.stopShortcut ?? .commandShift5)
        let size = "\(Int(input.size.width.rounded())) \u{00D7} \(Int(input.size.height.rounded()))"
        let target: String = switch input.target {
        case .area: "Area"
        case .window: "Window"
        case .fullscreen: "Fullscreen"
        }
        var items: [MenuItem] = []
        if let stall = input.stall {
            // Not clickable: Stop Recording right below keeps what was written.
            items.append(MenuItem(id: .status, kind: .status, title: stall.message, isEnabled: false))
            items.append(MenuItem(id: .separator(0), kind: .separator, title: ""))
        }
        items += [
            MenuItem(
                id: .stopRecording, title: "Stop Recording", keyEquivalent: MenuKeyEquivalent(combo),
                shortcutText: combo.displayString
            ),
            MenuItem(id: .cancelRecording, title: "Cancel Recording"),
            MenuItem(id: .separator(1), kind: .separator, title: ""),
            MenuItem(
                id: .recordingInfo(0), kind: .info, title: "\(target) \(size), \(input.fps) fps, \(input.format.title)",
                isEnabled: false, symbolName: "display"
            ),
            MenuItem(
                id: .recordingInfo(1), kind: .info, title: input.microphoneName ?? "Microphone off", isEnabled: false,
                symbolName: "mic"
            ),
            MenuItem(
                id: .recordingInfo(2), kind: .info, title: input.systemAudio ? "System audio on" : "System audio off",
                isEnabled: false, symbolName: "speaker.wave.2"
            ),
        ]
        self.items = items
    }

    public func item(_ id: MenuItemID) -> MenuItem? {
        items.first { $0.id == id }
    }
}
