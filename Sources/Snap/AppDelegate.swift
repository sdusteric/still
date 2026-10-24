import AppKit
import ServiceManagement
import SnapCore
import SnapSystem
import SnapUI
import SwiftUI

/// The app lifecycle (design 5, 12, 13): menu bar only (`.accessory`), the status menu, settings,
/// global hotkeys with the CleanShot X hand-over, and the first-run window. The capture graph
/// lives in `AppWiring`. Only the installed app runs this; tests, tools and the shot mode never do.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let sweepInterval: TimeInterval = 60 * 60

    private var wiring: AppWiring?
    private var menu: StatusMenuController?
    private var hotkeys: HotkeyCenter?
    private let conflictingApps = ConflictingApps()
    private var plan: HotkeyPlan?
    private var registrationErrors: [ShortcutAction: String] = [:]
    private var symbolicEntries: [SymbolicHotkeyEntry] = []
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var onboardingModel: OnboardingModel?
    private var onboardingWindow: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    private var sweepTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, and launching never takes focus.
        NSApp.setActivationPolicy(.accessory)
        let wiring = AppWiring()
        self.wiring = wiring
        wiring.onSettingsChanged = { [weak self] settings in self?.settingsModel?.settings = settings }
        wiring.onPermissionChanged = { [weak self] in self?.permissionChanged() }
        wiring.start()

        installMenu(wiring)
        installHotkeys(wiring)
        observeSystem(wiring)
        showOnboardingIfNeeded(wiring)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
        conflictingApps.stopObserving()
        sweepTimer?.invalidate()
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        menu?.uninstall()
        wiring?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menu

    private func installMenu(_ wiring: AppWiring) {
        let controller = StatusMenuController(
            modelProvider: { [weak self] in self?.menuModel() ?? MenuModel(MenuInput()) },
            thumbnail: { [weak wiring] id in wiring?.menuThumbnail(for: id) },
            onSelect: { [weak self] id in self?.menuSelected(id) },
            onWillOpen: { [weak wiring] in wiring?.recheckPermission() }
        )
        controller.install()
        menu = controller
    }

    private func menuModel() -> MenuModel {
        guard let wiring else { return MenuModel(MenuInput()) }
        return MenuModel(MenuInput(
            shortcuts: wiring.settings.shortcuts,
            recentCaptures: wiring.recentCaptures(),
            hasLastCapture: wiring.hasLastCapture,
            permissionNeeded: wiring.permission.needsAttention,
            plan: plan
        ))
    }

    private func menuSelected(_ id: MenuItemID) {
        guard let wiring else { return }
        switch id {
        case .captureArea: wiring.capture(.area)
        case .captureWindow: wiring.capture(.window)
        case .captureFullscreen: wiring.capture(.fullscreen)
        case .applyBackground: wiring.applyBackgroundToLastCapture()
        case .openInAnnotate: wiring.openLastCaptureInAnnotate()
        case .recentCapture(let captureID): wiring.showRecentCapture(id: captureID)
        case .openHistoryFolder: wiring.openHistoryFolder()
        case .status:
            if wiring.permission.needsAttention {
                AppWiring.openScreenRecordingSettings()
            } else {
                openSettings(tab: .shortcuts)
            }
        case .settings: openSettings(tab: nil)
        case .quit: NSApp.terminate(nil)
        case .recentCapturesHeader, .noRecentCaptures, .separator: break
        }
    }

    // MARK: Hotkeys

    private func installHotkeys(_ wiring: AppWiring) {
        hotkeys = HotkeyCenter { [weak self] press in self?.hotkeyPressed(press) }
        readSymbolicHotkeys()
        applyHotkeys()
        // CleanShot X launching or quitting changes which combos Snap may register (design 12.3).
        conflictingApps.startObserving { [weak self] running in
            self?.wiring?.log.info("hotkeys: CleanShot X running: \(!running.isEmpty)")
            self?.applyHotkeys()
        }
    }

    private func hotkeyPressed(_ press: HotkeyPress) {
        guard let wiring else { return }
        let eventTime = press.time(on: SystemClock())
        switch press.action {
        case .captureArea: wiring.capture(.area, eventTime: eventTime)
        case .captureWindow: wiring.capture(.window, eventTime: eventTime)
        case .captureFullscreen: wiring.capture(.fullscreen, eventTime: eventTime)
        case .applyBackground: wiring.applyBackgroundToLastCapture()
        case .openInAnnotate: wiring.openLastCaptureInAnnotate()
        }
    }

    private func readSymbolicHotkeys() {
        switch SymbolicHotkeys.read() {
        case .success(let entries):
            symbolicEntries = entries
        case .failure(let error):
            symbolicEntries = []
            wiring?.log.warning("hotkeys: cannot read system shortcuts: \(error)")
        }
    }

    private func evaluate(_ shortcuts: ShortcutSettings) -> HotkeyPlan {
        HotkeyConflicts.evaluate(
            shortcuts: shortcuts, systemEntries: symbolicEntries, runningBundleIDs: conflictingApps.runningBundleIDs
        )
    }

    /// Registers what the plan allows now; CleanShot's combos wait until it quits. A failed
    /// registration is shown next to the shortcut in settings, never as an alert.
    private func applyHotkeys() {
        guard let wiring, let hotkeys else { return }
        let plan = evaluate(wiring.settings.shortcuts)
        self.plan = plan
        var errors: [ShortcutAction: String] = [:]
        for registration in hotkeys.apply(plan) {
            if let message = registration.message {
                errors[registration.action] = message
                wiring.log.warning("hotkeys: \(registration.action.rawValue) \(registration.combo.displayString): \(message)")
            }
        }
        if plan.isWaitingForCleanShot {
            let waiting = plan.deferred.keys.map(\.rawValue).sorted().joined(separator: ", ")
            wiring.log.info("hotkeys: waiting for CleanShot X to quit before registering \(waiting)")
        }
        registrationErrors = errors
        settingsModel?.plan = plan
        settingsModel?.registrationErrors = errors
        onboardingModel?.cleanShotRunning = conflictingApps.isCleanShotRunning
    }

    // MARK: Settings

    private func openSettings(tab: SettingsTab?) {
        guard let wiring else { return }
        if settingsWindow == nil {
            let actions = SettingsActions(
                settingsChanged: { [weak self] settings in self?.settingsChanged(settings) },
                setLaunchAtLogin: { enabled in AppDelegate.setLaunchAtLogin(enabled) },
                chooseSaveFolder: { AppDelegate.chooseFolder() },
                saveFolder: { [paths = wiring.paths] settings in paths.saveFolder(for: settings) },
                evaluateShortcuts: { [weak self] shortcuts in self?.evaluate(shortcuts) },
                editPreset: { [weak wiring] id in wiring?.editPreset(id: id) },
                recordingChanged: { [weak self] recording in self?.recordingChanged(recording) },
                now: { Date() }
            )
            let model = SettingsModel(
                settings: wiring.settings, tab: tab ?? .general, plan: plan, registrationErrors: registrationErrors,
                presets: wiring.presetStore.presets, starredPresetID: wiring.presetStore.starredID, actions: actions
            )
            let controller = SettingsWindowController(model: model)
            controller.onOpen = { [weak self] in self?.settingsWillOpen() }
            settingsModel = model
            settingsWindow = controller
        }
        settingsWindow?.present(tab: tab)
    }

    /// Re-reads the system shortcuts, the presets and the permission each time settings open.
    private func settingsWillOpen() {
        guard let wiring else { return }
        readSymbolicHotkeys()
        settingsModel?.presets = wiring.presetStore.presets
        settingsModel?.starredPresetID = wiring.presetStore.starredID
        settingsModel?.settings = wiring.settings
        wiring.recheckPermission()
        applyHotkeys()
    }

    private func settingsChanged(_ settings: SnapCore.Settings) {
        guard let wiring else { return }
        let shortcutsChanged = settings.shortcuts != wiring.settings.shortcuts
        wiring.replaceSettings(settings)
        if shortcutsChanged { applyHotkeys() }
    }

    /// A shortcut recorder is listening: Snap's own hotkeys are paused so the keys reach it.
    private func recordingChanged(_ recording: Bool) {
        if recording {
            hotkeys?.unregisterAll()
        } else {
            applyHotkeys()
        }
    }

    private static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    private static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path(percentEncoded: false)
    }

    // MARK: Onboarding

    /// The first-run window (design 13, 17.6): only when permission is missing and was never
    /// requested. Never modal; Snap works without it.
    private func showOnboardingIfNeeded(_ wiring: AppWiring) {
        guard wiring.permission.needsOnboarding, !wiring.stateStore.state.onboardingCompleted else { return }
        let model = OnboardingModel(
            permissionGranted: false, cleanShotRunning: conflictingApps.isCleanShotRunning,
            offersRelaunch: false,
            actions: OnboardingActions(
                requestAccess: { [weak wiring] in wiring?.requestScreenRecording() },
                relaunch: { AppDelegate.relaunch() },
                finish: { [weak self] in self?.finishOnboarding() }
            )
        )
        let host = NSHostingView(rootView: OnboardingView(model: model).frame(width: Theme.Onboarding.width))
        let size = CGSize(width: Theme.Onboarding.width, height: max(host.fittingSize.height, 200))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to Snap"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        onboardingModel = model
        onboardingWindow = window
        // The one window allowed to activate Snap on its own: the user has to read it.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        wiring?.markOnboardingCompleted()
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingModel = nil
    }

    private func permissionChanged() {
        guard let wiring, let model = onboardingModel else { return }
        model.permissionGranted = wiring.permission.status == .granted
        model.offersRelaunch = wiring.permission.offersRelaunch
        model.cleanShotRunning = conflictingApps.isCleanShotRunning
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: System events

    private func observeSystem(_ wiring: AppWiring) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak wiring] _ in
            MainActor.assumeIsolated { wiring?.screenParametersChanged() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak wiring] _ in
            MainActor.assumeIsolated { wiring?.recheckPermission() }
        })
        sweepTimer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { [weak wiring] _ in
            MainActor.assumeIsolated { wiring?.sweepHistory() }
        }
    }
}
