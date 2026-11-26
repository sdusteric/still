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
        /// The history write failed: no item will come, so the record may be dropped once its card closes.
        var storeFailed = false

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
    /// Records keep full-size images (a 5K fullscreen is about 58 MB), so only a few with closed
    /// cards stay; an older capture is read back from its history file when asked for.
    private static let recordLimit = 4
    /// Recent capture thumbnails in the menu are drawn from images at most this many pixels wide.
    nonisolated static let menuThumbnailPixels = 64

    let paths: SnapPaths
    let log: Log
    private let shelfStatus: ShelfStatusWriter
    private let shelfQueue = DispatchQueue(label: "dev.sdusteric.snap.shelf-status", qos: .utility)
    let settingsStore: SettingsStore
    let stateStore: StateStore
    let presetStore: PresetStore
    let history: HistoryStore
    /// Reads screenshots for Shelf search (Recall design 7).
    let recall: RecallIndexer
    private var recallPending = 0
    private var lastStatusWrite = Date.distantPast
    private var statusWriteScheduled = false
    let clock = SystemClock()
    let captureSource: LiveCaptureSource
    private let windowSource = LiveWindowSource()
    let clipboard = PasteboardWriter()
    let textRecognizer = VisionTextRecognizer()
    let textIndex = CaptureTextIndex()
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
    var recordOrder: [String] = []
    var cardForTrace: [ObjectIdentifier: String] = [:]
    private var backgroundPanels: [ObjectIdentifier: BackgroundEditorPanel] = [:]
    private var annotateWindows: [ObjectIdentifier: AnnotateWindowController] = [:]
    /// History ids an open Background editor or annotate window works on, for the sweep.
    private var editorItems: [ObjectIdentifier: String] = [:]
    var menuThumbnails: [String: CGImage] = [:]
    /// Scrolling capture while it runs (ScrollWiring.swift).
    var scrollSession: ScrollCaptureSession?
    let scrollOutline = RecordingOutlinePanel()
    let scrollBar = ScrollCaptureBarPanel()
    /// Takes keys as global hotkeys until `releaseKeys`; set by the app delegate, which owns them.
    var grabKeys: (@MainActor ([KeyShortcut], @escaping @MainActor (Int, Bool) -> Void) -> Void)?
    var releaseKeys: (@MainActor () -> Void)?
    var menuThumbnailTask: Task<Void, Never>?
    /// Video cards by card id (design 20.6, D67): the recording each one shows.
    var videoCards: [String: CaptureItem] = [:]
    var historyWindow: HistoryWindowController?

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
        recall = RecallIndexer(
            history: history, ocr: OCRStore(history: history), recognizer: VisionTextRecognizer(),
            writer: RecallWriter(directory: paths.recallDirectory), options: RecallOptions(settingsStore.settings.general), log: log
        )
        shelfStatus = ShelfStatusWriter(
            directory: paths.shelfStatusDirectory,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        captureSource = LiveCaptureSource(log: log)

        let settings = settingsStore.settings
        overlay = OverlayController(
            options: OverlayController.Options(settings: settings.capture),
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
        publishShelfStatus()
        let (counts, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { [recall] in await recall.setOnPendingChange { continuation.yield($0) } }
        Task { [weak self] in
            for await count in counts { self?.recallPendingChanged(count) }
        }
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
            // The overlay panels exist now; list them so the first capture needs no extra fetch.
            await captureSource.refreshContent()
        } catch {
            log.warning("displays: \(error)")
        }
    }

    func screenParametersChanged() {
        pins.displaysChanged()
        coordinator.cancel()
        // The area's coordinates no longer hold after a display change.
        cancelScrollSession()
        if case .countdown = recorder.controller.state { recorder.cancel() }
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
        let imageRetention = settings.general.screenshotRetention.interval
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
                    let removed = try history.sweep(skipping: inUse, imageRetention: imageRetention)
                    if !removed.isEmpty { log.info("history: swept \(removed.count) items, skipped \(inUse.count) in use") }
                    return removed
                } catch {
                    log.warning("history: sweep failed: \(error)")
                    return []
                }
            }.value
            if !removed.isEmpty || markInterruptedFirst { historyChanged() }
            await recall.remove(removed)
            // At launch, after the sweep: repair the recall folder both ways.
            if markInterruptedFirst { await recall.reconcile() }
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
        refreshMenuThumbnails()
        // A trash, sweep, finished recording or edit changes what Shelf shows, not only a capture.
        publishShelfStatus()
        NotificationCenter.default.post(name: HistoryWindowController.historyDidChange, object: nil)
    }

    /// Writes the Shelf status file for the newest 3 complete captures, off the main thread.
    func publishShelfStatus() {
        let captures: [ShelfCapture]
        do {
            captures = try history.recent(limit: 12).lazy
                .filter { $0.state == .complete }
                .compactMap { item in item.thumbnailURL.map { ShelfCapture(takenAt: item.createdAt, imageURL: $0) } }
                .prefix(ShelfStatusWriter.maxCaptures).map { $0 }
        } catch {
            log.warning("shelf: cannot read history: \(error)")
            return
        }
        let writer = shelfStatus
        let showPreviews = settings.general.showInShelf
        let recallStatus = RecallStatus(enabled: settings.general.searchInShelf, pending: recallPending)
        let log = log
        lastStatusWrite = Date()
        shelfQueue.async {
            do {
                try writer.write(captures: captures, showPreviews: showPreviews, recall: recallStatus)
            } catch {
                log.warning("shelf: status write failed: \(error)")
            }
        }
    }

    /// The OCR queue changed size: tell Shelf, at most once a second.
    private func recallPendingChanged(_ count: Int) {
        // OCR writes ocr.json inside an item folder, which neither the folder date nor a capture
        // event reports: when the queue empties, History reads the new text for its search.
        if count == 0, recallPending > 0 {
            NotificationCenter.default.post(name: HistoryWindowController.historyDidChange, object: nil)
        }
        recallPending = count
        let wait = 1 - Date().timeIntervalSince(lastStatusWrite)
        guard wait > 0 else { return publishShelfStatus() }
        guard !statusWriteScheduled else { return }
        statusWriteScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.statusWriteScheduled = false
            self?.publishShelfStatus()
        }
    }

    // MARK: Settings

    var settings: SnapCore.Settings { settingsStore.settings }

    /// Stores new settings and applies them to the overlay and the Quick Access stack.
    func replaceSettings(_ new: SnapCore.Settings) {
        guard new != settingsStore.settings else { return }
        let old = settingsStore.settings.general
        let shelfChanged = new.general.showInShelf != old.showInShelf || new.general.searchInShelf != old.searchInShelf
        defer { if shelfChanged { publishShelfStatus() } }
        let recallOptions = RecallOptions(new.general)
        if recallOptions != RecallOptions(old) {
            Task { [recall] in await recall.update(options: recallOptions) }
        }
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
        // The overlay is also up for the record countdown, which a capture would reset.
        guard !coordinator.isCapturing, !overlay.isPresented, scrollSession == nil, permissionAllowsCapture(mode.rawValue) else { return }
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

    /// A capture or a recording got frames: any permission lapse is over (menu line and badge).
    func permissionWorked() {
        let wasLapsed = permission.status != .granted
        permission.captureSucceeded()
        if wasLapsed { onPermissionChanged?() }
    }

    /// False, after showing the hint, when Screen Recording permission is missing. Never requests it.
    func permissionAllowsCapture(_ what: String) -> Bool {
        guard permission.hotkeyPressed() == .showHint else { return true }
        log.info("capture \(what): no Screen Recording permission, showing the hint")
        showPermissionHint()
        onPermissionChanged?()
        return false
    }

    func showPermissionHint() {
        guard let screen = AppWiring.screenUnderPointer() else { return }
        hint.show(near: NSEvent.mouseLocation, visibleFrame: screen.visibleFrame, reapproval: permission.needsReapproval)
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
        publishShelfStatus()
        let id = stored.item.id
        Task { [recall] in await recall.enqueue(id) }

        if settings.capture.copyToClipboard, !stored.copied { quickAccess.markNotCopied(record.cardID) }

        permissionWorked()
        countCapture(stored.item.id)
        playShutterIfEnabled()
        if settings.capture.openInAnnotate { annotate(record.cardID) }
    }

    func captureFailed(_ failure: CaptureFailure) {
        log.warning("capture \(failure.mode.rawValue) failed at \(failure.stage.rawValue): \(failure.message)")
        if failure.stage == .output, let traceID = failure.traceID, let cardID = cardForTrace[traceID] {
            // The card is already up; say what did not happen instead of failing quietly.
            records[cardID]?.storeFailed = true
            let copyMissing = settings.capture.copyToClipboard && !failure.copied
            if copyMissing { quickAccess.markNotCopied(cardID) }
            quickAccess.showNote(copyMissing ? "Not saved or copied" : "Not saved to History", on: cardID)
            trimRecords()
        }
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

    func insert(_ record: CaptureRecord) {
        records[record.cardID] = record
        recordOrder.append(record.cardID)
        trimRecords()
    }

    /// Drops the records of captures that left history, closing their cards, so "Last Capture"
    /// and an open card never act on a file that is gone.
    func forgetRecords(ofItems ids: Set<String>) {
        for (cardID, record) in records where record.item.map({ ids.contains($0.id) }) == true {
            quickAccess.close(cardID, reason: .trashed)
            if let trace = record.trace { cardForTrace[ObjectIdentifier(trace)] = nil }
            records[cardID] = nil
            recordOrder.removeAll { $0 == cardID }
        }
    }

    /// Move to Trash on a card: waits for the capture to be stored, then moves its history folder
    /// to the Trash, the same way History does, and forgets the record.
    private func trashCard(_ cardID: String) async -> Bool {
        var itemID = videoCards[cardID]?.id ?? records[cardID]?.item?.id
        if itemID == nil { itemID = await records[cardID]?.stored?.value?.item.id }
        guard let itemID, trashHistoryItems([itemID]).contains(itemID) else {
            log.warning("card \(cardID): could not move its capture to the Trash")
            return false
        }
        if let trace = records[cardID]?.trace { cardForTrace[ObjectIdentifier(trace)] = nil }
        records[cardID] = nil
        recordOrder.removeAll { $0 == cardID }
        return true
    }

    /// Drops the oldest records whose cards are closed and whose files are stored; their files
    /// stay in history. An open editor keeps its own reference to its record.
    private func trimRecords() {
        while recordOrder.count > Self.recordLimit,
              let index = recordOrder.firstIndex(where: { id in
                  quickAccess.card(id) == nil && (records[id].map { $0.item != nil || $0.storeFailed } ?? true)
              }) {
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
            copyText: { [weak self] id in await self?.copyCardText(id) ?? .failed },
            trash: { [weak self] id in await self?.trashCard(id) ?? false },
            closed: { [weak self] id, reason in
                self?.videoCards[id] = nil
                self?.trimRecords()
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
                // An edit from before version 3 may have annotations burned into its PNG with no
                // file to rebuild them from; that one stays in history.
                if record.editsAreReproducible {
                    record.edited = nil
                    record.annotations = nil
                    await storeUnedited(record)
                }
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
    /// History goes back to the original: the edited PNG and its annotation file are removed.
    private func storeUnedited(_ record: CaptureRecord) async {
        var item = record.item
        if item == nil { item = await record.stored?.value?.item }
        guard let id = item?.id else { return }
        let history = history
        let log = log
        let updated = await Task.detached(priority: .userInitiated) { () -> CaptureItem? in
            do {
                return try history.discardEdit(id: id)
            } catch {
                log.error("history: removing the edit of \(id) failed: \(error)")
                return nil
            }
        }.value
        if let updated {
            record.item = updated
            historyChanged()
            Task { [recall] in await recall.enqueue(id, force: true) }
        }
    }

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
            Task { [recall] in await recall.enqueue(id, force: true) }
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
            // The last capture is only a preview here: Copy or Save must not rewrite its history file.
            openBackgroundEditor(source: record.original, record: nil, preset: preset)
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
                let annotated = CapturedImage(cgImage: flattened, scale: scale)
                AppWiring.saveAs(self?.withBackground(annotated, record: record) ?? annotated)
                // As Save does: the card and history get the annotated version too.
                self?.annotateExported(annotated, record: record, copy: false)
            },
            background: { [weak self] flattened, scale in
                guard let self else { return }
                // The annotations are kept first, so a canceled Background editor loses nothing.
                annotateExported(CapturedImage(cgImage: flattened, scale: scale), record: record, copy: false)
                openBackgroundEditor(
                    source: CapturedImage(cgImage: flattened, scale: scale), record: record,
                    preset: record.annotations?.background ?? defaultPreset
                )
            },
            reveal: { url in AppWiring.reveal(url) },
            saveFolderName: paths.saveFolder(for: settings).lastPathComponent,
            settings: settings.annotate,
            settingsChanged: { [weak self] annotate in
                guard let self else { return }
                var updated = settings
                updated.annotate = annotate
                replaceSettings(updated)
            },
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

    // MARK: All-in-one HUD (design 20.5)

    /// Cmd+Shift+5, "All-in-One..." or "Record Screen..." (Record mode). The overlay with the
    /// toolbar, the last area restored when the same display is present; a Record confirm hands
    /// the target to the recorder, which counts down over the same overlay.
    func openHUD(mode: HUDMode? = nil, eventTime: TimeInterval? = nil) {
        guard !coordinator.isCapturing, !overlay.isPresented, !recorder.isBusy, scrollSession == nil else { return }
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

    static func chooseImage() -> String? {
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
