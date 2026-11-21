import AppKit
import Foundation
import SnapCore
import SnapUI

/// Scrolling capture in the app (design 6.7): the area overlay picks the region (Space for a
/// window), then an outline marks it and a bar under it shows the size so far with Done and
/// Cancel while the user scrolls. Return or Done stitches and shows the card; Esc cancels.
extension AppWiring {
    /// Return, keypad Enter and Esc while the bar is up.
    static let scrollKeys = [
        KeyShortcut(keyCode: 36, modifiers: 0), KeyShortcut(keyCode: 76, modifiers: 0), KeyShortcut(keyCode: 53, modifiers: 0),
    ]

    func captureScrolling(eventTime: TimeInterval? = nil) {
        guard !coordinator.isCapturing, !overlay.isPresented, scrollSession == nil, !recorder.isBusy,
              permissionAllowsCapture("scrolling") else { return }
        overlay.options = OverlayController.Options(settings: settings)
        Task {
            if coordinator.displays.isEmpty {
                await refreshDisplays()
            } else {
                overlay.prepare(displays: coordinator.displays)
            }
            guard let region = await coordinator.selectRegion(eventTime: eventTime) else { return }
            guard region.rect.width >= 16, region.rect.height >= 16 else {
                showHintMessage("Pick a larger area to scroll")
                return
            }
            startScrollSession(display: region.display, area: region.rect.integral)
        }
    }

    private func startScrollSession(display: DisplayInfo, area: CGRect) {
        let model = ScrollCaptureBarModel(scale: display.scale)
        let primaryHeight = ScreenSpace.primaryHeight
        scrollOutline.show(around: area, primaryHeight: primaryHeight)
        // Sized for its longest line, so the bar never jumps as the status changes.
        let sizing = ScrollCaptureBarModel(scale: 1)
        sizing.progress = ScrollCaptureProgress(status: .stopped, pixelSize: PixelSize(width: 99_999, height: 99_999))
        let visible = AppWiring.visibleFrameTopLeft(for: display) ?? display.frameTopLeft
        let barSize = ScrollCaptureBarPanel.barSize(sizing)
        model.barWidth = barSize.width
        let frame = ScrollCaptureLayout.barFrame(area: area, visibleFrame: visible, barSize: barSize)
        scrollBar.show(model, frame: frame, primaryHeight: primaryHeight)

        var excluded = quickAccess.surfaceWindowIDs + hint.surfaceWindowIDs
        if let id = scrollOutline.windowID { excluded.append(id) }
        if let id = scrollBar.windowID { excluded.append(id) }
        let options = CaptureOptions(hideDesktopIcons: settings.capture.hideDesktopIcons, excludedWindowIDs: excluded)
        let session = ScrollCaptureSession(
            source: captureSource, display: display, area: area, options: options, clock: clock,
            onProgress: { progress in model.progress = progress }
        )
        let log = log
        session.onError = { error in log.warning("scrolling capture: \(error)") }
        scrollSession = session
        model.onDone = { [weak self] in self?.finishScrollSession(area: area) }
        model.onCancel = { [weak self] in self?.cancelScrollSession() }
        grabKeys?(Self.scrollKeys) { [weak self] index, pressed in
            guard pressed else { return }
            if index == 2 { self?.cancelScrollSession() } else { self?.finishScrollSession(area: area) }
        }
        log.info("scrolling capture: started on display \(display.id), \(Int(area.width))x\(Int(area.height)) pt")
        session.start()
    }

    private func finishScrollSession(area: CGRect) {
        guard let session = scrollSession else { return }
        // Cleared now, so a second Return or click while the last frame is taken does nothing.
        scrollSession = nil
        endScrollChrome()
        Task {
            let image = await session.finish()
            guard let image else {
                showHintMessage("Nothing was captured")
                return
            }
            log.info("scrolling capture: \(image.pixelWidth)x\(image.pixelHeight) px")
            let ticket = coordinator.deliverCapture(image, rect: area)
            if let cardID = cardForTrace[ObjectIdentifier(ticket.result.trace)] { records[cardID]?.stored = ticket.stored }
        }
    }

    private func cancelScrollSession() {
        guard let session = scrollSession else { return }
        session.cancel()
        scrollSession = nil
        endScrollChrome()
        log.info("scrolling capture: canceled")
    }

    private func endScrollChrome() {
        releaseKeys?()
        scrollBar.hide()
        scrollOutline.hide()
    }

    /// The visible frame (no menu bar or Dock) of the screen showing `display`, in global top-left points.
    static func visibleFrameTopLeft(for display: DisplayInfo) -> CGRect? {
        let primaryHeight = ScreenSpace.primaryHeight
        let screen = NSScreen.screens.first { ScreenSpace.topLeft(fromScreen: $0.frame, primaryHeight: primaryHeight) == display.frameTopLeft }
        return screen.map { ScreenSpace.topLeft(fromScreen: $0.visibleFrame, primaryHeight: primaryHeight) }
    }
}
