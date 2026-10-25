import Foundation

/// Every user setting (design sections 12.2 and 20.10), grouped as the settings tabs are. Missing
/// keys decode to their defaults, so an older file keeps working when a setting is added. A
/// version 1 file is migrated on decode by `SettingsMigration` (Cmd+Shift+5 moves to All-in-One).
public struct Settings: VersionedDocument {
    public static let currentVersion = 2

    public var version: Int
    public var general: GeneralSettings
    public var capture: CaptureSettings
    public var quickAccess: QuickAccessSettings
    public var recording: RecordingSettings
    public var annotate: AnnotateSettings
    public var shortcuts: ShortcutSettings

    public init(
        version: Int = Settings.currentVersion,
        general: GeneralSettings = GeneralSettings(),
        capture: CaptureSettings = CaptureSettings(),
        quickAccess: QuickAccessSettings = QuickAccessSettings(),
        recording: RecordingSettings = RecordingSettings(),
        annotate: AnnotateSettings = AnnotateSettings(),
        shortcuts: ShortcutSettings = ShortcutSettings()
    ) {
        self.version = version
        self.general = general
        self.capture = capture
        self.quickAccess = quickAccess
        self.recording = recording
        self.annotate = annotate
        self.shortcuts = shortcuts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        let fileVersion = try container.value(.version, default: defaults.version)
        version = fileVersion
        general = try container.value(.general, default: defaults.general)
        capture = try container.value(.capture, default: defaults.capture)
        quickAccess = try container.value(.quickAccess, default: defaults.quickAccess)
        recording = try container.value(.recording, default: defaults.recording)
        annotate = try container.value(.annotate, default: defaults.annotate)
        if fileVersion < 2 {
            // Version 1 shortcuts decode with the version 1 defaults, then migrate.
            let v1 = try container.decodeIfPresent(VersionOneShortcuts.self, forKey: .shortcuts)?.shortcuts
                ?? ShortcutSettings.version1Defaults
            shortcuts = v1
            self = SettingsMigration.migrate(self, from: fileVersion)
        } else {
            shortcuts = try container.value(.shortcuts, default: defaults.shortcuts)
        }
    }
}

/// Pure migrations between `settings.json` versions (design 20.10).
public enum SettingsMigration {
    /// Version 1 to 2 (design D56): when Capture Window still holds the default Cmd+Shift+5, the
    /// combo moves to All-in-One and Capture Window becomes unset. A changed or cleared Capture
    /// Window is left alone, and All-in-One then stays unset. Recording and annotate settings take
    /// their defaults. `settings.shortcuts` holds the shortcuts as version 1 stored them.
    public static func migrate(_ settings: Settings, from version: Int) -> Settings {
        guard version < 2 else { return settings }
        var migrated = settings
        var shortcuts = settings.shortcuts
        if shortcuts.captureWindow == .commandShift5 {
            shortcuts.allInOne = .commandShift5
            shortcuts.captureWindow = nil
        }
        migrated.shortcuts = shortcuts
        migrated.version = 2
        return migrated
    }
}

/// Decodes the shortcuts of a version 1 file, where a missing Capture Window key meant Cmd+Shift+5.
private struct VersionOneShortcuts: Decodable {
    let shortcuts: ShortcutSettings

    init(from decoder: any Decoder) throws {
        shortcuts = try ShortcutSettings(from: decoder, defaults: .version1Defaults)
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

/// The actions that can have a global shortcut (design 12.3 and 20.10). New actions are appended,
/// because `HotkeyConflicts` skips the later of two duplicates and `HotkeyCenter` numbers
/// registrations by this order.
public enum ShortcutAction: String, Codable, Sendable, Hashable, CaseIterable {
    case captureArea, captureWindow, captureFullscreen, applyBackground, openInAnnotate
    case allInOne, recordScreen, stopRecording, pinLastCapture, openHistory

    public var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .applyBackground: "Apply Background to Last Capture"
        case .openInAnnotate: "Open Last Capture in Annotate"
        case .allInOne: "All-in-One"
        case .recordScreen: "Record Screen"
        case .stopRecording: "Stop Recording"
        case .pinLastCapture: "Pin Last Capture"
        case .openHistory: "Open Capture History"
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
/// Defaults (design 20.10): Cmd+Shift+4 area, Cmd+Shift+3 fullscreen, Cmd+Shift+5 All-in-One,
/// every other action unset.
public struct ShortcutSettings: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case captureArea, captureWindow, captureFullscreen, applyBackground, openInAnnotate
        case allInOne, recordScreen, stopRecording, pinLastCapture, openHistory
    }

    public var captureArea: KeyShortcut?
    public var captureWindow: KeyShortcut?
    public var captureFullscreen: KeyShortcut?
    public var applyBackground: KeyShortcut?
    public var openInAnnotate: KeyShortcut?
    public var allInOne: KeyShortcut?
    public var recordScreen: KeyShortcut?
    public var stopRecording: KeyShortcut?
    public var pinLastCapture: KeyShortcut?
    public var openHistory: KeyShortcut?

    public init(
        captureArea: KeyShortcut? = .commandShift4,
        captureWindow: KeyShortcut? = nil,
        captureFullscreen: KeyShortcut? = .commandShift3,
        applyBackground: KeyShortcut? = nil,
        openInAnnotate: KeyShortcut? = nil,
        allInOne: KeyShortcut? = .commandShift5,
        recordScreen: KeyShortcut? = nil,
        stopRecording: KeyShortcut? = nil,
        pinLastCapture: KeyShortcut? = nil,
        openHistory: KeyShortcut? = nil
    ) {
        self.captureArea = captureArea
        self.captureWindow = captureWindow
        self.captureFullscreen = captureFullscreen
        self.applyBackground = applyBackground
        self.openInAnnotate = openInAnnotate
        self.allInOne = allInOne
        self.recordScreen = recordScreen
        self.stopRecording = stopRecording
        self.pinLastCapture = pinLastCapture
        self.openHistory = openHistory
    }

    /// What a version 1 file meant by a missing key: Cmd+Shift+5 on Capture Window and no
    /// All-in-One (it did not exist yet).
    public static let version1Defaults = ShortcutSettings(captureWindow: .commandShift5, allInOne: nil)

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, defaults: ShortcutSettings())
    }

    init(from decoder: any Decoder, defaults: ShortcutSettings) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureArea = try container.optionalValue(.captureArea, default: defaults.captureArea)
        captureWindow = try container.optionalValue(.captureWindow, default: defaults.captureWindow)
        captureFullscreen = try container.optionalValue(.captureFullscreen, default: defaults.captureFullscreen)
        applyBackground = try container.optionalValue(.applyBackground, default: defaults.applyBackground)
        openInAnnotate = try container.optionalValue(.openInAnnotate, default: defaults.openInAnnotate)
        allInOne = try container.optionalValue(.allInOne, default: defaults.allInOne)
        recordScreen = try container.optionalValue(.recordScreen, default: defaults.recordScreen)
        stopRecording = try container.optionalValue(.stopRecording, default: defaults.stopRecording)
        pinLastCapture = try container.optionalValue(.pinLastCapture, default: defaults.pinLastCapture)
        openHistory = try container.optionalValue(.openHistory, default: defaults.openHistory)
    }

    // Encode nil as an explicit null so a cleared default stays cleared after a round trip.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureArea, forKey: .captureArea)
        try container.encode(captureWindow, forKey: .captureWindow)
        try container.encode(captureFullscreen, forKey: .captureFullscreen)
        try container.encode(applyBackground, forKey: .applyBackground)
        try container.encode(openInAnnotate, forKey: .openInAnnotate)
        try container.encode(allInOne, forKey: .allInOne)
        try container.encode(recordScreen, forKey: .recordScreen)
        try container.encode(stopRecording, forKey: .stopRecording)
        try container.encode(pinLastCapture, forKey: .pinLastCapture)
        try container.encode(openHistory, forKey: .openHistory)
    }

    public subscript(action: ShortcutAction) -> KeyShortcut? {
        get {
            switch action {
            case .captureArea: captureArea
            case .captureWindow: captureWindow
            case .captureFullscreen: captureFullscreen
            case .applyBackground: applyBackground
            case .openInAnnotate: openInAnnotate
            case .allInOne: allInOne
            case .recordScreen: recordScreen
            case .stopRecording: stopRecording
            case .pinLastCapture: pinLastCapture
            case .openHistory: openHistory
            }
        }
        set {
            switch action {
            case .captureArea: captureArea = newValue
            case .captureWindow: captureWindow = newValue
            case .captureFullscreen: captureFullscreen = newValue
            case .applyBackground: applyBackground = newValue
            case .openInAnnotate: openInAnnotate = newValue
            case .allInOne: allInOne = newValue
            case .recordScreen: recordScreen = newValue
            case .stopRecording: stopRecording = newValue
            case .pinLastCapture: pinLastCapture = newValue
            case .openHistory: openHistory = newValue
            }
        }
    }
}

/// Video file format (design 20.6): H.264 by default, HEVC files are about half the size.
public enum VideoFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case h264, hevc

    /// The FourCC `snapctl probe` and `item.json` report.
    public var fourCC: String {
        switch self {
        case .h264: "avc1"
        case .hevc: "hvc1"
        }
    }

    public var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// Recording resolution: the display's pixels (Retina) or one pixel per point.
public enum RecordingScale: String, Codable, Sendable, Hashable, CaseIterable {
    case retina
    case oneX = "1x"

    public var title: String {
        switch self {
        case .retina: "Retina"
        case .oneX: "1x"
        }
    }
}

/// Recording tab (design 20.10).
public struct RecordingSettings: Codable, Sendable, Hashable {
    public static let frameRates = [30, 60]
    public static let countdownChoices = [0, 3, 5]

    public var format: VideoFormat
    /// 30 or 60.
    public var fps: Int
    public var scale: RecordingScale
    /// 0 (off), 3 or 5.
    public var countdownSeconds: Int
    public var showCursor: Bool
    public var highlightClicks: Bool
    public var systemAudio: Bool
    /// The user's intent; recordings proceed without the microphone when access is denied.
    public var microphone: Bool
    /// The chosen input device's unique id; nil means the system default input.
    public var microphoneDeviceID: String?

    public init(
        format: VideoFormat = .h264,
        fps: Int = 30,
        scale: RecordingScale = .retina,
        countdownSeconds: Int = 3,
        showCursor: Bool = true,
        highlightClicks: Bool = true,
        systemAudio: Bool = false,
        microphone: Bool = false,
        microphoneDeviceID: String? = nil
    ) {
        self.format = format
        self.fps = RecordingSettings.normalizedFPS(fps)
        self.scale = scale
        self.countdownSeconds = RecordingSettings.normalizedCountdown(countdownSeconds)
        self.showCursor = showCursor
        self.highlightClicks = highlightClicks
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.microphoneDeviceID = microphoneDeviceID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RecordingSettings()
        self.init(
            format: container.lenientValue(.format, default: defaults.format),
            fps: container.lenientValue(.fps, default: defaults.fps),
            scale: container.lenientValue(.scale, default: defaults.scale),
            countdownSeconds: container.lenientValue(.countdownSeconds, default: defaults.countdownSeconds),
            showCursor: try container.value(.showCursor, default: defaults.showCursor),
            highlightClicks: try container.value(.highlightClicks, default: defaults.highlightClicks),
            systemAudio: try container.value(.systemAudio, default: defaults.systemAudio),
            microphone: try container.value(.microphone, default: defaults.microphone),
            microphoneDeviceID: try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        )
    }

    /// 60 stays 60; anything else records at 30.
    public static func normalizedFPS(_ value: Int) -> Int { value == 60 ? 60 : 30 }

    /// The nearest of 0, 3 and 5.
    public static func normalizedCountdown(_ value: Int) -> Int {
        countdownChoices.min { abs($0 - value) < abs($1 - value) } ?? 3
    }

    /// The audio sources a recording asks for.
    public var audioSources: [AudioSource] {
        var sources: [AudioSource] = []
        if systemAudio { sources.append(.system) }
        if microphone { sources.append(.microphone) }
        return sources
    }
}

/// The Redact tool's three styles (design 20.8). P cycles them in this order.
public enum RedactStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case pixelate, blur, blackout

    public var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .blackout: "Black-out"
        }
    }

    /// The next style when P is pressed again.
    public var next: RedactStyle {
        let all = RedactStyle.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// Annotate tool settings that persist across documents (design 20.8).
public struct AnnotateSettings: Codable, Sendable, Hashable {
    /// #FFD60A, drawn at `highlightOpacity`.
    public static let defaultHighlightColor = RGBAColor(red: 1, green: 214.0 / 255, blue: 10.0 / 255)
    public static let highlightOpacity = 0.38

    public var highlightColor: RGBAColor
    public var redactStyle: RedactStyle

    public init(highlightColor: RGBAColor = AnnotateSettings.defaultHighlightColor, redactStyle: RedactStyle = .pixelate) {
        self.highlightColor = highlightColor
        self.redactStyle = redactStyle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AnnotateSettings()
        self.init(
            highlightColor: container.lenientValue(.highlightColor, default: defaults.highlightColor),
            redactStyle: container.lenientValue(.redactStyle, default: defaults.redactStyle)
        )
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

    /// Like `value(_:default:)`, but a value of the wrong type or an unknown enum case also falls
    /// back, so one bad M2 field does not move the whole settings file aside.
    func lenientValue<T: Decodable>(_ key: Key, default fallback: T) -> T {
        do {
            return try decodeIfPresent(T.self, forKey: key) ?? fallback
        } catch {
            return fallback
        }
    }
}
