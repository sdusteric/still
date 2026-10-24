import Foundation

/// Every user setting (design section 12.2), grouped as the four settings tabs are. Missing keys
/// decode to their defaults, so an older file keeps working when a setting is added.
public struct Settings: VersionedDocument {
    public static let currentVersion = 1

    public var version: Int
    public var general: GeneralSettings
    public var capture: CaptureSettings
    public var quickAccess: QuickAccessSettings
    public var shortcuts: ShortcutSettings

    public init(
        version: Int = Settings.currentVersion,
        general: GeneralSettings = GeneralSettings(),
        capture: CaptureSettings = CaptureSettings(),
        quickAccess: QuickAccessSettings = QuickAccessSettings(),
        shortcuts: ShortcutSettings = ShortcutSettings()
    ) {
        self.version = version
        self.general = general
        self.capture = capture
        self.quickAccess = quickAccess
        self.shortcuts = shortcuts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        version = try container.value(.version, default: defaults.version)
        general = try container.value(.general, default: defaults.general)
        capture = try container.value(.capture, default: defaults.capture)
        quickAccess = try container.value(.quickAccess, default: defaults.quickAccess)
        shortcuts = try container.value(.shortcuts, default: defaults.shortcuts)
    }
}

/// General tab.
public struct GeneralSettings: Codable, Sendable, Hashable {
    public static let defaultFileNamePattern = "Snap {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}"

    /// Launch at login through `SMAppService.mainApp`. Off by default and never touched by tests.
    public var launchAtLogin: Bool
    /// Save folder chosen by the user; nil means `SnapPaths.defaultSaveFolder`.
    public var saveFolderPath: String?
    public var fileNamePattern: String
    /// Sound on capture (design D29: off).
    public var playSound: Bool

    public init(
        launchAtLogin: Bool = false,
        saveFolderPath: String? = nil,
        fileNamePattern: String = GeneralSettings.defaultFileNamePattern,
        playSound: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.saveFolderPath = saveFolderPath
        self.fileNamePattern = fileNamePattern
        self.playSound = playSound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralSettings()
        launchAtLogin = try container.value(.launchAtLogin, default: defaults.launchAtLogin)
        saveFolderPath = try container.decodeIfPresent(String.self, forKey: .saveFolderPath)
        let pattern = try container.value(.fileNamePattern, default: defaults.fileNamePattern)
        fileNamePattern = pattern.isEmpty ? defaults.fileNamePattern : pattern
        playSound = try container.value(.playSound, default: defaults.playSound)
    }
}

/// Capture tab: after-capture actions, selection behavior and screen options.
public struct CaptureSettings: Codable, Sendable, Hashable {
    public var showQuickAccess: Bool
    public var copyToClipboard: Bool
    public var saveToFolder: Bool
    public var openInAnnotate: Bool
    /// Capture on mouse release (design D10). Off keeps the selection with handles until Return.
    public var instantCapture: Bool
    public var showMagnifier: Bool
    public var showCrosshair: Bool
    /// Key hints in the overlay; the app turns this off after the first 10 captures.
    public var showKeyHints: Bool
    public var hideDesktopIcons: Bool
    public var includeWindowShadow: Bool

    public init(
        showQuickAccess: Bool = true,
        copyToClipboard: Bool = true,
        saveToFolder: Bool = false,
        openInAnnotate: Bool = false,
        instantCapture: Bool = true,
        showMagnifier: Bool = true,
        showCrosshair: Bool = true,
        showKeyHints: Bool = true,
        hideDesktopIcons: Bool = true,
        includeWindowShadow: Bool = true
    ) {
        self.showQuickAccess = showQuickAccess
        self.copyToClipboard = copyToClipboard
        self.saveToFolder = saveToFolder
        self.openInAnnotate = openInAnnotate
        self.instantCapture = instantCapture
        self.showMagnifier = showMagnifier
        self.showCrosshair = showCrosshair
        self.showKeyHints = showKeyHints
        self.hideDesktopIcons = hideDesktopIcons
        self.includeWindowShadow = includeWindowShadow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureSettings()
        showQuickAccess = try container.value(.showQuickAccess, default: defaults.showQuickAccess)
        copyToClipboard = try container.value(.copyToClipboard, default: defaults.copyToClipboard)
        saveToFolder = try container.value(.saveToFolder, default: defaults.saveToFolder)
        openInAnnotate = try container.value(.openInAnnotate, default: defaults.openInAnnotate)
        instantCapture = try container.value(.instantCapture, default: defaults.instantCapture)
        showMagnifier = try container.value(.showMagnifier, default: defaults.showMagnifier)
        showCrosshair = try container.value(.showCrosshair, default: defaults.showCrosshair)
        showKeyHints = try container.value(.showKeyHints, default: defaults.showKeyHints)
        hideDesktopIcons = try container.value(.hideDesktopIcons, default: defaults.hideDesktopIcons)
        includeWindowShadow = try container.value(.includeWindowShadow, default: defaults.includeWindowShadow)
    }
}

/// Screen corner the Quick Access stack is anchored to.
public enum QuickAccessCorner: String, Codable, Sendable, Hashable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    public var title: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }
}

/// Quick Access card size (design section 8).
public enum QuickAccessSize: String, Codable, Sendable, Hashable, CaseIterable {
    case small, medium, large

    /// Width of the thumbnail box in points. The card adds 8 pt padding on each side.
    public var thumbnailWidth: Double {
        switch self {
        case .small: 180
        case .medium: 240
        case .large: 300
        }
    }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Quick Access tab.
public struct QuickAccessSettings: Codable, Sendable, Hashable {
    public static let autoCloseRange: ClosedRange<Int> = 3...60

    public var corner: QuickAccessCorner
    public var size: QuickAccessSize
    public var autoClose: Bool
    /// Seconds before a card closes on its own, 3 to 60.
    public var autoCloseSeconds: Int
    public var closeAfterDragOut: Bool
    public var closeAfterCopyOrSave: Bool
    /// The Background preset the one-click action uses; nil means the starred preset.
    public var defaultPresetID: String?

    public init(
        corner: QuickAccessCorner = .bottomLeft,
        size: QuickAccessSize = .medium,
        autoClose: Bool = true,
        autoCloseSeconds: Int = 15,
        closeAfterDragOut: Bool = true,
        closeAfterCopyOrSave: Bool = true,
        defaultPresetID: String? = nil
    ) {
        self.corner = corner
        self.size = size
        self.autoClose = autoClose
        self.autoCloseSeconds = QuickAccessSettings.clampSeconds(autoCloseSeconds)
        self.closeAfterDragOut = closeAfterDragOut
        self.closeAfterCopyOrSave = closeAfterCopyOrSave
        self.defaultPresetID = defaultPresetID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuickAccessSettings()
        self.init(
            corner: try container.value(.corner, default: defaults.corner),
            size: try container.value(.size, default: defaults.size),
            autoClose: try container.value(.autoClose, default: defaults.autoClose),
            autoCloseSeconds: try container.value(.autoCloseSeconds, default: defaults.autoCloseSeconds),
            closeAfterDragOut: try container.value(.closeAfterDragOut, default: defaults.closeAfterDragOut),
            closeAfterCopyOrSave: try container.value(.closeAfterCopyOrSave, default: defaults.closeAfterCopyOrSave),
            defaultPresetID: try container.decodeIfPresent(String.self, forKey: .defaultPresetID)
        )
    }

    public static func clampSeconds(_ value: Int) -> Int {
        min(max(value, autoCloseRange.lowerBound), autoCloseRange.upperBound)
    }
}

/// The five actions that can have a global shortcut (design 12.3).
public enum ShortcutAction: String, Codable, Sendable, Hashable, CaseIterable {
    case captureArea, captureWindow, captureFullscreen, applyBackground, openInAnnotate

    public var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .applyBackground: "Apply Background to Last Capture"
        case .openInAnnotate: "Open Last Capture in Annotate"
        }
    }
}

/// A stored shortcut: a virtual key code and Carbon modifier bits, the form
/// `RegisterEventHotKey` takes and CleanShot stores (Cmd+Shift is 768).
public struct KeyShortcut: Codable, Sendable, Hashable {
    /// Carbon modifier bits, defined here so SnapCore needs no Carbon import.
    public enum Modifier {
        public static let command: UInt32 = 1 << 8
        public static let shift: UInt32 = 1 << 9
        public static let option: UInt32 = 1 << 11
        public static let control: UInt32 = 1 << 12
    }

    /// Virtual key codes of the default shortcuts (`kVK_ANSI_3`, `kVK_ANSI_4`, `kVK_ANSI_5`).
    public enum KeyCode {
        public static let ansi3: UInt32 = 20
        public static let ansi4: UInt32 = 21
        public static let ansi5: UInt32 = 23
    }

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let commandShift3 = KeyShortcut(keyCode: KeyCode.ansi3, modifiers: Modifier.command | Modifier.shift)
    public static let commandShift4 = KeyShortcut(keyCode: KeyCode.ansi4, modifiers: Modifier.command | Modifier.shift)
    public static let commandShift5 = KeyShortcut(keyCode: KeyCode.ansi5, modifiers: Modifier.command | Modifier.shift)
}

/// Shortcuts tab. A key that is present with `null` means the user cleared that shortcut.
public struct ShortcutSettings: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case captureArea, captureWindow, captureFullscreen, applyBackground, openInAnnotate
    }

    public var captureArea: KeyShortcut?
    public var captureWindow: KeyShortcut?
    public var captureFullscreen: KeyShortcut?
    public var applyBackground: KeyShortcut?
    public var openInAnnotate: KeyShortcut?

    public init(
        captureArea: KeyShortcut? = .commandShift4,
        captureWindow: KeyShortcut? = .commandShift5,
        captureFullscreen: KeyShortcut? = .commandShift3,
        applyBackground: KeyShortcut? = nil,
        openInAnnotate: KeyShortcut? = nil
    ) {
        self.captureArea = captureArea
        self.captureWindow = captureWindow
        self.captureFullscreen = captureFullscreen
        self.applyBackground = applyBackground
        self.openInAnnotate = openInAnnotate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ShortcutSettings()
        captureArea = try container.optionalValue(.captureArea, default: defaults.captureArea)
        captureWindow = try container.optionalValue(.captureWindow, default: defaults.captureWindow)
        captureFullscreen = try container.optionalValue(.captureFullscreen, default: defaults.captureFullscreen)
        applyBackground = try container.optionalValue(.applyBackground, default: defaults.applyBackground)
        openInAnnotate = try container.optionalValue(.openInAnnotate, default: defaults.openInAnnotate)
    }

    // Encode nil as an explicit null so a cleared default stays cleared after a round trip.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureArea, forKey: .captureArea)
        try container.encode(captureWindow, forKey: .captureWindow)
        try container.encode(captureFullscreen, forKey: .captureFullscreen)
        try container.encode(applyBackground, forKey: .applyBackground)
        try container.encode(openInAnnotate, forKey: .openInAnnotate)
    }

    public subscript(action: ShortcutAction) -> KeyShortcut? {
        get {
            switch action {
            case .captureArea: captureArea
            case .captureWindow: captureWindow
            case .captureFullscreen: captureFullscreen
            case .applyBackground: applyBackground
            case .openInAnnotate: openInAnnotate
            }
        }
        set {
            switch action {
            case .captureArea: captureArea = newValue
            case .captureWindow: captureWindow = newValue
            case .captureFullscreen: captureFullscreen = newValue
            case .applyBackground: applyBackground = newValue
            case .openInAnnotate: openInAnnotate = newValue
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// The decoded value, or `fallback` when the key is missing or null.
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }

    /// The decoded optional: `fallback` when the key is missing, nil when it is present and null.
    func optionalValue<T: Decodable>(_ key: Key, default fallback: T?) throws -> T? {
        guard contains(key) else { return fallback }
        return try decodeIfPresent(T.self, forKey: key)
    }
}
