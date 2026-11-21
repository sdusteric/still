import CoreGraphics
import Foundation

/// Puts a capture on the pasteboard (design section 9). Live: `PasteboardWriter` in SnapSystem.
/// Tests and `snapctl` use a recording fake. Called on the background output stage.
public protocol ClipboardWriting: Sendable {
    /// Writes `pngData` at once; richer types (TIFF) may be supplied lazily from `image`.
    func writeImage(pngData: Data, image: CGImage, scale: Double) throws
    /// "Copy file": writes the file URL instead of the image.
    func writeFileURL(_ url: URL) throws
    /// "Copy Text": plain text only.
    func writeText(_ text: String) throws
}

public struct ClipboardTextUnsupported: Error {}

extension ClipboardWriting {
    /// Fakes that never copy text need not implement it.
    public func writeText(_ text: String) throws { throw ClipboardTextUnsupported() }
}

/// What the coordinator reports after the overlay is gone. Live: the Quick Access controller in
/// SnapUI, wired by the app (`snapbench latency` uses it too). Fake: a recording presenter in tests.
@MainActor
public protocol CaptureResultPresenter: AnyObject {
    /// Shows the Quick Access card. Called before the image is encoded, stored or copied.
    func showCard(for capture: CaptureResult)
    /// The background stage finished: the history item exists and the clipboard holds the image.
    func captureStored(_ stored: StoredCapture)
    /// A capture or its output stage failed. The overlay is already dismissed.
    func captureFailed(_ failure: CaptureFailure)
}

/// The settings one capture runs with, read at the moment of the hotkey.
public struct CaptureConfiguration: Sendable, Hashable {
    public var options: CaptureOptions
    public var showQuickAccess: Bool
    public var copyToClipboard: Bool
    /// Folder for the optional "Save to folder" action; nil leaves the capture in history only.
    public var saveFolder: URL?
    public var fileNamePattern: String
    /// Snap's overlay panels. The coordinator adds them to `options.excludedWindowIDs` only for a
    /// capture that orders them front: a fullscreen capture never shows them, so they are not on
    /// screen, and listing them would make the live source fall back to excluding all of Snap,
    /// which leaves the desktop icons in.
    public var overlayWindowIDs: [WindowID]

    public init(
        options: CaptureOptions = CaptureOptions(),
        showQuickAccess: Bool = true,
        copyToClipboard: Bool = true,
        saveFolder: URL? = nil,
        fileNamePattern: String = FileNamer.defaultPattern,
        overlayWindowIDs: [WindowID] = []
    ) {
        self.options = options
        self.showQuickAccess = showQuickAccess
        self.copyToClipboard = copyToClipboard
        self.saveFolder = saveFolder
        self.fileNamePattern = fileNamePattern
        self.overlayWindowIDs = overlayWindowIDs
    }

    /// From the stored settings.
    /// - Parameters:
    ///   - overlayWindowIDs: Snap's overlay panels, excluded only when the overlay is shown.
    ///   - excludedWindowIDs: Snap's other panels that are on screen now (the Quick Access
    ///     stack, the permission hint), excluded from every display capture.
    public init(
        settings: Settings, paths: SnapPaths, overlayWindowIDs: [WindowID] = [], excludedWindowIDs: [WindowID] = []
    ) {
        self.init(
            options: CaptureOptions(
                hideDesktopIcons: settings.capture.hideDesktopIcons,
                includeWindowShadow: settings.capture.includeWindowShadow,
                excludedWindowIDs: excludedWindowIDs
            ),
            showQuickAccess: settings.capture.showQuickAccess,
            copyToClipboard: settings.capture.copyToClipboard,
            saveFolder: settings.capture.saveToFolder ? paths.saveFolder(for: settings) : nil,
            fileNamePattern: settings.general.fileNamePattern,
            overlayWindowIDs: overlayWindowIDs
        )
    }

    /// The options for one capture: the overlay panels are excluded only when they are shown.
    public func captureOptions(overlayShown: Bool) -> CaptureOptions {
        var options = options
        if overlayShown {
            for id in overlayWindowIDs where !options.excludedWindowIDs.contains(id) {
                options.excludedWindowIDs.append(id)
            }
        }
        return options
    }
}

/// What one all-in-one HUD session ended with (design 20.5).
public enum HUDCaptureOutcome: Sendable {
    /// Screenshot mode: the card is shown and the background stage runs, as for Cmd+Shift+4.
    case screenshot(CaptureTicket)
    /// Record mode: what to record. The overlay is still up so it can show the countdown; the
    /// caller hands the target to the recording controller and dismisses the overlay.
    case record(RecordingTarget, trace: CaptureTrace)
    case cancelled

    public var ticket: CaptureTicket? {
        if case .screenshot(let ticket) = self { return ticket }
        return nil
    }
}

/// A finished capture, before it is encoded or stored.
public struct CaptureResult: Sendable {
    public var mode: CaptureMode
    /// The cropped area, the window or the whole display, at its native scale.
    public var image: CapturedImage
    public var createdAt: Date
    /// What was captured in global top-left points: the selection, the window frame or the display.
    public var rect: CGRect
    /// Owner of the captured window, when known.
    public var sourceApp: String?
    public var trace: CaptureTrace

    public init(
        mode: CaptureMode,
        image: CapturedImage,
        createdAt: Date,
        rect: CGRect,
        sourceApp: String? = nil,
        trace: CaptureTrace
    ) {
        self.mode = mode
        self.image = image
        self.createdAt = createdAt
        self.rect = rect
        self.sourceApp = sourceApp
        self.trace = trace
    }
}

/// A capture after the background stage: in history, maybe on the pasteboard and in the save folder.
public struct StoredCapture: Sendable {
    public var result: CaptureResult
    public var item: CaptureItem
    public var copied: Bool
    public var savedURL: URL?
    /// Why the clipboard or save step failed; the history copy exists regardless.
    public var problems: [String]

    public init(result: CaptureResult, item: CaptureItem, copied: Bool, savedURL: URL?, problems: [String] = []) {
        self.result = result
        self.item = item
        self.copied = copied
        self.savedURL = savedURL
        self.problems = problems
    }
}

/// A failed capture, for the log and the permission hint.
public struct CaptureFailure: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable {
        /// Screen or window capture, before any card was shown.
        case capture
        /// Encoding or the history write, after the card was shown.
        case output
    }

    public var mode: CaptureMode
    public var stage: Stage
    /// Set when the capture source failed; nil for an output error.
    public var captureError: CaptureError?
    public var message: String
    /// The capture's trace for an output failure, so the app finds the card it already showed.
    public var traceID: ObjectIdentifier?
    /// An output failure after which the clipboard still got the image.
    public var copied: Bool

    public init(
        mode: CaptureMode, stage: Stage, captureError: CaptureError?, message: String,
        traceID: ObjectIdentifier? = nil, copied: Bool = false
    ) {
        self.mode = mode
        self.stage = stage
        self.captureError = captureError
        self.message = message
        self.traceID = traceID
        self.copied = copied
    }

    /// True for a missing or lapsed Screen Recording grant, which shows the hint panel.
    public var isPermissionError: Bool { captureError == .permissionDenied }
}

/// The handle `confirm` returns: the result shown on the card and the background stage.
public struct CaptureTicket: Sendable {
    public var result: CaptureResult
    /// Resolves after `captureStored` or `captureFailed` was called; nil when the stage failed.
    public var stored: Task<StoredCapture?, Never>
}

extension CaptureError {
    /// The source's cached shareable content no longer matches the screen (a display or window
    /// it does not know). The coordinator refetches once and retries (design 6.2).
    public var isStaleContent: Bool {
        switch self {
        case .displayNotFound, .windowNotFound: true
        case .permissionDenied, .failed: false
        }
    }
}

/// PNG encode, history write, clipboard and the optional save, in that order, off the main
/// actor and always after the card is shown (design 6.6).
public struct CaptureOutputStage: Sendable {
    public let history: HistoryStore
    public let clipboard: (any ClipboardWriting)?
    public let clock: any Clock
    public let log: Log?

    public init(history: HistoryStore, clipboard: (any ClipboardWriting)?, clock: any Clock = SystemClock(), log: Log? = nil) {
        self.history = history
        self.clipboard = clipboard
        self.clock = clock
        self.log = log
    }

    public func run(_ result: CaptureResult, configuration: CaptureConfiguration) throws -> StoredCapture {
        let trace = result.trace
        let png = try PNGWriter.data(for: result.image.cgImage, scale: result.image.scale)
        trace.record(.encode, at: clock.now())

        let namer = FileNamer(pattern: configuration.fileNamePattern)
        // Each item has its own history folder, so the plain name never collides there.
        let fileName = namer.fileName(date: result.createdAt, app: result.sourceApp) { _ in false }
        let item: CaptureItem
        do {
            item = try history.add(
                pngData: png, fileName: fileName, mode: result.mode, scale: result.image.scale,
                sourceApp: result.sourceApp, createdAt: result.createdAt,
                // Area and window captures keep their rect, so a pin opened later from history lands
                // on top of what it shows (design 20.4, D47); fullscreen has none.
                screenRect: result.mode == .fullscreen ? nil : result.rect,
                pixelSize: PixelSize(width: result.image.cgImage.width, height: result.image.cgImage.height)
            )
        } catch {
            // A full disk or a missing folder must not also lose the clipboard and the saved copy.
            let (copied, savedURL, problems) = deliverCopies(png, result: result, configuration: configuration, namer: namer)
            for problem in problems { log?.warning("capture: \(problem)") }
            throw CaptureOutputError.historyFailed(String(describing: error), copied: copied, savedURL: savedURL)
        }
        trace.record(.history, at: clock.now())

        let (copied, savedURL, problems) = deliverCopies(png, result: result, configuration: configuration, namer: namer)
        for problem in problems { log?.warning("capture \(item.id): \(problem)") }
        log?.info(LatencyLog.line(for: trace))
        return StoredCapture(result: result, item: item, copied: copied, savedURL: savedURL, problems: problems)
    }

    /// The clipboard copy and the save-folder copy, each on its own so one failing keeps the other.
    private func deliverCopies(
        _ png: Data, result: CaptureResult, configuration: CaptureConfiguration, namer: FileNamer
    ) -> (copied: Bool, savedURL: URL?, problems: [String]) {
        let trace = result.trace
        var problems: [String] = []
        var copied = false
        if configuration.copyToClipboard, let clipboard {
            do {
                try clipboard.writeImage(pngData: png, image: result.image.cgImage, scale: result.image.scale)
                copied = true
                trace.record(.clipboard, at: clock.now())
            } catch {
                problems.append("clipboard: \(error)")
            }
        }

        var savedURL: URL?
        if let folder = configuration.saveFolder {
            do {
                savedURL = try namer.write(png, into: folder, date: result.createdAt, app: result.sourceApp)
                trace.record(.save, at: clock.now())
            } catch {
                problems.append("save: \(error)")
            }
        }
        return (copied, savedURL, problems)
    }
}

/// The history write failed after the card was shown. The clipboard and save copies still ran.
public enum CaptureOutputError: Error, CustomStringConvertible {
    case historyFailed(String, copied: Bool, savedURL: URL?)

    public var description: String {
        switch self {
        case .historyFailed(let message, _, _): "history: \(message)"
        }
    }

    public var copied: Bool {
        switch self {
        case .historyFailed(_, let copied, _): copied
        }
    }
}

/// Runs one capture from hotkey to card (design 5 and 6.2): the overlay first, then every display
/// captured in parallel with the window list, the frozen images handed to the panels as they
/// arrive, the crop or the live window capture on confirm, the card, and only then the
/// background output stage. Knows the screen, the panels and the pasteboard only through protocols.
@MainActor
public final class CaptureCoordinator {
    private final class Session {
        let mode: CaptureMode
        let trace: CaptureTrace
        let displays: [DisplayInfo]
        let configuration: CaptureConfiguration
        let presented: Bool
        /// An all-in-one HUD session: the result mode follows the selection, not the hotkey.
        let hud: Bool
        var frozen: [DisplayID: Task<CapturedImage, any Error>] = [:]
        var pendingFrozen = 0
        var windows: [WindowInfo] = []
        var windowTask: Task<Void, Never>?
        var finished = false

        init(
            mode: CaptureMode, trace: CaptureTrace, displays: [DisplayInfo], configuration: CaptureConfiguration,
            presented: Bool, hud: Bool = false
        ) {
            self.mode = mode
            self.trace = trace
            self.displays = displays
            self.configuration = configuration
            self.presented = presented
            self.hud = hud
        }
    }

    private let captureSource: any CaptureSource
    private let windowSource: any WindowSource
    private let overlay: any OverlayPresenter
    private let results: any CaptureResultPresenter
    private let output: CaptureOutputStage
    private let clock: any Clock
    private let log: Log?
    private let configuration: @MainActor () -> CaptureConfiguration
    private var session: Session?

    /// The display list `present` uses. Refreshed at launch, on screen changes and on a stale retry.
    public private(set) var displays: [DisplayInfo] = []
    /// The trace of the most recent capture, for tests and the latency tool.
    public private(set) var lastTrace: CaptureTrace?
    /// Called when an area is confirmed from Cmd+Shift+4 or the HUD (a screenshot or a recording),
    /// so the app stores it in `state.json` for the next HUD (design D58).
    public var onAreaConfirmed: ((LastArea) -> Void)?

    public init(
        captureSource: any CaptureSource,
        windowSource: any WindowSource,
        overlay: any OverlayPresenter,
        results: any CaptureResultPresenter,
        output: CaptureOutputStage,
        clock: any Clock = SystemClock(),
        log: Log? = nil,
        configuration: @escaping @MainActor () -> CaptureConfiguration = { CaptureConfiguration() }
    ) {
        self.captureSource = captureSource
        self.windowSource = windowSource
        self.overlay = overlay
        self.results = results
        self.output = output
        self.clock = clock
        self.log = log
        self.configuration = configuration
    }

    /// True while an overlay or a capture is in progress; a second hotkey is ignored then.
    public var isCapturing: Bool { session != nil }

    /// Refetches the display list from the source (the live source refetches its shareable content).
    @discardableResult
    public func refreshDisplays() async throws -> [DisplayInfo] {
        let fresh = try await captureSource.displays()
        displays = fresh
        return fresh
    }

    // MARK: Whole capture

    /// Begins a capture, waits for the overlay's selection and confirms it. Fullscreen skips the
    /// overlay and captures the display under `pointer`. Nil when cancelled, failed or busy.
    /// - Parameters:
    ///   - eventTime: the hotkey event time on this coordinator's clock; nil means now.
    ///   - pointer: the mouse location in global top-left points, for fullscreen.
    @discardableResult
    public func run(mode: CaptureMode, eventTime: TimeInterval? = nil, pointer: CGPoint? = nil) async -> CaptureTicket? {
        guard await begin(mode: mode, eventTime: eventTime, pointer: pointer), let session else { return nil }
        if mode == .fullscreen {
            return await finishFullscreen(session)
        }
        let selection = await overlay.selection()
        guard self.session === session else { return nil }
        return await confirm(selection)
    }

    /// Scrolling capture's first step: the area overlay (Space for a window) up to the user's
    /// choice, then dismissed with no capture taken. Global top-left points. Nil when canceled,
    /// busy or failed.
    public func selectRegion(eventTime: TimeInterval? = nil) async -> (display: DisplayInfo, rect: CGRect)? {
        guard await begin(mode: .area, eventTime: eventTime), let session else { return nil }
        let selection = await overlay.selection()
        guard self.session === session, !session.finished else { return nil }
        let displays = session.displays
        end(session)
        switch selection {
        case .area(let displayID, let rect):
            guard let display = displays.first(where: { $0.id == displayID }) else { return nil }
            return (display, rect)
        case .window(let window, _):
            guard let display = CoordinateSpace.display(mostlyContaining: window.frame, in: displays) else { return nil }
            let rect = window.frame.intersection(display.frameTopLeft)
            return rect.isEmpty ? nil : (display, rect)
        case .fullscreen(let displayID):
            guard let display = displays.first(where: { $0.id == displayID }) else { return nil }
            return (display, display.frameTopLeft)
        case .cancelled, .record:
            return nil
        }
    }

    /// An image made outside the overlay (a scrolling capture) shown and stored like any capture:
    /// the card, then history, clipboard and save folder in the background.
    @discardableResult
    public func deliverCapture(_ image: CapturedImage, rect: CGRect, sourceApp: String? = nil) -> CaptureTicket {
        let trace = CaptureTrace(mode: .area, triggerTime: clock.now())
        lastTrace = trace
        let result = CaptureResult(mode: .area, image: image, createdAt: clock.date(), rect: rect, sourceApp: sourceApp, trace: trace)
        return deliver(result, configuration: configuration())
    }

    /// "Capture Previous Area": captures the stored area at once, with no overlay, on the display
    /// it was taken on. Nil when that display is gone or changed, or a capture is running.
    @discardableResult
    public func runPreviousArea(_ area: LastArea, eventTime: TimeInterval? = nil) async -> CaptureTicket? {
        guard session == nil else { return nil }
        var known = displays
        if known.isEmpty {
            do {
                known = try await refreshDisplays()
            } catch {
                report(mode: .area, stage: .capture, error: error)
                return nil
            }
        }
        guard let rect = area.restore(on: known) else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard await begin(mode: .area, eventTime: eventTime, pointer: center, presented: false), let session else { return nil }
        return await cropFrozen(session, displayID: area.displayID, rect: rect, mode: .area).ticket
    }

    /// The all-in-one HUD (design 20.5): presents the overlay with the toolbar, starts the frozen
    /// captures only in Screenshot mode (D59), waits for the user and confirms. Record mode ends
    /// with the target to record; the overlay stays up for the countdown.
    public func runHUD(_ state: AllInOneState, eventTime: TimeInterval? = nil) async -> HUDCaptureOutcome {
        guard await beginHUD(state, eventTime: eventTime), let session else { return .cancelled }
        let selection = await overlay.selection()
        guard self.session === session else { return .cancelled }
        return await finish(selection)
    }

    // MARK: Steps

    /// Presents the overlay at once, then starts the display captures and the window snapshot in
    /// parallel. Returns false when a capture is already running or no display is known.
    @discardableResult
    public func begin(
        mode: CaptureMode, eventTime: TimeInterval? = nil, pointer: CGPoint? = nil, presented: Bool? = nil
    ) async -> Bool {
        guard session == nil else { return false }
        let trace = CaptureTrace(mode: mode, triggerTime: eventTime ?? clock.now())
        lastTrace = trace
        let presented = presented ?? (mode != .fullscreen)
        var configuration = configuration()
        configuration.options = configuration.captureOptions(overlayShown: presented)

        var known = displays
        if known.isEmpty {
            do {
                known = try await refreshDisplays()
            } catch {
                report(mode: mode, stage: .capture, error: error)
                return false
            }
        }
        guard session == nil, !known.isEmpty else {
            if known.isEmpty { report(mode: mode, stage: .capture, error: CaptureError.failed("no displays")) }
            return false
        }

        let session = Session(mode: mode, trace: trace, displays: known, configuration: configuration, presented: presented)
        self.session = session
        if presented {
            overlay.present(mode: mode, displays: known)
            trace.record(.present, at: clock.now())
        }

        let targets: [DisplayInfo]
        if presented {
            targets = known
        } else {
            let point = pointer ?? CGPoint(x: known[0].frameTopLeft.midX, y: known[0].frameTopLeft.midY)
            targets = [CoordinateSpace.display(containing: point, in: known)
                ?? CoordinateSpace.nearestDisplay(to: point, in: known) ?? known[0]]
        }
        startFrozenCaptures(targets, session: session)
        if presented { startWindowSnapshot(session) }
        return true
    }

    /// The HUD's first step: presents the overlay with the toolbar at once, then the window
    /// snapshot, and the display captures only when `state` is in Screenshot mode. Switching to
    /// Screenshot later starts them then. Returns false when a capture is already running or no
    /// display is known.
    @discardableResult
    public func beginHUD(_ state: AllInOneState, eventTime: TimeInterval? = nil) async -> Bool {
        guard session == nil else { return false }
        let trace = CaptureTrace(mode: state.target, triggerTime: eventTime ?? clock.now())
        lastTrace = trace
        var configuration = configuration()
        configuration.options = configuration.captureOptions(overlayShown: true)

        var known = displays
        if known.isEmpty {
            do {
                known = try await refreshDisplays()
            } catch {
                report(mode: state.target, stage: .capture, error: error)
                return false
            }
        }
        guard session == nil, !known.isEmpty else {
            if known.isEmpty { report(mode: state.target, stage: .capture, error: CaptureError.failed("no displays")) }
            return false
        }

        let session = Session(
            mode: state.target, trace: trace, displays: known, configuration: configuration, presented: true, hud: true
        )
        self.session = session
        overlay.presentHUD(state, displays: known) { [weak self, weak session] mode in
            guard let self, let session, mode == .screenshot else { return }
            self.startFrozenCaptures(session.displays, session: session)
        }
        trace.record(.present, at: clock.now())
        if state.needsFrozenCapture { startFrozenCaptures(known, session: session) }
        startWindowSnapshot(session)
        return true
    }

    /// Starts the frozen capture of each display that has none yet.
    private func startFrozenCaptures(_ targets: [DisplayInfo], session: Session) {
        guard self.session === session, !session.finished else { return }
        let missing = targets.filter { session.frozen[$0.id] == nil }
        guard !missing.isEmpty else { return }
        session.pendingFrozen += missing.count
        for display in missing {
            session.frozen[display.id] = startDisplayCapture(display, session: session)
        }
    }

    private func startWindowSnapshot(_ session: Session) {
        session.windowTask = Task { [windowSource, overlay] in
            do {
                let windows = try await windowSource.snapshot()
                guard self.session === session else { return }
                session.windows = windows
                overlay.updateWindows(windows)
            } catch {
                self.log?.warning("capture: window list failed: \(error)")
            }
        }
    }

    /// Finishes the capture with the user's selection: crops the frozen image (waiting for it if
    /// needed) or captures the window live, dismisses the overlay, shows the card and hands the
    /// image to the background stage. A Record selection returns nil here; `runHUD` reports it.
    @discardableResult
    public func confirm(_ selection: OverlaySelection) async -> CaptureTicket? {
        await finish(selection).ticket
    }

    /// `confirm` with the HUD's Record outcome kept.
    private func finish(_ selection: OverlaySelection) async -> HUDCaptureOutcome {
        guard let session, !session.finished else { return .cancelled }
        switch selection {
        case .cancelled:
            end(session)
            return .cancelled

        case .area(let displayID, let rect):
            session.trace.record(.confirm, at: clock.now())
            if let area = LastArea.store(rect, displays: session.displays) { onAreaConfirmed?(area) }
            let mode: CaptureMode = session.hud ? .area : session.mode
            return await cropFrozen(session, displayID: displayID, rect: rect, mode: mode)

        case .fullscreen(let displayID):
            session.trace.record(.confirm, at: clock.now())
            guard let display = session.displays.first(where: { $0.id == displayID }) else {
                fail(session, error: CaptureError.displayNotFound(displayID))
                return .cancelled
            }
            return await cropFrozen(session, displayID: displayID, rect: display.frameTopLeft, mode: .fullscreen)

        case .window(let window, let includeShadow):
            session.trace.record(.confirm, at: clock.now())
            // The live window capture leaves out every other window, so the overlay can go first.
            end(session)
            var options = session.configuration.options
            options.includeWindowShadow = includeShadow
            let image: CapturedImage
            do {
                image = try await withStaleRetry { [captureSource] in
                    try await captureSource.captureWindow(window.id, options: options)
                }
            } catch {
                report(mode: session.mode, stage: .capture, error: error)
                return .cancelled
            }
            let result = CaptureResult(
                mode: session.hud ? .window : session.mode, image: image, createdAt: clock.date(), rect: window.frame,
                sourceApp: window.ownerName, trace: session.trace
            )
            return .screenshot(deliver(result, configuration: session.configuration))

        case .record(let target):
            session.trace.record(.confirm, at: clock.now())
            if case .area(let rect) = target, let area = LastArea.store(rect, displays: session.displays) {
                onAreaConfirmed?(area)
            }
            // The overlay stays up: it shows the countdown over the same dim.
            end(session, dismissOverlay: false)
            return .record(target, trace: session.trace)
        }
    }

    /// Crops the frozen image of `displayID` (starting its capture if Record mode never asked for
    /// it), then ends the session and delivers the card.
    private func cropFrozen(_ session: Session, displayID: DisplayID, rect: CGRect, mode: CaptureMode) async -> HUDCaptureOutcome {
        guard let display = session.displays.first(where: { $0.id == displayID }) else {
            fail(session, error: CaptureError.displayNotFound(displayID))
            return .cancelled
        }
        if session.frozen[displayID] == nil { startFrozenCaptures([display], session: session) }
        guard let task = session.frozen[displayID] else {
            fail(session, error: CaptureError.displayNotFound(displayID))
            return .cancelled
        }
        let frozen: CapturedImage
        do {
            frozen = try await task.value
        } catch {
            fail(session, error: error)
            return .cancelled
        }
        guard self.session === session, !session.finished else { return .cancelled }
        let cropped: CapturedImage
        let global: CGRect
        do {
            (cropped, global) = try CaptureCoordinator.crop(frozen, to: rect, on: display)
        } catch {
            fail(session, error: error)
            return .cancelled
        }
        end(session)
        let result = CaptureResult(
            mode: mode, image: cropped, createdAt: clock.date(), rect: global, sourceApp: nil, trace: session.trace
        )
        return .screenshot(deliver(result, configuration: session.configuration))
    }

    /// Closes the overlay without a capture (screen change, Esc handled outside the presenter).
    public func cancel() {
        if let session { end(session) }
    }

    // MARK: Internals

    private func startDisplayCapture(_ display: DisplayInfo, session: Session) -> Task<CapturedImage, any Error> {
        let options = session.configuration.options
        return Task { [captureSource, overlay] in
            let image: CapturedImage
            do {
                image = try await withStaleRetry {
                    try await captureSource.captureDisplay(display.id, options: options)
                }
            } catch {
                if session.presented { fail(session, error: error) }
                throw error
            }
            // A window selection may end the session first; its frozen images are then unused.
            guard self.session === session, !session.finished else { return image }
            if session.presented { overlay.showFrozen(image, displayID: display.id) }
            session.pendingFrozen -= 1
            // Recorded in the same main-actor job as the hand-over, before any resumed selection runs.
            if session.pendingFrozen == 0 { session.trace.record(.frozen, at: clock.now()) }
            return image
        }
    }

    private func finishFullscreen(_ session: Session) async -> CaptureTicket? {
        guard let (displayID, task) = session.frozen.first,
              let display = session.displays.first(where: { $0.id == displayID }) else { return nil }
        let image: CapturedImage
        do {
            image = try await task.value
        } catch {
            fail(session, error: error)
            return nil
        }
        guard self.session === session, !session.finished else { return nil }
        session.trace.record(.confirm, at: clock.now())
        end(session)
        let result = CaptureResult(
            mode: .fullscreen, image: image, createdAt: clock.date(), rect: display.frameTopLeft,
            sourceApp: nil, trace: session.trace
        )
        return deliver(result, configuration: session.configuration)
    }

    private func deliver(_ result: CaptureResult, configuration: CaptureConfiguration) -> CaptureTicket {
        if configuration.showQuickAccess {
            results.showCard(for: result)
            result.trace.record(.card, at: clock.now())
        }
        let stage = output
        let background = Task.detached(priority: .userInitiated) {
            try stage.run(result, configuration: configuration)
        }
        let stored = Task { [results, log] () -> StoredCapture? in
            do {
                let stored = try await background.value
                results.captureStored(stored)
                return stored
            } catch {
                log?.error("capture: output failed: \(error)")
                results.captureFailed(CaptureFailure(
                    mode: result.mode, stage: .output, captureError: nil, message: String(describing: error),
                    traceID: ObjectIdentifier(result.trace), copied: (error as? CaptureOutputError)?.copied ?? false
                ))
                return nil
            }
        }
        return CaptureTicket(result: result, stored: stored)
    }

    /// Runs `operation`; on a stale-content error refetches the displays once and runs it again.
    private func withStaleRetry<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as CaptureError where error.isStaleContent {
            log?.info("capture: \(error), refetching shareable content and retrying once")
            do {
                try await refreshDisplays()
            } catch {
                log?.warning("capture: refetch failed: \(error)")
            }
            return try await operation()
        }
    }

    private func end(_ session: Session, dismissOverlay: Bool = true) {
        guard !session.finished else { return }
        session.finished = true
        session.windowTask?.cancel()
        if self.session === session { self.session = nil }
        if session.presented, dismissOverlay { overlay.dismiss() }
    }

    private func fail(_ session: Session, error: any Error) {
        guard !session.finished else { return }
        end(session)
        report(mode: session.mode, stage: .capture, error: error)
    }

    private func report(mode: CaptureMode, stage: CaptureFailure.Stage, error: any Error) {
        let captureError = error as? CaptureError
        log?.error("capture \(mode.rawValue) failed: \(error)")
        results.captureFailed(CaptureFailure(
            mode: mode, stage: stage, captureError: captureError ?? .failed(String(describing: error)),
            message: String(describing: error)
        ))
    }

    /// The crop of a frozen display image for a selection in global points, and the rect it covers.
    /// Uses the image's real pixel size, which can differ from the display's nominal one.
    public static func crop(_ frozen: CapturedImage, to rect: CGRect, on display: DisplayInfo) throws
        -> (image: CapturedImage, rect: CGRect) {
        let geometry = SelectionGeometry(display: display)
        // Cut at the display edge rather than shifting the rect, so the crop is what was selected.
        let clamped = rect.standardized.intersection(display.frameTopLeft)
        guard !clamped.isNull else { throw CaptureError.failed("selection \(rect) is off the display") }
        var pixels = geometry.cropRect(for: clamped)
        let ratioX = Double(frozen.pixelWidth) / Double(max(display.pixelWidth, 1))
        let ratioY = Double(frozen.pixelHeight) / Double(max(display.pixelHeight, 1))
        if ratioX != 1 || ratioY != 1 {
            let minX = (pixels.minX * ratioX).rounded()
            let minY = (pixels.minY * ratioY).rounded()
            pixels = CGRect(
                x: minX, y: minY,
                width: (pixels.maxX * ratioX).rounded() - minX, height: (pixels.maxY * ratioY).rounded() - minY
            )
        }
        pixels = pixels.intersection(CGRect(origin: .zero, size: frozen.pixelSize))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              let cgImage = frozen.cgImage.cropping(to: pixels) else {
            throw CaptureError.failed("empty selection \(rect)")
        }
        let image = CapturedImage(cgImage: cgImage, scale: frozen.scale, displayID: display.id)
        return (image, clamped)
    }
}
