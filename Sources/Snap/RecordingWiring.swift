import AppKit
import Foundation
import SnapCore
import SnapSystem
import SnapUI

/// Screen recording in the app (design 20.6): `RecordingController` with `LiveRecordingSource`,
/// the countdown over the HUD's overlay, the outline panel around an area, the status item timer
/// and every stop path (timer click, Cmd+Shift+5, the Stop Recording shortcut, quit, sleep).
/// Only the installed app makes one; tests drive `RecordingController` with fakes.
final class RecordingWiring {
    private unowned let app: AppWiring
    let controller: RecordingController
    private let source: LiveRecordingSource
    private let outline = RecordingOutlinePanel()
    private let clock: SystemClock

    /// The status item shows the timer, "Saving" or the viewfinder (nil).
    var onIndicatorChange: ((RecordingIndicator?) -> Void)?
    /// What the timer's Option-click menu shows for the current recording.
    private(set) var menuInput: RecordingMenuInput?
    /// The area being recorded, for the outline.
    private var area: CGRect?

    init(app: AppWiring) {
        self.app = app
        clock = app.clock
        source = LiveRecordingSource(captureSource: app.captureSource, clock: app.clock, log: app.log)
        controller = RecordingController(
            clock: app.clock, history: app.history, source: source, diskSpace: LiveDiskSpace(),
            microphone: app.microphone, fileNamer: FileNamer(pattern: app.settings.general.fileNamePattern), log: app.log
        )
        controller.onStateChange = { [weak self] state in self?.stateChanged(state) }
    }

    /// Counting down, starting, recording or finishing: Cmd+Shift+5 and Record Screen stop instead.
    var isBusy: Bool { controller.state.isBusy }
    var activeItemID: String? { controller.activeItemID }
    func now() -> TimeInterval { clock.now() }

    /// The HUD's check before Record: nil when a recording may start (disk space, busy).
    func preflight() -> RecordingFailure? { controller.preflight() }

    var recordingMenuModel: RecordingMenuModel? { menuInput.map(RecordingMenuModel.init) }

    // MARK: Starting

    /// A Record confirm from the HUD. The overlay is still up: it shows the countdown, takes
    /// Return and Esc, and leaves when the stream starts (M23).
    func record(_ target: RecordingTarget, displays: [DisplayInfo]) async {
        guard !isBusy else {
            app.overlay.dismiss()
            return
        }
        let settings = app.settings
        if let failure = controller.preflight() {
            app.log.warning("recording: cannot start: \(failure)")
            app.overlay.dismiss()
            return
        }
        var excluded = app.overlay.surfaceWindowIDs + app.quickAccess.surfaceWindowIDs + app.hint.surfaceWindowIDs
        if case .area(let rect) = target {
            // The outline panel exists only after its first show; its window number has to be in
            // the filter's exclusions before the stream starts, so it is shown and hidden at once.
            outline.show(around: rect, primaryHeight: ScreenSpace.primaryHeight)
            outline.hide()
            if let id = outline.windowID { excluded.append(id) }
        }
        var icons: [WindowID] = []
        if settings.capture.hideDesktopIcons, let displayID = Self.displayID(of: target, in: displays) {
            do {
                icons = try await source.desktopIconWindowIDs(on: displayID)
            } catch {
                app.log.warning("recording: desktop icon windows: \(error)")
            }
        }
        let plan: RecordingPlan
        do {
            plan = try RecordingPlan.make(
                target: target, displays: displays, settings: settings, excludedWindowIDs: excluded,
                desktopIconWindowIDs: icons
            )
        } catch {
            app.log.warning("recording: no plan for \(target): \(error)")
            app.overlay.dismiss()
            return
        }
        if case .area = target { area = plan.screenRect } else { area = nil }
        menuInput = RecordingMenuInput(
            target: target.mode, size: plan.sourceRect.size, fps: plan.fps, format: plan.codec,
            microphoneName: microphoneName(plan: plan), systemAudio: plan.capturesAudio,
            stopShortcut: settings.shortcuts.stopRecording
        )
        app.overlay.onCountdownKey = { [weak self] key in
            switch key {
            case .startNow: self?.controller.skipCountdown()
            case .cancel: self?.controller.cancelCountdown()
            }
        }
        let outcome = await controller.start(
            plan: plan, countdownSeconds: RecordingSettings.normalizedCountdown(settings.recording.countdownSeconds)
        )
        app.overlay.onCountdownKey = nil
        if app.overlay.isHoldingForRecording { app.overlay.dismiss() }
        switch outcome {
        case .recording(let item):
            app.log.info("recording: started \(item.id)")
            app.historyChanged()
        case .cancelled:
            app.log.info("recording: cancelled during the countdown")
            finishedUI()
        case .failed(let failure):
            finishedUI()
            app.recordingFailed(failure)
        }
    }

    /// The name the recording menu shows, nil when the microphone is off or not allowed.
    private func microphoneName(plan: RecordingPlan) -> String? {
        guard plan.capturesMicrophone, app.microphone.status().isAuthorized else { return nil }
        let devices = InputDevices.audioInputs()
        let id = InputDevices.resolve(plan.microphoneDeviceID, among: devices)
        return devices.first { $0.id == id }?.name ?? devices.first?.name
    }

    private static func displayID(of target: RecordingTarget, in displays: [DisplayInfo]) -> DisplayID? {
        switch target {
        case .fullscreen(let id): return id
        case .area(let rect):
            return CoordinateSpace.nearestDisplay(to: CGPoint(x: rect.midX, y: rect.midY), in: displays)?.id
        case .window(let window):
            return CoordinateSpace.nearestDisplay(to: CGPoint(x: window.frame.midX, y: window.frame.midY), in: displays)?.id
        }
    }

    // MARK: Stopping

    /// The timer click, Cmd+Shift+5, the Stop Recording shortcut or the menu item. During the
    /// countdown it cancels.
    func stop(reason: RecordingStopReason) {
        Task { _ = await controller.stop(reason: reason) }
    }

    /// Cancel Recording: stops and moves the item folder to the Trash (design 20.4 step 6).
    func cancel() {
        Task { await controller.cancelRecording() }
    }

    /// Quit or sleep: finishes the file, waiting at most `timeout` seconds, then calls `done`.
    func finishForQuit(reason: RecordingStopReason, timeout: TimeInterval, done: @escaping () -> Void) {
        var called = false
        let finish = {
            guard !called else { return }
            called = true
            done()
        }
        Task {
            _ = await controller.stop(reason: reason)
            finish()
        }
        Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            app.log.warning("recording: still finishing after \(Int(timeout)) s, quitting anyway")
            finish()
        }
    }

    // MARK: State

    private func stateChanged(_ state: RecordingController.State) {
        switch state {
        case .idle:
            finishedUI()
        case .countdown(let seconds):
            app.overlay.showCountdown(seconds)
        case .starting:
            // M23: the dim, disc and hint leave at once when the recording starts.
            if app.overlay.isHoldingForRecording { app.overlay.dismiss() }
        case .recording(let since):
            if let area { outline.show(around: area, primaryHeight: ScreenSpace.primaryHeight) }
            onIndicatorChange?(.recording(since: since))
        case .finishing:
            onIndicatorChange?(.saving)
        case .done(let result):
            finishedUI()
            app.recordingFinished(result)
        case .failed:
            finishedUI()
        }
    }

    private func finishedUI() {
        outline.hide()
        area = nil
        menuInput = nil
        onIndicatorChange?(nil)
    }
}

// MARK: Results and video cards

extension AppWiring {
    /// A finished recording (design 20.6, D67, D69): the mp4's file URL on the clipboard, the save
    /// folder copy when that is on, and the video card with its note ("Stopped: ...", "No
    /// microphone"). A file that does not play gets a card with Reveal only.
    func recordingFinished(_ result: RecordingResult) {
        historyChanged()
        let note = result.note ?? (result.noMicrophone ? "No microphone" : nil)
        if let note { log.info("recording \(result.item.id): \(note)") }
        let item = result.item
        guard result.isComplete else {
            log.warning("recording \(item.id): the file does not play, kept as interrupted")
            if settings.capture.showQuickAccess { showVideoCard(item, copied: false, note: note, revealOnly: true) }
            return
        }
        let copied = settings.capture.copyToClipboard && copyFileURLs([item.originalURL])
        if settings.capture.saveToFolder {
            Task { _ = await saveVideo(item) }
        }
        if settings.capture.showQuickAccess { showVideoCard(item, copied: copied, note: note) }
    }

    /// The start failed (design D69): the permission hint for a denial; for any other stream or
    /// history failure, the "Recording could not start" chip near the pointer for 4 s.
    func recordingFailed(_ failure: RecordingFailure) {
        log.warning("recording: \(failure)")
        switch failure {
        case .permissionDenied:
            screenRecordingDenied()
        case .startFailed, .history:
            guard let screen = AppWiring.screenUnderPointer() else { return }
            hint.show(message: "Recording could not start", near: NSEvent.mouseLocation, visibleFrame: screen.visibleFrame)
        case .plan, .notEnoughDisk, .busy:
            // The HUD's size chip says these before Record is confirmed.
            break
        }
    }

    /// A video card: the poster as the thumbnail and the duration pill. A file that does not play
    /// may have no poster; its card shows a plain dark frame of the recording's size instead.
    func showVideoCard(_ item: CaptureItem, copied: Bool, note: String? = nil, revealOnly: Bool = false) {
        var thumbnail: CGImage?
        var pointSize = CGSize.zero
        if let posterURL = item.posterURL {
            do {
                let poster = try PNGReader.read(posterURL)
                thumbnail = poster.cgImage
                pointSize = poster.pointSize
            } catch {
                log.warning("recording \(item.id): cannot read the poster: \(error)")
            }
        }
        if thumbnail == nil, revealOnly {
            let pixels = item.pixelSize ?? PixelSize(width: 1280, height: 800)
            thumbnail = SyntheticImages.solid(width: 160, height: max(160 * pixels.height / max(pixels.width, 1), 1), color: .black)
            pointSize = CGSize(width: Double(pixels.width) / max(item.scale, 1), height: Double(pixels.height) / max(item.scale, 1))
        }
        guard let thumbnail else {
            log.warning("recording \(item.id): no poster, no card")
            return
        }
        let cardID = "video-" + UUID().uuidString.lowercased()
        videoCards[cardID] = item
        quickAccess.show(QuickAccessItem(
            id: cardID, thumbnail: thumbnail, pointSize: pointSize, copied: copied, kind: .video,
            durationSeconds: item.durationSeconds, note: note, revealOnly: revealOnly
        ))
    }

    /// Puts file URLs on the pasteboard (`public.file-url`), so pasting attaches the files.
    func copyFileURLs(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if urls.count == 1 {
            do {
                try clipboard.writeFileURL(urls[0])
                return true
            } catch {
                log.error("copy file: \(error)")
                return false
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Save on a video card: copies the mp4 into the save folder with the file name pattern and
    /// the same collision rule as PNGs (design 20.4).
    func saveVideo(_ item: CaptureItem) async -> URL? {
        let source = item.originalURL
        let folder = paths.saveFolder(for: settings)
        let namer = FileNamer(pattern: settings.general.fileNamePattern)
        let log = log
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in namer.candidates(date: item.createdAt, app: item.sourceApp, fileExtension: "mp4") {
                    let target = folder.appending(path: name, directoryHint: .notDirectory)
                    guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
                    try FileManager.default.copyItem(at: source, to: target)
                    return target
                }
                return nil
            } catch {
                log.error("save recording \(item.id): \(error)")
                return nil
            }
        }.value
    }
}
