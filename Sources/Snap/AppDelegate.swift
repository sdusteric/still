import AppKit
import ServiceManagement
import SnapCore
import SnapSystem
import SnapUI
import SwiftUI

/// The app lifecycle (design 5, 12, 13 and 20): menu bar only (`.accessory`), the status menu with
/// the recording timer, settings, global hotkeys with the CleanShot X hand-over, the first-run
/// window, and finishing a recording on quit and sleep. The capture graph lives in `AppWiring`.
/// Only the installed app runs this; tests, tools and the shot mode never do.
final class AppDelegate: NSObject, NSApplicationDelegate, ShelfActionHandling {
    private static let sweepInterval: TimeInterval = 60 * 60

    private var wiring: AppWiring?
    private var updater: Updater?
    private var menu: StatusMenuController?
    private var hotkeys: HotkeyCenter?
    private let conflictingApps = ConflictingApps()
    private var plan: HotkeyPlan?
    /// Key presses while Still's menu is open, when the hotkeys are released (see `menuTracking`).
    private var menuKeyMonitor: Any?
    /// Who holds the one key grab of `HotkeyCenter`.
    private enum GrabOwner { case none, overlay, scroll, card }
    private var grabOwner = GrabOwner.none
    private var registrationErrors: [ShortcutAction: String] = [:]
    private var symbolicEntries: [SymbolicHotkeyEntry] = []
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var onboardingModel: OnboardingModel?
    private var onboardingWindow: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var sweepTimer: Timer?
    /// Shelf actions that arrived before the capture graph existed.
    private var pendingShelfActions: [ShelfAction] = []
    private var pendingOpenItem: String?
    /// Quit waits this long for a recording to finish its file (design 20.6).
    private static let quitFinishTimeout: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, and launching never takes focus.
        NSApp.setActivationPolicy(.accessory)
        updater = Updater.make()
        let wiring = AppWiring()
        self.wiring = wiring
        wiring.onSettingsChanged = { [weak self] settings in self?.settingsModel?.settings = settings }
        wiring.onPermissionChanged = { [weak self] in self?.permissionChanged() }
        wiring.start()

        installMenu(wiring)
        installHotkeys(wiring)
        observeSystem(wiring)
        showOnboardingIfNeeded(wiring)
        let pending = pendingShelfActions
        pendingShelfActions = []
        pending.forEach(perform)
        if let id = pendingOpenItem {
            pendingOpenItem = nil
            openItem(id: id)
        }
    }

    // MARK: Shelf quick actions

    func application(_ application: NSApplication, open urls: [URL]) {
        let router = ShelfRouter(handler: self) { [weak self] message in
            self?.wiring?.log.info(message)
        }
        for url in urls where ShelfURL.isShelfURL(url) { router.handle(url) }
    }

    /// The same calls the hotkeys and the menu make.
    func perform(_ action: ShelfAction) {
        guard let wiring else {
            pendingShelfActions.append(action)
            return
        }
        switch action {
        case .captureArea: wiring.capture(.area)
        case .captureWindow: wiring.capture(.window)
        case .checkForUpdates: updater?.checkForUpdates()
        }
    }

    func openItem(id: String) {
        guard let wiring else {
            pendingOpenItem = id
            return
        }
        wiring.revealInHistory(id)
    }

    /// Opening Snap again from Finder, Spotlight or Launchpad shows Settings, so the app never
    /// seems to do nothing when its menu bar icon is hidden by macOS or behind other items.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(tab: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
        conflictingApps.stopObserving()
        sweepTimer?.invalidate()
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { workspace.removeObserver(token) }
        workspaceObservers.removeAll()
        menu?.uninstall()
        wiring?.stop()
    }

    /// Quitting during a recording finishes the file first, for up to 5 s (design D69).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = wiring?.recorder, recorder.isBusy else { return .terminateNow }
        wiring?.log.info("quit: finishing the recording first")
        recorder.finishForQuit(reason: .quit, timeout: Self.quitFinishTimeout) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menu

    private func installMenu(_ wiring: AppWiring) {
        let recorder = wiring.recorder
        let controller = StatusMenuController(
            modelProvider: { [weak self] in self?.menuModel() ?? MenuModel(MenuInput()) },
            recordingMenuProvider: { [weak recorder] in recorder?.recordingMenuModel },
            thumbnail: { [weak wiring] id in wiring?.menuThumbnail(for: id) },
            onSelect: { [weak self] id in self?.menuSelected(id) },
            onWillOpen: { [weak wiring] in wiring?.recheckPermission() },
            now: { [weak recorder] in recorder?.now() ?? SystemClock().now() }
        )
        controller.onTrackingChanged = { [weak self] open in self?.menuTracking(open) }
        recorder.onIndicatorChange = { [weak controller] indicator in controller?.setRecording(indicator) }
        recorder.onStallChange = { [weak controller] stall in controller?.setStall(stall) }
        controller.install()
        controller.setBadge(wiring.permission.showsBadge)
        menu = controller
    }

    private func menuModel() -> MenuModel {
        guard let wiring else { return MenuModel(MenuInput()) }
        return MenuModel(MenuInput(
            shortcuts: wiring.settings.shortcuts,
            recentCaptures: wiring.recentCaptures(),
            hasLastCapture: wiring.hasLastCapture,
            permissionNeeded: wiring.permission.needsAttention,
            offersRelaunch: wiring.permission.offersRelaunchFromMenu,
            hasPreviousArea: wiring.hasPreviousArea,
            hasClipboardImage: wiring.hasClipboardImage,
            plan: plan,
            offersUpdates: updater != nil,
            canPinLastCapture: wiring.canPinLastCapture,
            pins: wiring.pins.menuEntries.map(PinnedCaptureEntry.init),
            isRecording: wiring.recorder.isBusy
        ))
    }

    /// The menu fades out over about 0.2 s; a capture started at once froze it into the image.
    private static let menuFadeDelay: TimeInterval = 0.25

    private func menuSelected(_ id: MenuItemID) {
        guard let wiring else { return }
        let captures: Set<MenuItemID> = [
            .captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea, .captureScrolling, .allInOne, .recordScreen,
        ]
        if captures.contains(id), !wiring.recorder.isBusy {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuFadeDelay) { [weak self] in
                MainActor.assumeIsolated { self?.runMenuItem(id) }
            }
            return
        }
        runMenuItem(id)
    }

    private func runMenuItem(_ id: MenuItemID) {
        guard let wiring else { return }
        switch id {
        case .captureArea: wiring.capture(.area)
        case .capturePreviousArea: wiring.capturePreviousArea()
        case .captureScrolling: wiring.captureScrolling()
        case .copyLastCaptureText: wiring.copyLastCaptureText()
        case .relaunch: AppDelegate.relaunch()
        case .openImage: wiring.openImageFile()
        case .openClipboardImage: wiring.openClipboardImage()
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
        case .checkForUpdates: updater?.checkForUpdates()
        case .settings: openSettings(tab: nil)
        case .quit: NSApp.terminate(nil)
        case .allInOne: allInOne(eventTime: nil)
        case .recordScreen: recordScreen(eventTime: nil)
        case .pinLastCapture: wiring.pinLastCapture()
        case .captureHistory: wiring.openHistoryWindow()
        // A pin's row unlocks a click-through pin, like its Unlock item.
        case .pinnedCapture(let pinID), .unlockPin(let pinID): wiring.pins.unlock(pinID)
        case .closePin(let pinID): wiring.pins.close(pinID)
        case .closeAllPins: wiring.pins.closeAll()
        case .stopRecording: wiring.recorder.stop(reason: .user)
        case .cancelRecording: wiring.recorder.cancel()
        case .recentCapturesHeader, .noRecentCaptures, .separator, .pinnedCaptures, .recordingInfo, .lastCapture: break
        }
    }

    /// Cmd+Shift+5 and "All-in-One...": the HUD, or Stop while a recording runs (design 20.5).
    private func allInOne(eventTime: TimeInterval?) {
        guard let wiring else { return }
        if wiring.recorder.isBusy {
            wiring.recorder.stop(reason: eventTime == nil ? .user : .hotkey)
        } else {
            wiring.openHUD(eventTime: eventTime)
        }
    }

    /// "Record Screen..." and its shortcut: the HUD in Record mode, or Stop while recording.
    private func recordScreen(eventTime: TimeInterval?) {
        guard let wiring else { return }
        if wiring.recorder.isBusy {
            wiring.recorder.stop(reason: eventTime == nil ? .user : .hotkey)
        } else {
            wiring.openHUD(mode: .record, eventTime: eventTime)
        }
    }

    // MARK: Hotkeys

    private func installHotkeys(_ wiring: AppWiring) {
        let hotkeys = HotkeyCenter { [weak self] press in self?.hotkeyPressed(press) }
        self.hotkeys = hotkeys
        // Panels of a background app get no key events, so their keys arrive as grabbed hotkeys:
        // the overlay's while it is up, scrolling capture's while its bar shows, and a Quick Access
        // card's while it is hovered. There is one grab at a time; the card yields to the others.
        let overlay = wiring.overlay
        overlay.onKeyGrabChanged = { [weak self, weak hotkeys, weak overlay, weak wiring] active in
            guard let self, let hotkeys else { return }
            guard active else {
                if self.grabOwner == .overlay { hotkeys.releaseGrab(); self.grabOwner = .none }
                return
            }
            let keys = OverlayController.grabbedKeys
            let registered = hotkeys.grab(keys) { index, pressed in overlay?.grabbedKey(at: index, pressed: pressed) }
            self.grabOwner = .overlay
            if registered < keys.count {
                wiring?.log.warning("overlay: grabbed \(registered) of \(keys.count) keys; another app holds the rest")
            }
        }
        wiring.grabKeys = { [weak self, weak hotkeys] keys, onKey in
            hotkeys?.grab(keys, onKey: onKey)
            self?.grabOwner = .scroll
        }
        wiring.releaseKeys = { [weak self, weak hotkeys] in
            guard self?.grabOwner == .scroll else { return }
            hotkeys?.releaseGrab()
            self?.grabOwner = .none
        }
        let quickAccess = wiring.quickAccess
        quickAccess.onKeyGrabChanged = { [weak self, weak hotkeys, weak quickAccess] hovered in
            guard let self, let hotkeys else { return }
            if hovered {
                guard self.grabOwner == .none else { return }
                hotkeys.grab(QuickAccessController.grabbedKeys.map(\.shortcut)) { index, pressed in
                    if pressed { quickAccess?.grabbedKey(at: index) }
                }
                self.grabOwner = .card
            } else if self.grabOwner == .card {
                hotkeys.releaseGrab()
                self.grabOwner = .none
            }
        }
        readSymbolicHotkeys()
        applyHotkeys()
        // CleanShot X launching or quitting changes which combos Snap may register (design 12.3).
        conflictingApps.startObserving { [weak self] running in
            self?.wiring?.log.info("hotkeys: CleanShot X running: \(!running.isEmpty)")
            self?.applyHotkeys()
        }
    }

    /// macOS holds hotkey events while the app's own menu is open, so ⇧⌘4 waited for the menu to
    /// close. Meanwhile the hotkeys are released and key presses matched against the plan here:
    /// a match closes the menu and runs at once. The menu's own key equivalents are the fallback.
    private func menuTracking(_ open: Bool) {
        if open {
            guard menuKeyMonitor == nil, let plan else { return }
            hotkeys?.unregisterAll()
            menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let action = MainActor.assumeIsolated {
                    plan.action(keyCode: UInt32(event.keyCode), modifiers: AppDelegate.carbonModifiers(event.modifierFlags))
                }
                guard let action else { return event }
                MainActor.assumeIsolated {
                    self?.menu?.closeMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.menuFadeDelay) {
                        self?.hotkeyPressed(HotkeyPress(
                            action: action, eventTime: event.timestamp, receivedUptime: ProcessInfo.processInfo.systemUptime
                        ))
                    }
                }
                return nil
            }
        } else {
            if let menuKeyMonitor { NSEvent.removeMonitor(menuKeyMonitor) }
            menuKeyMonitor = nil
            applyHotkeys()
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyShortcut.Modifier.command }
        if flags.contains(.shift) { modifiers |= KeyShortcut.Modifier.shift }
        if flags.contains(.option) { modifiers |= KeyShortcut.Modifier.option }
        if flags.contains(.control) { modifiers |= KeyShortcut.Modifier.control }
        return modifiers
    }

    private func hotkeyPressed(_ press: HotkeyPress) {
        guard let wiring else { return }
        let eventTime = press.time(on: SystemClock())
        switch press.action {
        case .captureArea: wiring.capture(.area, eventTime: eventTime)
        case .capturePreviousArea: wiring.capturePreviousArea(eventTime: eventTime)
        case .captureScrolling: wiring.captureScrolling(eventTime: eventTime)
        case .captureWindow: wiring.capture(.window, eventTime: eventTime)
        case .captureFullscreen: wiring.capture(.fullscreen, eventTime: eventTime)
        case .applyBackground: wiring.applyBackgroundToLastCapture()
        case .openInAnnotate: wiring.openLastCaptureInAnnotate()
        case .allInOne: allInOne(eventTime: eventTime)
        case .recordScreen: recordScreen(eventTime: eventTime)
        case .stopRecording:
            if wiring.recorder.isBusy { wiring.recorder.stop(reason: .hotkey) }
        case .pinLastCapture: wiring.pinLastCapture()
        case .openHistory: wiring.openHistoryWindow()
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
            var actions = SettingsActions(
                settingsChanged: { [weak self] settings in self?.settingsChanged(settings) },
                setLaunchAtLogin: { enabled in AppDelegate.setLaunchAtLogin(enabled) },
                chooseSaveFolder: { AppDelegate.chooseFolder() },
                saveFolder: { [paths = wiring.paths] settings in paths.saveFolder(for: settings) },
                evaluateShortcuts: { [weak self] shortcuts in self?.evaluate(shortcuts) },
                editPreset: { [weak wiring] id in wiring?.editPreset(id: id) },
                recordingChanged: { [weak self] recording in self?.recordingChanged(recording) },
                now: { Date() },
                // The Settings switch is one of the two places allowed to ask (design D65).
                requestMicrophoneAccess: { [weak wiring] in
                    guard let microphone = wiring?.microphone else { return .notDetermined }
                    _ = await microphone.requestAccess()
                    return microphone.status()
                },
                openMicrophonePrivacySettings: {
                    if let url = MicrophoneAuthorization.privacySettingsURL { NSWorkspace.shared.open(url) }
                }
            )
            actions.runningAppNames = {
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
            }
            let model = SettingsModel(
                settings: wiring.settings, tab: tab ?? .general, plan: plan, registrationErrors: registrationErrors,
                presets: wiring.presetStore.presets, starredPresetID: wiring.presetStore.starredID,
                microphoneAccess: wiring.microphone.status(), microphones: wiring.microphoneDevices(), actions: actions
            )
            let controller = SettingsWindowController(model: model)
            model.updates = updater.map { UpdateSettingsModel(updater: $0) }
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
        settingsModel?.microphoneAccess = wiring.microphone.status()
        settingsModel?.microphones = wiring.microphoneDevices()
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
        window.title = "Welcome to Still"
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
        guard let wiring else { return }
        // The badge and the menu row say a capture failed for permission (design 13).
        menu?.setBadge(wiring.permission.showsBadge)
        guard let model = onboardingModel else { return }
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
        // The Mac going to sleep finishes a running recording (design D69).
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak wiring] _ in
            MainActor.assumeIsolated {
                guard let recorder = wiring?.recorder, recorder.isBusy else { return }
                recorder.stop(reason: .sleep)
            }
        })
        sweepTimer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { [weak wiring] _ in
            MainActor.assumeIsolated { wiring?.sweepHistory() }
        }
        // The sweep has no deadline, so macOS may fold its wake-up into others.
        sweepTimer?.tolerance = Self.sweepInterval / 6
    }
}
