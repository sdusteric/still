import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SnapCore
import SnapSystem
import SnapUI
import UniformTypeIdentifiers

/// The capture graph of the running app (design 5): the live ScreenCaptureKit and window sources,
/// the overlay panels, the Quick Access stack, the pasteboard writer, the stores and the editors,
/// all joined through `CaptureCoordinator`. `AppDelegate` owns one and adds the menu, settings,
/// hotkeys and onboarding. Never created by tests, tools or the shot mode.
final class AppWiring: CaptureResultPresenter {
    /// One capture as the app tracks it: the card it is on, its pixels and its history item.
    private final class CaptureRecord {
        let cardID: String
        /// Keeps the trace alive so its `ObjectIdentifier` stays unique while the record exists.
        let trace: CaptureTrace?
        let original: CapturedImage
        let createdAt: Date
        let sourceApp: String?
        var item: CaptureItem?
        var stored: Task<StoredCapture?, Never>?
        /// The Background or editor render, once made.
        var edited: CapturedImage?
        var showingEdited = false

        init(cardID: String, trace: CaptureTrace?, original: CapturedImage, createdAt: Date, sourceApp: String?) {
            self.cardID = cardID
            self.trace = trace
            self.original = original
            self.createdAt = createdAt
            self.sourceApp = sourceApp
        }

        var current: CapturedImage { showingEdited ? (edited ?? original) : original }

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
    private let clock = SystemClock()
    private let captureSource: LiveCaptureSource
    private let windowSource = LiveWindowSource()
    private let clipboard = PasteboardWriter()
    let overlay: OverlayController
    let quickAccess: QuickAccessController
    let hint: PermissionHintController
    private(set) var permission: PermissionState

    private lazy var coordinator = CaptureCoordinator(
        captureSource: captureSource,
        windowSource: windowSource,
        overlay: overlay,
        results: self,
        output: CaptureOutputStage(history: history, clipboard: clipboard, clock: clock, log: log),
        clock: clock,
        log: log,
        configuration: { [weak self] in self?.captureConfiguration() ?? CaptureConfiguration() }
    )

    private var records: [String: CaptureRecord] = [:]
    private var recordOrder: [String] = []
    private var cardForTrace: [ObjectIdentifier: String] = [:]
    private var backgroundPanels: [ObjectIdentifier: BackgroundEditorPanel] = [:]
    private var annotateWindows: [ObjectIdentifier: AnnotateWindowController] = [:]
    private var menuThumbnails: [String: CGImage] = [:]

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
            preflight: PermissionProbe.preflightCheck,
            requestedAt: stateStore.state.screenRecordingRequested
        )
        quickAccess.actions = makeQuickAccessActions()
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

    /// Sweeps old history and, when permission is already granted, builds the overlay panels.
    /// Without permission nothing touches ScreenCaptureKit, so launch never prompts.
    func start() {
        log.info("launch: SNAP_HOME \(paths.home.path(percentEncoded: false)), permission \(permission.status)")
        sweepHistory()
        if permission.status == .granted {
            Task { await refreshDisplays() }
        }
    }

    func stop() {
        quickAccess.closeAll()
        log.info("quit")
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
        coordinator.cancel()
        guard permission.status == .granted else { return }
        Task {
            await captureSource.invalidate()
            await refreshDisplays()
        }
    }

    func sweepHistory() {
        let history = history
        let log = log
        Task.detached(priority: .utility) {
            do {
                let removed = try history.sweep()
                if !removed.isEmpty { log.info("history: swept \(removed.count) items") }
            } catch {
                log.warning("history: sweep failed: \(error)")
            }
        }
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
        overlay.options = OverlayController.Options(settings: stored.capture)
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
        overlay.options = OverlayController.Options(settings: settings.capture)
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
        menuThumbnails[stored.item.id] = nil

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

    private func addRecord(for result: CaptureResult) -> CaptureRecord {
        let record = CaptureRecord(
            cardID: "card-" + UUID().uuidString.lowercased(), trace: result.trace, original: result.image,
            createdAt: result.createdAt, sourceApp: result.sourceApp
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
            copy: { [weak self] id in await self?.copyCard(id) ?? false },
            save: { [weak self] id in await self?.saveCard(id) },
            toggleBackground: { [weak self] id in await self?.toggleBackground(id) },
            openBackgroundEditor: { [weak self] id in self?.openBackgroundEditor(cardID: id) },
            annotate: { [weak self] id in self?.annotate(id) },
            reveal: { url in AppWiring.reveal(url) },
            dragURL: { [weak self] id in self?.records[id]?.currentURL },
            closed: { [weak self] id, reason in self?.log.info("card \(id) closed: \(reason)") }
        )
    }

    private func copyCard(_ id: String) async -> Bool {
        guard let record = records[id] else { return false }
        return await copyToClipboard(record.current)
    }

    private func saveCard(_ id: String) async -> URL? {
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

    /// One click on Background: renders the default preset, or restores the original when it is
    /// applied (design 10.4).
    private func toggleBackground(_ id: String) async -> QuickAccessThumbnail? {
        guard let record = records[id] else { return nil }
        if record.showingEdited {
            record.showingEdited = false
            return QuickAccessThumbnail(
                image: record.original.cgImage, pointSize: record.original.pointSize, backgroundApplied: false
            )
        }
        if record.edited == nil {
            let source = record.original
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
            record.edited = rendered
            await storeEdited(rendered, for: record)
        }
        guard let edited = record.edited else { return nil }
        record.showingEdited = true
        return QuickAccessThumbnail(image: edited.cgImage, pointSize: edited.pointSize, backgroundApplied: true)
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
        let updated = await Task.detached(priority: .userInitiated) { () -> CaptureItem? in
            do {
                return try history.saveEdited(id: id, pngData: PNGWriter.data(for: image.cgImage, scale: image.scale))
            } catch {
                log.error("history: edited write for \(id) failed: \(error)")
                return nil
            }
        }.value
        if let updated { record.item = updated }
    }

    // MARK: Editors

    func openBackgroundEditor(cardID: String) {
        guard let record = records[cardID] else { return }
        openBackgroundEditor(source: record.original, record: record, preset: defaultPreset)
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
            copy: { [weak self] output, _ in self?.editorRendered(output, record: record, copy: true) },
            save: { [weak self] output, _ in self?.editorRendered(output, record: record, copy: false) },
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
        panel.onClose = { [weak self] in self?.backgroundPanels[key] = nil }
        panel.present()
    }

    private func withPresets(_ body: (PresetStore) throws -> Void) {
        do {
            try body(presetStore)
        } catch {
            log.error("presets: \(error)")
        }
    }

    /// Copy or Save in the Background editor: the render becomes the card's edited image.
    private func editorRendered(_ output: BeautifyRenderer.Output, record: CaptureRecord?, copy: Bool) {
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
            record.edited = image
            record.showingEdited = true
            quickAccess.updateThumbnail(
                record.cardID, with: QuickAccessThumbnail(image: image.cgImage, pointSize: image.pointSize, backgroundApplied: true)
            )
            await storeEdited(image, for: record)
        }
    }

    func annotate(_ cardID: String) {
        guard let record = records[cardID] else { return }
        let image = record.current
        let document = AnnotationDocument(image: image.cgImage, scale: image.scale)
        let actions = AnnotateActions(
            copy: { [weak self] flattened, scale in
                self?.annotateExported(CapturedImage(cgImage: flattened, scale: scale), record: record, copy: true)
            },
            save: { [weak self] flattened, scale in
                self?.annotateSaved(CapturedImage(cgImage: flattened, scale: scale), record: record)
            },
            saveAs: { flattened, scale in AppWiring.saveAs(CapturedImage(cgImage: flattened, scale: scale)) },
            background: { [weak self] flattened, scale in
                guard let self else { return }
                openBackgroundEditor(
                    source: CapturedImage(cgImage: flattened, scale: scale), record: record, preset: defaultPreset
                )
            },
            reveal: { url in AppWiring.reveal(url) },
            saveFolderName: paths.saveFolder(for: settings).lastPathComponent
        )
        let controller = AnnotateWindowController(document: document, actions: actions)
        let key = ObjectIdentifier(controller)
        annotateWindows[key] = controller
        controller.onClose = { [weak self] in self?.annotateWindows[key] = nil }
        controller.present()
    }

    private func annotateExported(_ image: CapturedImage, record: CaptureRecord, copy: Bool) {
        Task {
            if copy { _ = await copyToClipboard(image) }
            await storeEdited(image, for: record)
        }
    }

    private func annotateSaved(_ image: CapturedImage, record: CaptureRecord) -> URL? {
        do {
            let url = try AppWiring.write(
                image, toFolder: paths.saveFolder(for: settings), pattern: settings.general.fileNamePattern,
                date: record.createdAt, app: record.sourceApp
            )
            annotateExported(image, record: record, copy: false)
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

    /// A small thumbnail of a history item for the menu, read once and cached.
    func menuThumbnail(for id: String) -> CGImage? {
        if let cached = menuThumbnails[id] { return cached }
        let url: URL?
        do {
            url = try history.item(id: id)?.currentURL
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

    private var lastRecord: CaptureRecord? {
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

    /// A Recent Captures entry: its card again.
    func showRecentCapture(id: String) {
        if let record = records.values.first(where: { $0.item?.id == id }), quickAccess.card(record.cardID) != nil {
            return
        }
        _ = reopen(historyID: id, showCard: true)
    }

    func openHistoryFolder() {
        NSWorkspace.shared.open(paths.historyDirectory)
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
    private func reopen(historyID id: String, showCard: Bool) -> String? {
        do {
            guard let item = try history.item(id: id) else { return nil }
            let original = try PNGReader.read(item.originalURL)
            let record = CaptureRecord(
                cardID: "card-" + UUID().uuidString.lowercased(), trace: nil, original: original,
                createdAt: item.createdAt, sourceApp: item.sourceApp
            )
            record.item = item
            if let edited = item.editedURL {
                record.edited = try PNGReader.read(edited)
                record.showingEdited = true
            }
            insert(record)
            if showCard {
                let image = record.current
                quickAccess.show(QuickAccessItem(
                    id: record.cardID, thumbnail: image.cgImage, pointSize: image.pointSize, copied: false
                ))
                quickAccess.card(record.cardID)?.backgroundApplied = record.showingEdited
            }
            return record.cardID
        } catch {
            log.warning("history: cannot reopen \(id): \(error)")
            return nil
        }
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

    private func copyToClipboard(_ image: CapturedImage) async -> Bool {
        let clipboard = clipboard
        let log = log
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                let png = try PNGWriter.data(for: image.cgImage, scale: image.scale)
                try clipboard.writeImage(pngData: png, image: image.cgImage, scale: image.scale)
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNamer(pattern: pattern).fileName(in: folder, date: date, app: app)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try AtomicFile.write(PNGWriter.data(for: image.cgImage, scale: image.scale), to: url)
        return url
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
