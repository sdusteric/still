import AppKit
import Observation
import SnapCore
import SwiftUI

/// An audio input the Recording tab and the HUD's Options menu offer (design 20.7, 20.10). The
/// app lists them from `InputDevices` in SnapSystem; tests and shots pass fixed ones.
public struct MicrophoneDevice: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The stored choice when that device is present, else the first (the system default).
    public static func resolve(_ chosenID: String?, among devices: [MicrophoneDevice]) -> String? {
        if let chosenID, devices.contains(where: { $0.id == chosenID }) { return chosenID }
        return devices.first?.id
    }
}

/// The five settings tabs (design 12.2, D42, and 20.10: Recording sits between Quick Access and
/// Shortcuts).
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, capture, quickAccess, recording, shortcuts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .quickAccess: "Quick Access"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .capture: "viewfinder"
        case .quickAccess: "square.on.square"
        case .recording: "record.circle"
        case .shortcuts: "command"
        }
    }
}

/// What the settings window asks the app to do. Injected, so tests and shots never write
/// settings, register login items or open panels.
public struct SettingsActions {
    /// Persist the new settings (the app writes `settings.json` and re-registers hotkeys).
    public var settingsChanged: (SnapCore.Settings) -> Void
    /// Turn launch at login on or off (`SMAppService.mainApp` in the app). Returns whether it worked.
    public var setLaunchAtLogin: (Bool) -> Bool
    /// "Choose..." for the save folder (`NSOpenPanel` in the app): the path, nil when cancelled.
    public var chooseSaveFolder: () -> String?
    /// The folder saves go to for these settings.
    public var saveFolder: (SnapCore.Settings) -> URL
    /// Checks shortcuts against macOS and CleanShot (`HotkeyConflicts.evaluate` with live inputs).
    public var evaluateShortcuts: (ShortcutSettings) -> HotkeyPlan?
    /// "Edit..." next to the default preset: opens the Background editor on that preset.
    public var editPreset: (String) -> Void
    /// A recorder started or stopped listening; the app pauses its global hotkeys meanwhile.
    public var recordingChanged: (Bool) -> Void
    /// The time used for the file name preview.
    public var now: () -> Date
    /// Turning the microphone on asks for access when it was never asked (design D65). The app
    /// asks at most once per install and returns the status after the answer.
    public var requestMicrophoneAccess: () async -> MicrophoneAccess
    /// "Open Privacy Settings": Privacy & Security > Microphone.
    public var openMicrophonePrivacySettings: () -> Void

    public init(
        settingsChanged: @escaping (SnapCore.Settings) -> Void = { _ in },
        setLaunchAtLogin: @escaping (Bool) -> Bool = { _ in false },
        chooseSaveFolder: @escaping () -> String? = { nil },
        saveFolder: @escaping (SnapCore.Settings) -> URL = { _ in URL(filePath: "/Saved", directoryHint: .isDirectory) },
        evaluateShortcuts: @escaping (ShortcutSettings) -> HotkeyPlan? = { _ in nil },
        editPreset: @escaping (String) -> Void = { _ in },
        recordingChanged: @escaping (Bool) -> Void = { _ in },
        now: @escaping () -> Date = { Date() },
        requestMicrophoneAccess: @escaping () async -> MicrophoneAccess = { .notDetermined },
        openMicrophonePrivacySettings: @escaping () -> Void = {}
    ) {
        self.settingsChanged = settingsChanged
        self.setLaunchAtLogin = setLaunchAtLogin
        self.chooseSaveFolder = chooseSaveFolder
        self.saveFolder = saveFolder
        self.evaluateShortcuts = evaluateShortcuts
        self.editPreset = editPreset
        self.recordingChanged = recordingChanged
        self.now = now
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.openMicrophonePrivacySettings = openMicrophonePrivacySettings
    }
}

/// State behind the settings window. Every change to `settings` is passed to
/// `actions.settingsChanged` and re-checks shortcut conflicts.
@MainActor
@Observable
public final class SettingsModel {
    public var settings: SnapCore.Settings {
        didSet {
            guard settings != oldValue else { return }
            if settings.shortcuts != oldValue.shortcuts { refreshConflicts() }
            actions.settingsChanged(settings)
        }
    }
    public var tab: SettingsTab
    /// Shortcut warnings from `HotkeyConflicts` (design 12.3).
    public var plan: HotkeyPlan?
    /// Registration failures by action ("eventHotKeyExistsErr" and others), shown beside the field.
    public var registrationErrors: [ShortcutAction: String]
    public var presets: [BackgroundPreset]
    public var starredPresetID: String
    public internal(set) var launchAtLoginError: String?
    /// The Updates group in General. Nil in tests, shots and when `SNAP_NO_UPDATES=1`.
    public var updates: UpdateSettingsModel?
    /// Microphone access as the app last read it; drives the warning row (design 20.7).
    public var microphoneAccess: MicrophoneAccess
    /// Audio inputs for the device popup.
    public var microphones: [MicrophoneDevice]

    @ObservationIgnored public var actions: SettingsActions

    public init(
        settings: SnapCore.Settings = SnapCore.Settings(),
        tab: SettingsTab = .general,
        plan: HotkeyPlan? = nil,
        registrationErrors: [ShortcutAction: String] = [:],
        presets: [BackgroundPreset] = [BackgroundPreset.factoryDefault],
        starredPresetID: String = BackgroundPreset.factoryID,
        microphoneAccess: MicrophoneAccess = .notDetermined,
        microphones: [MicrophoneDevice] = [],
        actions: SettingsActions = SettingsActions()
    ) {
        self.settings = settings
        self.tab = tab
        self.plan = plan
        self.registrationErrors = registrationErrors
        self.presets = presets
        self.starredPresetID = starredPresetID
        self.microphoneAccess = microphoneAccess
        self.microphones = microphones
        self.actions = actions
        if plan == nil { self.plan = actions.evaluateShortcuts(settings.shortcuts) }
    }

    public func refreshConflicts() {
        plan = actions.evaluateShortcuts(settings.shortcuts)
    }

    public var isWaitingForCleanShot: Bool { plan?.isWaitingForCleanShot ?? false }

    /// Warnings shown under one shortcut. The CleanShot wait has its own notice above the groups.
    public func messages(for action: ShortcutAction) -> [String] {
        var messages = (plan?.warnings(for: action) ?? []).compactMap { warning -> String? in
            if case .waitingForCleanShot = warning { return nil }
            return warning.message
        }
        if let error = registrationErrors[action] { messages.append(error) }
        return messages
    }

    public var hasSystemShortcutOverlap: Bool {
        plan?.warnings.contains {
            if case .systemShortcutEnabled = $0 { return true }
            return false
        } ?? false
    }

    public var saveFolderURL: URL { actions.saveFolder(settings) }

    public var saveFolderName: String {
        let name = saveFolderURL.lastPathComponent
        return name.isEmpty ? saveFolderURL.path(percentEncoded: false) : name
    }

    /// The file name the pattern gives right now, with the extension.
    public var fileNamePreview: String {
        FileNamer(pattern: settings.general.fileNamePattern).fileName(date: actions.now()) { _ in false }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        if actions.setLaunchAtLogin(enabled) {
            settings.general.launchAtLogin = enabled
            launchAtLoginError = nil
        } else {
            launchAtLoginError = enabled
                ? "Snap could not be added to your login items. Check System Settings > General > Login Items."
                : "Snap could not be removed from your login items."
        }
    }

    public func chooseSaveFolder() {
        if let path = actions.chooseSaveFolder() {
            settings.general.saveFolderPath = path
        }
    }

    // MARK: Recording (design 20.7, 20.10)

    /// The "Record microphone" switch. Turning it on asks for access when it was never asked;
    /// a denial keeps the switch on as the user's intent and shows the warning row (D65).
    public var recordsMicrophone: Bool {
        get { settings.recording.microphone }
        set {
            settings.recording.microphone = newValue
            guard newValue, microphoneAccess == .notDetermined else { return }
            let request = actions.requestMicrophoneAccess
            Task { @MainActor [weak self] in
                let access = await request()
                self?.microphoneAccess = access
            }
        }
    }

    /// "Microphone access is off for Snap. Recordings are saved without it."
    public var showsMicrophoneWarning: Bool {
        settings.recording.microphone && (microphoneAccess == .denied || microphoneAccess == .restricted)
    }

    /// The device popup shows while the microphone is on and usable.
    public var showsMicrophoneDevices: Bool {
        settings.recording.microphone && !showsMicrophoneWarning && !microphones.isEmpty
    }

    /// The chosen device, or the system default when the stored one is gone.
    public var microphoneDeviceID: String {
        get { MicrophoneDevice.resolve(settings.recording.microphoneDeviceID, among: microphones) ?? "" }
        set { settings.recording.microphoneDeviceID = newValue.isEmpty ? nil : newValue }
    }

    /// The preset the one-click Background uses.
    public var defaultPresetID: String {
        get { settings.quickAccess.defaultPresetID ?? starredPresetID }
        set { settings.quickAccess.defaultPresetID = newValue == starredPresetID ? nil : newValue }
    }
}

/// Settings: toolbar-style tabs over a grouped form (design 12.2, 17.6, mockup section 6).
public struct SettingsView: View {
    @Bindable var model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $model.tab)
            Rectangle().fill(Theme.Colors.deskSeparator.color).frame(height: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Settings.groupSpacing) {
                    switch model.tab {
                    case .general: GeneralTab(model: model)
                    case .capture: CaptureTab(model: model)
                    case .quickAccess: QuickAccessTab(model: model)
                    case .recording: RecordingTab(model: model)
                    case .shortcuts: ShortcutsTab(model: model)
                    }
                }
                .padding(Theme.Settings.formPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Theme.Colors.desk.color)
        }
        .frame(width: Theme.Settings.width)
        .background(Theme.Colors.desk.color)
        .font(Theme.Typography.body.font)
        .tint(Theme.Colors.brand.color)
    }
}

// MARK: Tabs

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: Theme.Settings.tabGap) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title).font(Theme.Typography.captionSmall.font)
                    }
                    .foregroundStyle(selected ? Theme.Colors.brandText.color : Theme.Colors.deskText2.color)
                    .frame(width: Theme.Settings.tabSize.width, height: Theme.Settings.tabSize.height)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Theme.Settings.tabRadius, style: .continuous)
                                .fill(Theme.Colors.brandWash.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.deskBar.color)
    }
}

// MARK: Building blocks

/// A heading and a rounded group of rows (radius 10, `group` fill).
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.Settings.headingStyle.font)
                .foregroundStyle(Theme.Colors.deskText.color)
                .accessibilityAddTraits(.isHeader)
            .padding(.top, Theme.Settings.headingTopSpacing)
            .padding(.bottom, Theme.Settings.headingBottomSpacing)
            .padding(.leading, 4)
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Settings.groupRadius, style: .continuous)
                    .fill(Theme.Colors.deskGroup.color)
            )
            // A tinted last row (the microphone warning) follows the group's rounded corners.
            .clipShape(RoundedRectangle(cornerRadius: Theme.Settings.groupRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Settings.groupRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.deskSeparator.color, lineWidth: 0.5)
            )
        }
    }
}

/// One row: title, optional help line, trailing control. Rows after the first get a hairline.
private struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var warning: [String] = []
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(Theme.Colors.deskSeparator.color).frame(height: 1).padding(.leading, Theme.Settings.rowPadding.left)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Typography.body.font).foregroundStyle(Theme.Colors.deskText.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Typography.captionSmall.font)
                            .foregroundStyle(Theme.Colors.deskText2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(warning, id: \.self) { message in
                        Label {
                            Text(message).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(Theme.Typography.captionSmall.font)
                        .foregroundStyle(Theme.Colors.warning.color)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            .padding(.vertical, Theme.Settings.rowPadding.top)
            .padding(.horizontal, Theme.Settings.rowPadding.left)
            .frame(minHeight: Theme.Settings.rowMinHeight)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SwitchRow: View {
    let title: String
    var subtitle: String?
    var divider = true
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, divider: divider) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: General

private struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsGroup(title: "Startup") {
            SettingsRow(title: "Launch at login", warning: model.launchAtLoginError.map { [$0] } ?? [], divider: false) {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.general.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        SettingsGroup(title: "Saving") {
            SettingsRow(
                title: "Save folder",
                subtitle: (model.saveFolderURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath,
                divider: false
            ) {
                Button("Choose\u{2026}") { model.chooseSaveFolder() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Theme.Colors.deskSeparator.color).frame(height: 1)
                HStack(alignment: .firstTextBaseline) {
                    Text("File name").font(Theme.Typography.body.font)
                    Spacer(minLength: 8)
                    Text(model.fileNamePreview)
                        .font(Theme.Typography.captionSmall.font)
                        .foregroundStyle(Theme.Colors.deskText2.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
                TextField("File name", text: $model.settings.general.fileNamePattern)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("File name pattern")
            }
            .padding(.leading, Theme.Settings.rowPadding.left)
            .padding(.trailing, Theme.Settings.rowPadding.right)
            .padding(.bottom, Theme.Settings.rowPadding.bottom + 2)
        }
        Text("Tokens: {yyyy} {MM} {dd} {HH} {mm} {ss} {counter} {app}")
            .font(Theme.Typography.captionSmall.font)
            .foregroundStyle(Theme.Colors.deskText2.color)
            .padding(.leading, 4)
            .padding(.top, -8)
        SettingsGroup(title: "Sound") {
            SwitchRow(title: "Sound on capture", subtitle: "A quiet shutter.", divider: false,
                      isOn: $model.settings.general.playSound)
        }
        if let updates = model.updates {
            UpdatesGroup(updates: updates)
        }
    }
}

private struct UpdatesGroup: View {
    @Bindable var updates: UpdateSettingsModel

    var body: some View {
        SettingsGroup(title: "Updates") {
            SwitchRow(
                title: "Automatically install updates", subtitle: "Checks once a day.", divider: false,
                isOn: $updates.automaticallyInstallsUpdates
            )
            SettingsRow(title: "Check now") {
                Button("Check for Updates\u{2026}") { updates.checkForUpdates() }
            }
        }
    }
}

// MARK: Capture

private struct CaptureTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsGroup(title: "After capture") {
            SwitchRow(title: "Show Quick Access card", divider: false, isOn: $model.settings.capture.showQuickAccess)
            SwitchRow(title: "Copy to clipboard", isOn: $model.settings.capture.copyToClipboard)
            SwitchRow(title: "Save to folder", subtitle: model.saveFolderName, isOn: $model.settings.capture.saveToFolder)
            SwitchRow(title: "Open in Annotate", isOn: $model.settings.capture.openInAnnotate)
        }
        SettingsGroup(title: "Selection") {
            SwitchRow(
                title: "Capture on mouse release", subtitle: "Skips the adjust step. Turn off to resize with handles.",
                divider: false, isOn: $model.settings.capture.instantCapture
            )
            SwitchRow(title: "Show magnifier", isOn: $model.settings.capture.showMagnifier)
            SwitchRow(title: "Show crosshair", isOn: $model.settings.capture.showCrosshair)
            SwitchRow(
                title: "Show key hints", subtitle: "Hides itself after 10 captures.",
                isOn: $model.settings.capture.showKeyHints
            )
        }
        SettingsGroup(title: "Screen") {
            SwitchRow(title: "Hide desktop icons", divider: false, isOn: $model.settings.capture.hideDesktopIcons)
            SwitchRow(
                title: "Include window shadow", subtitle: "Option-click flips it for one capture.",
                isOn: $model.settings.capture.includeWindowShadow
            )
        }
    }
}

// MARK: Quick Access

private struct QuickAccessTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsGroup(title: "Position") {
            SettingsRow(title: "Corner", divider: false) {
                Picker("Corner", selection: $model.settings.quickAccess.corner) {
                    ForEach(QuickAccessCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingsRow(title: "Size") {
                Picker("Size", selection: $model.settings.quickAccess.size) {
                    ForEach(QuickAccessSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        SettingsGroup(title: "Closing") {
            SwitchRow(title: "Close automatically", divider: false, isOn: $model.settings.quickAccess.autoClose)
            SettingsRow(title: "Close after", subtitle: "Paused while the pointer is over a card.") {
                HStack(spacing: 6) {
                    Text("\(model.settings.quickAccess.autoCloseSeconds) s")
                        .font(Theme.Typography.body.font.monospacedDigit())
                        .foregroundStyle(Theme.Colors.deskText2.color)
                    Stepper(
                        "Seconds",
                        value: $model.settings.quickAccess.autoCloseSeconds,
                        in: QuickAccessSettings.autoCloseRange
                    )
                    .labelsHidden()
                }
                .disabled(!model.settings.quickAccess.autoClose)
            }
            SwitchRow(title: "Close after drag-out", isOn: $model.settings.quickAccess.closeAfterDragOut)
            SwitchRow(title: "Close after Copy or Save", isOn: $model.settings.quickAccess.closeAfterCopyOrSave)
        }
        SettingsGroup(title: "Background") {
            SettingsRow(title: "Default preset", subtitle: "Used by the Background button on the card.", divider: false) {
                HStack(spacing: 8) {
                    Picker("Default preset", selection: $model.defaultPresetID) {
                        ForEach(model.presets) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button("Edit\u{2026}") { model.actions.editPreset(model.defaultPresetID) }
                }
            }
        }
    }
}

// MARK: Recording

private struct RecordingTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsGroup(title: "Video") {
            SettingsRow(title: "Format", subtitle: "HEVC files are about half the size.", divider: false) {
                Picker("Format", selection: $model.settings.recording.format) {
                    ForEach(VideoFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingsRow(title: "Frame rate") {
                Picker("Frame rate", selection: $model.settings.recording.fps) {
                    ForEach(RecordingSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: Theme.SettingsM2.pairSegmentWidth)
            }
            SettingsRow(title: "Resolution") {
                Picker("Resolution", selection: $model.settings.recording.scale) {
                    ForEach(RecordingScale.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: Theme.SettingsM2.pairSegmentWidth)
            }
        }
        SettingsGroup(title: "While recording") {
            SettingsRow(title: "Countdown", divider: false) {
                Picker("Countdown", selection: $model.settings.recording.countdownSeconds) {
                    ForEach(RecordingSettings.countdownChoices, id: \.self) { Text(RecordingCountdown.title($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            SwitchRow(title: "Show cursor", isOn: $model.settings.recording.showCursor)
            SwitchRow(title: "Highlight clicks", isOn: $model.settings.recording.highlightClicks)
        }
        SettingsGroup(title: "Audio") {
            SwitchRow(title: "Record system audio", divider: false, isOn: $model.settings.recording.systemAudio)
            SwitchRow(title: "Record microphone", subtitle: "Asked once, when you turn this on.", isOn: $model.recordsMicrophone)
            if model.showsMicrophoneDevices {
                SettingsRow(title: "Microphone") {
                    Picker("Microphone", selection: $model.microphoneDeviceID) {
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            if model.showsMicrophoneWarning {
                MicrophoneWarningRow { model.actions.openMicrophonePrivacySettings() }
            }
        }
    }
}

/// The warning row under the microphone switch when access is off (design 20.7, mockup 14).
private struct MicrophoneWarningRow: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.Colors.deskSeparator.color).frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: Theme.SettingsM2.warningRowIconSize, weight: .regular))
                        .padding(.top, 1)
                    Text("Microphone access is off for Snap. Recordings are saved without it.")
                        .font(Theme.Typography.body.font)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.Colors.warning.color)
                Spacer(minLength: 8)
                Button("Open Privacy Settings", action: openSettings)
            }
            .padding(.vertical, Theme.Settings.rowPadding.top + 2)
            .padding(.horizontal, Theme.Settings.rowPadding.left)
            .frame(minHeight: Theme.Settings.rowMinHeight)
            .background(Theme.Colors.warningBackground.color)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Shortcuts

private struct ShortcutsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        if model.isWaitingForCleanShot {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.warning.color)
                    .padding(.top, 1)
                Text("\(Text("CleanShot X is running.").fontWeight(.semibold)) Snap registers these shortcuts when it quits and never closes it for you.")
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(Theme.Colors.deskText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Settings.groupRadius, style: .continuous)
                    .fill(Theme.Colors.warningBackground.color)
            )
            .accessibilityElement(children: .combine)
        }
        SettingsGroup(title: "Capture") {
            recorderRow(.captureArea, divider: false)
            recorderRow(.captureFullscreen)
            recorderRow(.allInOne)
            recorderRow(.captureWindow)
            recorderRow(.recordScreen)
            recorderRow(.stopRecording, subtitle: "\u{21E7}\u{2318}5 always stops a recording.")
        }
        SettingsGroup(title: "Last capture") {
            recorderRow(.applyBackground, divider: false)
            recorderRow(.openInAnnotate)
            recorderRow(.pinLastCapture)
        }
        SettingsGroup(title: "Other") {
            recorderRow(.openHistory, divider: false)
        }
        Text(footnote)
            .font(Theme.Typography.captionSmall.font)
            .foregroundStyle(Theme.Colors.deskText2.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var footnote: String {
        model.hasSystemShortcutOverlap
            ? "A macOS screenshot shortcut uses one of these keys. Turn it off in System Settings > Keyboard > "
                + "Keyboard Shortcuts > Screenshots."
            : "Screenshot shortcuts in System Settings are off, so nothing else is using these keys."
    }

    private func recorderRow(_ action: ShortcutAction, subtitle: String? = nil, divider: Bool = true) -> some View {
        SettingsRow(title: action.title, subtitle: subtitle, warning: model.messages(for: action), divider: divider) {
            ShortcutRecorder(
                action: action,
                shortcut: Binding(
                    get: { model.settings.shortcuts[action] },
                    set: { model.settings.shortcuts[action] = $0 }
                ),
                onRecordingChange: { model.actions.recordingChanged($0) }
            )
        }
    }
}

// MARK: Demo

/// The settings content with default settings and CleanShot X running (mockup section 6), for
/// tests and shots. Nothing is read from or written to disk.
public enum SettingsDemo {
    public static let size = CGSize(width: Theme.Settings.width, height: 690)

    /// The Recording tab shot (design 20.11 `settings-recording`): the microphone on and access
    /// denied, so the warning row shows.
    public static func makeModel(tab: SettingsTab = .capture) -> SettingsModel {
        let actions = SettingsActions(
            saveFolder: { _ in URL(filePath: "/Users/demo/Downloads", directoryHint: .isDirectory) },
            evaluateShortcuts: { shortcuts in
                HotkeyConflicts.evaluate(
                    shortcuts: shortcuts, systemEntries: [],
                    runningBundleIDs: ["com.getcleanshot.app-setapp"]
                )
            },
            now: { Date(timeIntervalSince1970: 1_792_850_602) }
        )
        let model = SettingsModel(
            tab: tab, microphoneAccess: tab == .recording ? .denied : .notDetermined,
            microphones: [MicrophoneDevice(id: "demo-mic", name: "MacBook Pro Microphone")], actions: actions
        )
        if tab == .recording { model.settings.recording.microphone = true }
        return model
    }

    public static func makeView(tab: SettingsTab = .capture, dark: Bool = false) -> NSView {
        let view = NSHostingView(rootView: SettingsView(model: makeModel(tab: tab)).frame(height: size.height, alignment: .top))
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }
}
