import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SnapCore
import SnapSystem
import SnapUI
import UniformTypeIdentifiers

/// The capture graph of the running app (design 5 and 20): the live ScreenCaptureKit and window
/// sources, the overlay panels with the all-in-one HUD, the Quick Access stack, pins, the history
/// window, the recorder, the pasteboard writer, the stores and the editors, joined through
/// `CaptureCoordinator`. Pins live in `PinWiring.swift`, recording in `RecordingWiring.swift`.
/// `AppDelegate` owns one and adds the menu, settings, hotkeys and onboarding. Never created by
/// tests, tools or the shot mode.
final class AppWiring: CaptureResultPresenter {
    /// One capture as the app tracks it: the card it is on, its pixels and its history item.
    final class CaptureRecord {
        let cardID: String
        /// Keeps the trace alive so its `ObjectIdentifier` stays unique while the record exists.
        let trace: CaptureTrace?
        let original: CapturedImage
        let createdAt: Date
        let sourceApp: String?
        let mode: CaptureMode
        /// Where the capture was on screen, global top-left points (pin placement, design D47).
        let screenRect: CGRect?
        var item: CaptureItem?
        var stored: Task<StoredCapture?, Never>?
        /// The Background or editor render, once made.
        var edited: CapturedImage?
        var showingEdited = false
        /// The editable annotations and Background of the edit (`annotations.json`, design 20.4),
        /// nil until the capture is edited.
        var annotations: AnnotationFile?
        /// False for a capture edited before `item.json` version 3: its edited PNG has no
        /// annotation file, so the annotate editor opens on that PNG and no file is written.
        var editsAreReproducible = true

        init(
            cardID: String, trace: CaptureTrace?, original: CapturedImage, createdAt: Date, sourceApp: String?,
            mode: CaptureMode, screenRect: CGRect?
        ) {
            self.cardID = cardID
            self.trace = trace
            self.original = original
            self.createdAt = createdAt
            self.sourceApp = sourceApp
            self.mode = mode
            self.screenRect = screenRect
        }

        var current: CapturedImage { showingEdited ? (edited ?? original) : original }

        /// The card's Background button shows the applied state.
        var backgroundApplied: Bool { showingEdited && (annotations.map { $0.background != nil } ?? true) }

        /// The annotation file to keep with the next edited PNG, nil when edits are not reproducible.
        var annotationsToStore: AnnotationFile? { editsAreReproducible ? annotations : nil }

        var currentURL: URL? {
            guard let item else { return nil }
            return showingEdited ? (item.editedURL ?? item.originalURL) : item.originalURL
        }
    }

    /// Records kept for the menu's last-capture actions after their cards close.
    private static let recordLimit = 12
    /// Recent capture thumbnails in the menu are drawn from images at most this many pixels wide.
    private static let menuThumbnailPixels = 64

    let paths: SnapPaths
    let log: Log
    let settingsStore: SettingsStore
    let stateStore: StateStore
    let presetStore: PresetStore
    let history: HistoryStore
    let clock = SystemClock()
    let captureSource: LiveCaptureSource
    private let windowSource = LiveWindowSource()
    let clipboard = PasteboardWriter()
    let overlay: OverlayController
    let quickAccess: QuickAccessController
    let hint: PermissionHintController
    let pins: PinController
    /// Microphone access (design 20.7): asked at most once, only from the Settings switch or the
    /// HUD's Options menu.
    let microphone: MicrophoneAuthorization
    private(set) var permission: PermissionState

    lazy var coordinator = CaptureCoordinator(
        captureSource: captureSource,
        windowSource: windowSource,
        overlay: overlay,
        results: self,
        output: CaptureOutputStage(history: history, clipboard: clipboard, clock: clock, log: log),
        clock: clock,
        log: log,
        configuration: { [weak self] in self?.captureConfiguration() ?? CaptureConfiguration() }
    )

    lazy var recorder = RecordingWiring(app: self)

    var records: [String: CaptureRecord] = [:]
    private(set) var recordOrder: [String] = []
    private var cardForTrace: [ObjectIdentifier: String] = [:]
    private var backgroundPanels: [ObjectIdentifier: BackgroundEditorPanel] = [:]
    private var annotateWindows: [ObjectIdentifier: AnnotateWindowController] = [:]
    /// History ids an open Background editor or annotate window works on, for the sweep.
    private var editorItems: [ObjectIdentifier: String] = [:]
    private var menuThumbnails: [String: CGImage] = [:]
    /// Video cards by card id (design 20.6, D67): the recording each one shows.
    var videoCards: [String: CaptureItem] = [:]
    private var historyWindow: HistoryWindowController?

    /// Called after the app changed settings on its own (key hints off after 10 captures).
    var onSettingsChanged: ((SnapCore.Settings) -> Void)?
    /// Called when the permission state may have changed (a grant, a lapse).
    var onPermissionChanged: (() -> Void)?

    init(paths: SnapPaths = SnapPaths()) {
        self.paths = paths
        do {
            try paths.createDirectories()
        } catch {
            FileHandle.standardError.write(Data("Snap: cannot create \(paths.home.path(percentEncoded: false)): \(error)\n".utf8))
        }
        let log = Log(paths: paths)
        self.log = log
        let settingsStore = SettingsStore(paths: paths)
        let stateStore = StateStore(paths: paths)
        let presetStore = PresetStore(paths: paths)
        Self.load("settings", log: log) { try settingsStore.load() }
        Self.load("state", log: log) { try stateStore.load() }
        Self.load("presets", log: log) { try presetStore.load() }
        self.settingsStore = settingsStore
        self.stateStore = stateStore
        self.presetStore = presetStore
        history = HistoryStore(paths: paths, clock: clock, log: log)
        captureSource = LiveCaptureSource(log: log)

        let settings = settingsStore.settings
        overlay = OverlayController(
            options: OverlayController.Options(settings: settings.capture),
            cursor: SystemOverlayCursor(),
            pointerLocation: { AppWiring.globalPointer() },
            visibleDisplays: { _ in ScreenSpace.visibleDisplays() },
            makeSurface: { display, all, sink in
                OverlayPanel.makeSurface(display: display, allDisplays: all, eventSink: sink)
            }
        )
        quickAccess = QuickAccessController(
            clock: clock,
            settings: settings.quickAccess,
            visibleFrame: { AppWiring.screenUnderPointer()?.visibleFrame },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            makeSurface: { QuickAccessPanel.makeSurface(controller: $0) }
        )
        hint = PermissionHintController(
            clock: clock,
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            onOpenSettings: { AppWiring.openScreenRecordingSettings() },
            makeSurface: { PermissionHintPanel.makeSurface(controller: $0) }
        )
        permission = PermissionState(
            source: PermissionProbe.Source(),
            requestedAt: stateStore.state.screenRecordingRequested
        )
        microphone = MicrophoneAuthorization(stateStore: stateStore, log: log)
        pins = PinController(
            clock: clock,
            displays: { ScreenSpace.visibleDisplays() },
            pointer: { AppWiring.globalPointer() },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            makeSurface: { PinPanel.makeSurface(controller: $0, model: $1) }
        )
        quickAccess.actions = makeQuickAccessActions()
        pins.actions = makePinActions()
        overlay.hudOptionItems = { [weak self] mode in self?.hudOptionItems(mode) ?? [] }
        overlay.onHUDOption = { [weak self] option in self?.hudOptionChosen(option) }
        coordinator.onAreaConfirmed = { [weak self] area in self?.storeLastArea(area) }
    }

    private static func load(_ name: String, log: Log, _ body: () throws -> StoreLoadOutcome) {
        do {
            switch try body() {
            case .missing, .loaded: break
            case .recovered(let url): log.warning("\(name): unreadable file moved to \(url.lastPathComponent)")
            case .newerVersion(let url): log.warning("\(name): newer file moved to \(url.lastPathComponent)")
            }
        } catch {
            log.error("\(name): load failed: \(error)")
        }
    }

    // MARK: Lifecycle

    /// Marks leftover recordings interrupted, sweeps old history and, when permission is already
    /// granted, builds the overlay panels. Without permission nothing touches ScreenCaptureKit, so
    /// launch never prompts.
    func start() {
        log.info("launch: SNAP_HOME \(paths.home.path(percentEncoded: false)), permission \(permission.status)")
        persistMigratedSettings()
        sweepHistory(markInterruptedFirst: true)
        if permission.status == .granted {
            Task { await refreshDisplays() }
        }
    }

    func stop() {
        quickAccess.closeAll()
        pins.closeAll()
        log.info("quit")
    }

    /// A version 1 `settings.json` is migrated on load (design D56); writing it back once keeps
    /// the file at version 2 so the migration never runs again.
    private func persistMigratedSettings() {
        guard FileManager.default.fileExists(atPath: paths.settingsFile.path(percentEncoded: false)) else { return }
        do {
            let data = try Data(contentsOf: paths.settingsFile)
            let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int
            guard let version, version < SnapCore.Settings.currentVersion else { return }
            // The store holds the migrated settings but sees no change to write, so write them here.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try AtomicFile.write(encoder.encode(settingsStore.settings), to: paths.settingsFile)
            log.info("settings: migrated settings.json from version \(version)")
        } catch {
            log.warning("settings: cannot check the settings version: \(error)")
        }
    }

    /// Display list and overlay panels, refreshed at launch and on screen changes (design 6.1).
    func refreshDisplays() async {
        do {
            let displays = try await coordinator.refreshDisplays()
            overlay.screenParametersChanged(displays: displays)
        } catch {
            log.warning("displays: \(error)")
        }
    }

    func screenParametersChanged() {
        pins.displaysChanged()
        coordinator.cancel()
        guard permission.status == .granted else { return }
        Task {
            await captureSource.invalidate()
            await refreshDisplays()
        }
    }

    /// Removes items past retention, skipping every item in use (design D54). At launch the
    /// leftover `recording` items become `interrupted` first (design 20.4 step 4).
    func sweepHistory(markInterruptedFirst: Bool = false) {
        let history = history
        let log = log
        let inUse = inUseItemIDs()
        Task {
            let removed = await Task.detached(priority: .utility) { () -> [String] in
                if markInterruptedFirst {
                    do {
                        let marked = try history.markInterrupted()
                        if !marked.isEmpty { log.info("history: \(marked.count) interrupted recordings") }
                    } catch {
                        log.warning("history: cannot mark interrupted recordings: \(error)")
                    }
                }
                do {
                    let removed = try history.sweep(skipping: inUse)
                    if !removed.isEmpty { log.info("history: swept \(removed.count) items, skipped \(inUse.count) in use") }
                    return removed
                } catch {
                    log.warning("history: sweep failed: \(error)")
                    return []
                }
            }.value
            if !removed.isEmpty || markInterruptedFirst { historyChanged() }
        }
    }

    /// Items the sweep must keep for now: open cards, pins, open editors, the history selection
    /// shown in Quick Access (it has a card) and a recording in progress.
    func inUseItemIDs() -> Set<String> {
        var ids = Set<String>()
        for record in records.values where quickAccess.card(record.cardID) != nil {
            if let id = record.item?.id { ids.insert(id) }
        }
        for (cardID, item) in videoCards where quickAccess.card(cardID) != nil {
            ids.insert(item.id)
        }
        ids.formUnion(pins.pinnedItemIDs)
        ids.formUnion(editorItems.values)
        if let id = recorder.activeItemID { ids.insert(id) }
        return ids
    }

    /// The in-process notification the history window reloads on (design 20.3).
    func historyChanged() {
        menuThumbnails = [:]
        NotificationCenter.default.post(name: HistoryWindowController.historyDidChange, object: nil)
    }

    // MARK: Settings

    var settings: SnapCore.Settings { settingsStore.settings }

    /// Stores new settings and applies them to the overlay and the Quick Access stack.
    func replaceSettings(_ new: SnapCore.Settings) {
        guard new != settingsStore.settings else { return }
        do {
            try settingsStore.update { $0 = new }
        } catch {
            log.error("settings: write failed: \(error)")
        }
        let stored = settingsStore.settings
        overlay.options = OverlayController.Options(settings: stored)
        quickAccess.apply(settings: stored.quickAccess)
    }

    /// The overlay panels are excluded only when the capture shows them (not fullscreen); the
    /// Quick Access and hint panels whenever they are on screen, so an earlier card is never
    /// baked into the next frozen image (design 6.2 step 3).
    private func captureConfiguration() -> CaptureConfiguration {
        CaptureConfiguration(
            settings: settings, paths: paths,
            overlayWindowIDs: overlay.surfaceWindowIDs,
            excludedWindowIDs: quickAccess.surfaceWindowIDs + hint.surfaceWindowIDs
        )
    }

    // MARK: Capture

    /// A capture hotkey or menu item. Shows the permission hint instead when permission is
    /// missing; never requests it.
    func capture(_ mode: CaptureMode, eventTime: TimeInterval? = nil) {
        guard !coordinator.isCapturing else { return }
        if permission.hotkeyPressed() == .showHint {
            log.info("capture \(mode.rawValue): no Screen Recording permission, showing the hint")
            showPermissionHint()
            onPermissionChanged?()
            return
        }
        overlay.options = OverlayController.Options(settings: settings)
        let pointer = AppWiring.globalPointer()
        Task {
            if coordinator.displays.isEmpty {
                await refreshDisplays()
            } else {
                // The panels must exist before the configuration lists them for exclusion.
                overlay.prepare(displays: coordinator.displays)
            }
            let ticket = await coordinator.run(mode: mode, eventTime: eventTime, pointer: pointer)
            guard let ticket, let cardID = cardForTrace[ObjectIdentifier(ticket.result.trace)] else { return }
            records[cardID]?.stored = ticket.stored
        }
    }

    func showPermissionHint() {
        guard let screen = AppWiring.screenUnderPointer() else { return }
        hint.show(near: NSEvent.mouseLocation, visibleFrame: screen.visibleFrame)
    }

    // MARK: CaptureResultPresenter

    func showCard(for capture: CaptureResult) {
        let record = addRecord(for: capture)
        quickAccess.show(QuickAccessItem(
            id: record.cardID, thumbnail: capture.image.cgImage, pointSize: capture.image.pointSize,
            copied: settings.capture.copyToClipboard
        ))
    }

    func captureStored(_ stored: StoredCapture) {
        let record = cardForTrace[ObjectIdentifier(stored.result.trace)].flatMap { records[$0] }
            ?? addRecord(for: stored.result)
        record.item = stored.item
        if let saved = stored.savedURL { quickAccess.markSaved(record.cardID, url: saved) }
        historyChanged()

        let wasLapsed = permission.status != .granted
        permission.captureSucceeded()
        if wasLapsed { onPermissionChanged?() }
        countCapture(stored.item.id)
        playShutterIfEnabled()
        if settings.capture.openInAnnotate { annotate(record.cardID) }
    }

    func captureFailed(_ failure: CaptureFailure) {
        log.warning("capture \(failure.mode.rawValue) failed at \(failure.stage.rawValue): \(failure.message)")
        guard failure.stage == .capture else { return }
        let code = failure.isPermissionError ? PermissionState.userDeclinedErrorCode : nil
        if permission.captureFailed(errorCode: code) == .showHint {
            showPermissionHint()
        }
        onPermissionChanged?()
    }

    /// A recording start was declined (-3801): the same hint as a declined screenshot (design D69).
    func screenRecordingDenied() {
        if permission.captureFailed(errorCode: PermissionState.userDeclinedErrorCode) == .showHint {
            showPermissionHint()
        }
        onPermissionChanged?()
    }

    private func addRecord(for result: CaptureResult) -> CaptureRecord {
        let record = CaptureRecord(
            cardID: "card-" + UUID().uuidString.lowercased(), trace: result.trace, original: result.image,
            createdAt: result.createdAt, sourceApp: result.sourceApp, mode: result.mode,
            screenRect: result.mode == .fullscreen ? nil : result.rect
        )
        insert(record)
        cardForTrace[ObjectIdentifier(result.trace)] = record.cardID
        return record
    }

    private func insert(_ record: CaptureRecord) {
        records[record.cardID] = record
        recordOrder.append(record.cardID)
        // Drop the oldest records whose cards are closed; their files stay in history.
        while recordOrder.count > Self.recordLimit,
              let index = recordOrder.firstIndex(where: { quickAccess.card($0) == nil }) {
            let id = recordOrder.remove(at: index)
            if let trace = records[id]?.trace { cardForTrace[ObjectIdentifier(trace)] = nil }
            records[id] = nil
        }
    }

    /// Counts captures for the key hints: after the 10th the app turns "Show key hints" off once
    /// (design 17.6); the user can turn it back on in settings.
    private func countCapture(_ id: String) {
        var reachedLimit = false
        do {
            try stateStore.update { state in
                state.lastCaptureID = id
                state.captureCount += 1
                reachedLimit = state.captureCount == SnapState.keyHintCaptureLimit
            }
        } catch {
            log.warning("state: write failed: \(error)")
        }
        if reachedLimit && settings.capture.showKeyHints {
            var new = settings
            new.capture.showKeyHints = false
            replaceSettings(new)
            onSettingsChanged?(settingsStore.settings)
        }
    }

    private func playShutterIfEnabled() {
        guard settings.general.playSound else { return }
        let shutter = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        let sound = NSSound(contentsOfFile: shutter, byReference: true) ?? NSSound(named: NSSound.Name("Pop"))
        sound?.volume = 0.4
        sound?.play()
    }

    // MARK: Quick Access actions

    private func makeQuickAccessActions() -> QuickAccessActions {
        QuickAccessActions(
            copy: { [weak self] id in await self?.copyCard(id, as: .image) ?? false },
            copyFile: { [weak self] id in await self?.copyCard(id, as: .file) ?? false },
            save: { [weak self] id in await self?.saveCard(id) },
            toggleBackground: { [weak self] id in await self?.toggleBackground(id) },
            openBackgroundEditor: { [weak self] id in self?.openBackgroundEditor(cardID: id) },
            annotate: { [weak self] id in self?.annotate(id) },
            reveal: { url in AppWiring.reveal(url) },
            dragURL: { [weak self] id in self?.videoCards[id]?.originalURL ?? self?.records[id]?.currentURL },
            pin: { [weak self] id in await self?.pinCard(id) ?? false },
            open: { [weak self] id in
                guard let url = self?.videoCards[id]?.originalURL else { return }
                NSWorkspace.shared.open(url)
            },
            closed: { [weak self] id, reason in
                self?.videoCards[id] = nil
                self?.log.info("card \(id) closed: \(reason)")
            }
        )
    }

    private func copyCard(_ id: String, as kind: ClipboardCopy.Kind) async -> Bool {
        // A video card copies its mp4's file URL (design D67).
        if let video = videoCards[id] { return copyFileURLs([video.originalURL]) }
        guard let record = records[id] else { return false }
        // Copy File right after the capture waits for the history write that makes the file.
        if kind == .file, record.item == nil, let stored = record.stored, let item = await stored.value?.item {
            record.item = item
        }
        return await copyToClipboard(record.current, kind: kind, fileURL: record.currentURL)
    }

    private func saveCard(_ id: String) async -> URL? {
        if let video = videoCards[id] { return await saveVideo(video) }
        guard let record = records[id] else { return nil }
        let image = record.current
        let folder = paths.saveFolder(for: settings)
        let pattern = settings.general.fileNamePattern
        let date = record.createdAt
        let app = record.sourceApp
        let log = log
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            do {
                return try AppWiring.write(image, toFolder: folder, pattern: pattern, date: date, app: app)
            } catch {
                log.error("save: \(error)")
                return nil
            }
        }.value
    }

    /// One click on Background: renders the default preset around the capture (with its
    /// annotations, when it has any), or removes it again (design 10.4). The edit and its
    /// annotation file go to history, so the next reopen shows the same state.
    private func toggleBackground(_ id: String) async -> QuickAccessThumbnail? {
        guard let record = records[id] else { return nil }
        let annotated = record.editsAreReproducible && record.annotations?.hasAnnotations == true
        if record.backgroundApplied {
            record.annotations?.background = nil
            guard annotated, let base = await annotatedBase(record) else {
                record.showingEdited = false
                return QuickAccessThumbnail(
                    image: record.original.cgImage, pointSize: record.original.pointSize, backgroundApplied: false
                )
            }
            record.edited = base
            record.showingEdited = true
            await storeEdited(base, for: record)
            return QuickAccessThumbnail(image: base.cgImage, pointSize: base.pointSize, backgroundApplied: false)
        }
        guard let source = await annotatedBase(record) else { return nil }
        let preset = defaultPreset
        let log = log
        let rendered = await Task.detached(priority: .userInitiated) { () -> CapturedImage? in
            do {
                let output = try BeautifyRenderer.render(source.cgImage, scale: source.scale, preset: preset)
                return CapturedImage(cgImage: output.image, scale: output.geometry.outputScale)
            } catch {
                log.error("background: \(error)")
                return nil
            }
        }.value
        guard let rendered else { return nil }
        if record.editsAreReproducible {
            var file = record.annotations ?? AnnotationFile()
            file.background = preset
            record.annotations = file
        }
        record.edited = rendered
        record.showingEdited = true
        await storeEdited(rendered, for: record)
        return QuickAccessThumbnail(image: rendered.cgImage, pointSize: rendered.pointSize, backgroundApplied: true)
    }

    /// The capture with its annotations burned in and no Background: what Background is drawn
    /// around. The original when there are no annotations (or they cannot be reproduced).
    private func annotatedBase(_ record: CaptureRecord) async -> CapturedImage? {
        guard record.editsAreReproducible, let file = record.annotations, file.hasAnnotations else { return record.original }
        var plain = file
        plain.background = nil
        let original = record.original
        let log = log
        return await Task.detached(priority: .userInitiated) { () -> CapturedImage? in
            do {
                let output = try plain.render(original: original.cgImage, scale: original.scale)
                return CapturedImage(cgImage: output.image, scale: output.scale)
            } catch {
                log.error("annotate: cannot flatten the annotations: \(error)")
                return nil
            }
        }.value
    }

    /// The preset one-click Background uses: the one chosen in settings, else the starred one.
    private var defaultPreset: BackgroundPreset {
        settings.quickAccess.defaultPresetID.flatMap { presetStore.preset(id: $0) } ?? presetStore.starred
    }

    /// Writes `<file name> (edited).png` into the record's history folder once the original is there.
    private func storeEdited(_ image: CapturedImage, for record: CaptureRecord) async {
        var item = record.item
        if item == nil, let stored = record.stored {
            item = await stored.value?.item
        }
        guard let id = item?.id else {
            log.warning("history: no item for \(record.cardID); edited image kept in memory only")
            return
        }
        let history = history
        let log = log
        let annotations = record.annotationsToStore
        let updated = await Task.detached(priority: .userInitiated) { () -> CaptureItem? in
            do {
                return try history.saveEdited(
                    id: id, pngData: PNGWriter.data(for: image.cgImage, scale: image.scale), annotations: annotations
                )
            } catch {
                log.error("history: edited write for \(id) failed: \(error)")
                return nil
            }
        }.value
        if let updated {
            record.item = updated
            historyChanged()
        }
    }

    // MARK: Editors

    func openBackgroundEditor(cardID: String) {
        guard let record = records[cardID] else { return }
        Task {
            guard let base = await annotatedBase(record) else { return }
            openBackgroundEditor(source: base, record: record, preset: record.annotations?.background ?? defaultPreset)
        }
    }

    /// "Edit..." next to the default preset in settings: the editor on the last capture, or on the
    /// sample capture when there is none yet.
    func editPreset(id: String) {
        let preset = presetStore.preset(id: id) ?? defaultPreset
        if let record = lastRecord {
            openBackgroundEditor(source: record.original, record: record, preset: preset)
        } else if let sample = DemoCapture.notesWindow(dark: false) {
            openBackgroundEditor(source: CapturedImage(cgImage: sample, scale: 2), record: nil, preset: preset)
        }
    }

    private func openBackgroundEditor(source: CapturedImage, record: CaptureRecord?, preset: BackgroundPreset) {
        let actions = BackgroundEditorActions(
            copy: { [weak self] output, preset in self?.editorRendered(output, preset: preset, record: record, copy: true) },
            save: { [weak self] output, preset in self?.editorRendered(output, preset: preset, record: record, copy: false) },
            savePreset: { [weak self] preset in self?.withPresets { try $0.save(preset) } },
            setDefault: { [weak self] id in self?.withPresets { _ = try $0.setStarred(id: id) } },
            deletePreset: { [weak self] id in self?.withPresets { try $0.delete(id: id) } },
            chooseImage: { AppWiring.chooseImage() }
        )
        let model = BackgroundEditorModel(
            source: source.cgImage, scale: source.scale, preset: preset,
            presets: presetStore.presets, defaultPresetID: presetStore.starredID, actions: actions
        )
        let panel = BackgroundEditorPanel(model: model)
        let key = ObjectIdentifier(panel)
        backgroundPanels[key] = panel
        editorItems[key] = record?.item?.id
        panel.onClose = { [weak self] in
            self?.backgroundPanels[key] = nil
            self?.editorItems[key] = nil
        }
        panel.present()
    }

    private func withPresets(_ body: (PresetStore) throws -> Void) {
        do {
            try body(presetStore)
        } catch {
            log.error("presets: \(error)")
        }
    }

    /// Copy or Save in the Background editor: the render becomes the card's edited image, and
    /// its preset the Background of the annotation file.
    private func editorRendered(
        _ output: BeautifyRenderer.Output, preset: BackgroundPreset, record: CaptureRecord?, copy: Bool
    ) {
        let image = CapturedImage(cgImage: output.image, scale: output.geometry.outputScale)
        let createdAt = record?.createdAt ?? clock.date()
        let app = record?.sourceApp
        Task {
            if copy {
                _ = await copyToClipboard(image)
            } else {
                do {
                    let url = try AppWiring.write(
                        image, toFolder: paths.saveFolder(for: settings), pattern: settings.general.fileNamePattern,
                        date: createdAt, app: app
                    )
                    if let record { quickAccess.markSaved(record.cardID, url: url) }
                } catch {
                    log.error("background save: \(error)")
                }
            }
            guard let record else { return }
            if record.editsAreReproducible {
                var file = record.annotations ?? AnnotationFile()
                file.background = preset
                record.annotations = file
            }
            record.edited = image
            record.showingEdited = true
            quickAccess.updateThumbnail(
                record.cardID, with: QuickAccessThumbnail(image: image.cgImage, pointSize: image.pointSize, backgroundApplied: true)
            )
            await storeEdited(image, for: record)
        }
    }

    /// The annotate editor (design 11, 20.4). A capture with an annotation file opens on its
    /// original with every annotation editable; Copy and Save flatten them, add the Background
    /// when one is applied, and keep the file next to the history item.
    func annotate(_ cardID: String) {
        guard let record = records[cardID] else { return }
        let document: AnnotationDocument
        if record.editsAreReproducible {
            let original = record.original
            document = record.annotations?.document(image: original.cgImage, scale: original.scale)
                ?? AnnotationDocument(image: original.cgImage, scale: original.scale)
        } else {
            // Edited before version 3: there is nothing to rebuild, so the edit opens flattened.
            let image = record.current
            document = AnnotationDocument(image: image.cgImage, scale: image.scale)
        }
        let actions = AnnotateActions(
            copy: { [weak self] flattened, scale in
                self?.annotateExported(CapturedImage(cgImage: flattened, scale: scale), record: record, copy: true)
            },
            save: { [weak self] flattened, scale in
                self?.annotateSaved(CapturedImage(cgImage: flattened, scale: scale), record: record)
            },
            saveAs: { [weak self] flattened, scale in
                AppWiring.saveAs(self?.withBackground(CapturedImage(cgImage: flattened, scale: scale), record: record)
                    ?? CapturedImage(cgImage: flattened, scale: scale))
            },
            background: { [weak self] flattened, scale in
                guard let self else { return }
                openBackgroundEditor(
                    source: CapturedImage(cgImage: flattened, scale: scale), record: record,
                    preset: record.annotations?.background ?? defaultPreset
                )
            },
            reveal: { url in AppWiring.reveal(url) },
            saveFolderName: paths.saveFolder(for: settings).lastPathComponent,
            keep: { document in
                guard record.editsAreReproducible else { return }
                record.annotations = AnnotationFile(document: document, background: record.annotations?.background)
            },
            backgroundApplied: record.editsAreReproducible && record.annotations?.background != nil
        )
        let controller = AnnotateWindowController(document: document, actions: actions)
        let key = ObjectIdentifier(controller)
        annotateWindows[key] = controller
        editorItems[key] = record.item?.id
        controller.onClose = { [weak self] in
            self?.annotateWindows[key] = nil
            self?.editorItems[key] = nil
        }
        controller.present()
    }

    /// The annotated image with the record's Background drawn around it, when one is applied.
    private func withBackground(_ image: CapturedImage, record: CaptureRecord) -> CapturedImage {
        guard record.editsAreReproducible, let preset = record.annotations?.background else { return image }
        do {
            let output = try BeautifyRenderer.render(image.cgImage, scale: image.scale, preset: preset)
            return CapturedImage(cgImage: output.image, scale: output.geometry.outputScale)
        } catch {
            log.error("annotate: background: \(error)")
            return image
        }
    }

    private func annotateExported(_ annotated: CapturedImage, record: CaptureRecord, copy: Bool) {
        let image = withBackground(annotated, record: record)
        record.edited = image
        record.showingEdited = true
        // The card shows what its Copy, Save and drag now use.
        if quickAccess.card(record.cardID) != nil {
            quickAccess.updateThumbnail(record.cardID, with: QuickAccessThumbnail(
                image: image.cgImage, pointSize: image.pointSize, backgroundApplied: record.backgroundApplied
            ))
        }
        Task {
            if copy { _ = await copyToClipboard(image) }
            await storeEdited(image, for: record)
        }
    }

    private func annotateSaved(_ annotated: CapturedImage, record: CaptureRecord) -> URL? {
        let image = withBackground(annotated, record: record)
        do {
            let url = try AppWiring.write(
                image, toFolder: paths.saveFolder(for: settings), pattern: settings.general.fileNamePattern,
                date: record.createdAt, app: record.sourceApp
            )
            annotateExported(annotated, record: record, copy: false)
            return url
        } catch {
            log.error("annotate save: \(error)")
            return nil
        }
    }

    // MARK: Menu

    func recentCaptures() -> [CaptureItem] {
        do {
            return try history.recent(limit: MenuModel.recentLimit)
        } catch {
            log.warning("history: \(error)")
            return []
        }
    }

    var hasLastCapture: Bool { lastRecord != nil || !recentCaptures().isEmpty }

    /// "Pin Last Capture" is enabled when the last capture is a screenshot (recordings cannot be pinned).
    var canPinLastCapture: Bool {
        if lastRecord != nil { return true }
        return recentCaptures().first { $0.state == .complete }?.kind == .image
    }

    /// A small thumbnail of a history item for the menu, read once and cached.
    func menuThumbnail(for id: String) -> CGImage? {
        if let cached = menuThumbnails[id] { return cached }
        let url: URL?
        do {
            url = try history.item(id: id)?.thumbnailURL
        } catch {
            url = nil
        }
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.menuThumbnailPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        menuThumbnails[id] = thumbnail
        return thumbnail
    }

    var lastRecord: CaptureRecord? {
        recordOrder.reversed().lazy.compactMap { self.records[$0] }.first { $0.item != nil || $0.stored != nil }
    }

    /// "Apply Background to Last Capture": on its card, shown again when it has closed.
    func applyBackgroundToLastCapture() {
        guard let cardID = cardForLastCapture() else { return }
        Task { await quickAccess.perform(.background, on: cardID) }
    }

    func openLastCaptureInAnnotate() {
        guard let cardID = cardForLastCapture(showCard: false) else { return }
        annotate(cardID)
    }

    /// A Recent Captures entry, a pin's Show in Quick Access or the history window: its card again
    /// with a fresh timer, never touching the clipboard (design 20.3). A recording gets its video card.
    func showRecentCapture(id: String) {
        if let record = records.values.first(where: { $0.item?.id == id }), quickAccess.card(record.cardID) != nil {
            return
        }
        if let open = videoCards.first(where: { $0.value.id == id }), quickAccess.card(open.key) != nil { return }
        do {
            if let item = try history.item(id: id), item.kind == .video {
                showVideoCard(item, copied: false)
                return
            }
        } catch {
            log.warning("history: cannot read \(id): \(error)")
            return
        }
        _ = reopen(historyID: id, showCard: true)
    }

    func openHistoryFolder() {
        NSWorkspace.shared.open(paths.historyDirectory)
    }

    /// "Open in Annotate" from a pin or the history window: the session's record when there is
    /// one, else the item read back from history.
    func annotate(historyID id: String) {
        if let record = records.values.first(where: { $0.item?.id == id }) {
            annotate(record.cardID)
        } else if let cardID = reopen(historyID: id, showCard: false) {
            annotate(cardID)
        }
    }

    /// The session's record of a history item, else one read back from history without a card.
    func record(forHistoryID id: String) -> CaptureRecord? {
        if let record = records.values.first(where: { $0.item?.id == id }) { return record }
        return reopen(historyID: id, showCard: false).flatMap { records[$0] }
    }

    private func cardForLastCapture(showCard: Bool = true) -> String? {
        if let record = lastRecord {
            if !showCard || quickAccess.card(record.cardID) != nil { return record.cardID }
            if let id = record.item?.id { return reopen(historyID: id, showCard: true) }
            return nil
        }
        guard let newest = recentCaptures().first else { return nil }
        return reopen(historyID: newest.id, showCard: showCard)
    }

    /// Reads a history item back into a new record and, if asked, a new card.
    func reopen(historyID id: String, showCard: Bool) -> String? {
        do {
            guard let item = try history.item(id: id), item.kind == .image, item.state == .complete else { return nil }
            let original = try PNGReader.read(item.originalURL)
            let record = CaptureRecord(
                cardID: "card-" + UUID().uuidString.lowercased(), trace: nil, original: original,
                createdAt: item.createdAt, sourceApp: item.sourceApp, mode: item.mode, screenRect: item.screenRect
            )
            record.item = item
            if let edited = item.editedURL {
                record.edited = try PNGReader.read(edited)
                record.showingEdited = true
                do {
                    record.annotations = try history.annotations(id: id)
                } catch {
                    log.warning("history: cannot read the annotations of \(id): \(error)")
                }
                // An edit from before version 3 has no annotation file to rebuild it from.
                record.editsAreReproducible = record.annotations != nil
            }
            insert(record)
            if showCard {
                let image = record.current
                quickAccess.show(QuickAccessItem(
                    id: record.cardID, thumbnail: image.cgImage, pointSize: image.pointSize, copied: false
                ))
                quickAccess.card(record.cardID)?.backgroundApplied = record.backgroundApplied
            }
            return record.cardID
        } catch {
            log.warning("history: cannot reopen \(id): \(error)")
            return nil
        }
    }

    // MARK: All-in-one HUD (design 20.5)

    /// Cmd+Shift+5, "All-in-One..." or "Record Screen..." (Record mode). The overlay with the
    /// toolbar, the last area restored when the same display is present; a Record confirm hands
    /// the target to the recorder, which counts down over the same overlay.
    func openHUD(mode: HUDMode? = nil, eventTime: TimeInterval? = nil) {
        guard !coordinator.isCapturing, !overlay.isPresented, !recorder.isBusy else { return }
        if permission.hotkeyPressed() == .showHint {
            log.info("hud: no Screen Recording permission, showing the hint")
            showPermissionHint()
            onPermissionChanged?()
            return
        }
        overlay.options = OverlayController.Options(settings: settings)
        Task {
            if coordinator.displays.isEmpty {
                await refreshDisplays()
            } else {
                overlay.prepare(displays: coordinator.displays)
            }
            let displays = coordinator.displays
            guard !displays.isEmpty else { return }
            let saved = stateStore.state
            let state = AllInOneState(
                mode: mode ?? saved.hudMode, target: saved.hudTarget, lastArea: saved.lastArea, displays: displays
            )
            let run = Task { await coordinator.runHUD(state, eventTime: eventTime) }
            // The HUD is on screen after one turn; a Record HUD that cannot start says why on its chip.
            await Task.yield()
            if state.mode == .record, overlay.hud != nil, let failure = recorder.preflight() {
                overlay.setHUDNotice(failure.description)
            }
            let outcome = await run.value
            storeHUDChoice()
            switch outcome {
            case .screenshot(let ticket):
                if let cardID = cardForTrace[ObjectIdentifier(ticket.result.trace)] { records[cardID]?.stored = ticket.stored }
            case .record(let target, _):
                await recorder.record(target, displays: displays)
            case .cancelled:
                break
            }
        }
    }

    /// The HUD's mode and target for the next time (design 20.10, `state.json`).
    private func storeHUDChoice() {
        guard let hud = overlay.hud else { return }
        do {
            try stateStore.update { state in
                state.hudMode = hud.mode
                state.hudTarget = hud.target
            }
        } catch {
            log.warning("state: cannot store the HUD mode: \(error)")
        }
    }

    /// An area confirmed from Cmd+Shift+4 or the HUD (design D58).
    private func storeLastArea(_ area: LastArea) {
        do {
            try stateStore.update { $0.lastArea = area }
        } catch {
            log.warning("state: cannot store the last area: \(error)")
        }
    }

    private func hudOptionItems(_ mode: HUDMode) -> [AllInOneOptionItem] {
        AllInOneOptions.items(mode: mode, settings: settings, microphones: mode == .record ? microphoneDevices() : [])
    }

    /// A row of the HUD's Options menu: the same settings as the Settings window. Choosing a
    /// microphone is a user action that turns it on, so it may ask for access (design D65).
    private func hudOptionChosen(_ option: AllInOneOption) {
        replaceSettings(AllInOneOptions.apply(option, to: settings))
        onSettingsChanged?(settingsStore.settings)
        if case .microphone(let id?) = option, microphone.status() == .notDetermined {
            log.info("hud: microphone \(id) turned on, asking for access")
            Task { _ = await microphone.requestAccess() }
        }
    }

    /// Audio inputs for the HUD's Options menu and the Recording tab.
    func microphoneDevices() -> [MicrophoneDevice] {
        InputDevices.audioInputs().map { MicrophoneDevice(id: $0.id, name: $0.name) }
    }

    // MARK: History window (design 20.3)

    /// "Capture History..." or its shortcut: one window, activated because the user opened it.
    func openHistoryWindow() {
        let controller = historyWindow ?? makeHistoryWindow()
        historyWindow = controller
        controller.model.captureAreaShortcut = settings.shortcuts.captureArea.map { HotkeyCombo($0).displayString }
        controller.show()
    }

    private func makeHistoryWindow() -> HistoryWindowController {
        let history = history
        let model = HistoryWindowModel(
            load: { HistorySnapshot(items: try history.allItems(), totalBytes: try history.totalBytes()) },
            context: { HistoryDateContext(now: Date()) },
            actions: HistoryActions(
                showInQuickAccess: { [weak self] items in
                    // Oldest first, so the first selected ends up on top of the stack.
                    for item in items.reversed() { self?.showRecentCapture(id: item.id) }
                },
                copy: { [weak self] items in self?.copyHistoryItems(items) ?? false },
                pin: { [weak self] items in self?.pin(historyItems: items) },
                annotate: { [weak self] item in self?.annotate(historyID: item.id) },
                reveal: { items in NSWorkspace.shared.activateFileViewerSelecting(items.map(HistoryWindowModel.previewURL)) },
                trash: { [weak self] ids in self?.trashHistoryItems(ids) ?? [] },
                openFolder: { [weak self] in self?.openHistoryFolder() }
            )
        )
        return HistoryWindowController(
            model: model, frame: stateStore.state.historyWindowFrame,
            frameChanged: { [weak self] frame in self?.storeHistoryWindowFrame(frame) }
        )
    }

    private func storeHistoryWindowFrame(_ frame: CGRect) {
        do {
            try stateStore.update { $0.historyWindowFrame = frame }
        } catch {
            log.warning("state: cannot store the history window frame: \(error)")
        }
    }

    /// Cmd+C in history: one screenshot as an image, otherwise the files (a recording copies its
    /// mp4's URL, design 20.3).
    private func copyHistoryItems(_ items: [CaptureItem]) -> Bool {
        if items.count == 1, let item = items.first, item.kind == .image {
            do {
                let image = try PNGReader.read(item.currentURL)
                try ClipboardCopy.write(.image, image: image, fileURL: item.currentURL, to: clipboard)
                return true
            } catch {
                log.error("history copy \(item.id): \(error)")
                return false
            }
        }
        return copyFileURLs(items.map(HistoryWindowModel.previewURL))
    }

    /// Move to Trash and Cmd+Delete: each item folder goes to the Trash, no dialog (design D52).
    private func trashHistoryItems(_ ids: [String]) -> Set<String> {
        var trashed = Set<String>()
        for id in ids {
            do {
                if try history.trash(id: id) { trashed.insert(id) }
            } catch {
                log.error("history: cannot move \(id) to the Trash: \(error)")
            }
        }
        if !trashed.isEmpty { historyChanged() }
        return trashed
    }

    // MARK: Permission

    /// "Allow Access..." in the first-run window: the one permitted request, recorded before it
    /// is made so a crash cannot lead to a second one; afterwards only System Settings opens.
    func requestScreenRecording() {
        switch permission.requestDecision() {
        case .request:
            let now = clock.date()
            permission.recordRequest(at: now)
            do {
                try stateStore.update { $0.screenRecordingRequested = $0.screenRecordingRequested ?? now }
            } catch {
                log.error("state: cannot record the permission request: \(error)")
            }
            log.info("permission: requesting Screen Recording once")
            PermissionProbe.requestOnce()
            AppWiring.openScreenRecordingSettings()
        case .openSystemSettings:
            AppWiring.openScreenRecordingSettings()
        case .alreadyGranted:
            break
        }
        onPermissionChanged?()
    }

    /// Snap became active, or its menu or settings opened: re-read the preflight (never prompts).
    func recheckPermission() {
        let before = permission.status
        permission.appDidActivate()
        if before != .granted, permission.status == .granted {
            log.info("permission: Screen Recording granted")
            Task { await refreshDisplays() }
        }
        onPermissionChanged?()
    }

    func markOnboardingCompleted() {
        do {
            try stateStore.update { $0.onboardingCompleted = true }
        } catch {
            log.warning("state: \(error)")
        }
    }

    // MARK: Output helpers

    func copyToClipboard(_ image: CapturedImage, kind: ClipboardCopy.Kind = .image, fileURL: URL? = nil) async -> Bool {
        let clipboard = clipboard
        let log = log
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                try ClipboardCopy.write(kind, image: image, fileURL: fileURL, to: clipboard)
                return true
            } catch {
                log.error("copy: \(error)")
                return false
            }
        }.value
    }

    /// Writes `image` into `folder` with the file pattern and a collision suffix, atomically.
    nonisolated static func write(_ image: CapturedImage, toFolder folder: URL, pattern: String, date: Date, app: String?)
        throws -> URL {
        try FileNamer(pattern: pattern).write(
            PNGWriter.data(for: image.cgImage, scale: image.scale), into: folder, date: date, app: app
        )
    }

    private static func saveAs(_ image: CapturedImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = FileNamer().fileName(date: Date()) { _ in false }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AtomicFile.write(PNGWriter.data(for: image.cgImage, scale: image.scale), to: url)
        } catch {
            FileHandle.standardError.write(Data("Snap: save as failed: \(error)\n".utf8))
        }
    }

    private static func chooseImage() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path(percentEncoded: false)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openScreenRecordingSettings() {
        if let url = PermissionProbe.screenRecordingSettingsURL { NSWorkspace.shared.open(url) }
    }

    // MARK: Screens

    /// The pointer in global top-left points (the space of `DisplayInfo` and CGWindowList).
    static func globalPointer() -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CoordinateSpace(primaryHeight: primaryHeight).topLeft(fromBottomLeft: NSEvent.mouseLocation)
    }

    static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }
}
