import AppKit
import Foundation
import SnapCore
import SnapUI

/// Pin to screen in the app (design 20.2): the card's Pin chip and P key, "Pin Last Capture" in
/// the menu and as a shortcut, the history window, and the commands a pin sends back. Placement,
/// sizes and the cap of 8 are `PinBoard`'s; this only builds requests and runs the commands.
extension AppWiring {
    func makePinActions() -> PinActions {
        PinActions(
            copy: { [weak self] pin in self?.copyPin(pin) ?? false },
            save: { [weak self] pin in self?.savePin(pin) },
            annotate: { [weak self] itemID in self?.annotate(historyID: itemID) },
            showInQuickAccess: { [weak self] itemID in self?.showRecentCapture(id: itemID) },
            reveal: { url in AppWiring.reveal(url) },
            closed: { [weak self] itemID in self?.log.info("pin: closed \(itemID)") }
        )
    }

    /// The Pin chip or P on a hovered card. The pin grows from the card's thumbnail (M17) and the
    /// card closes; true when a pin opened.
    func pinCard(_ cardID: String) async -> Bool {
        guard let record = records[cardID] else { return false }
        if record.item == nil, let stored = record.stored, let item = await stored.value?.item {
            record.item = item
        }
        let thumbnail = quickAccess.thumbnailFrame(for: cardID).map { ScreenSpace.topLeft(fromScreen: $0) }
        guard let request = pinRequest(for: record, origin: .card(thumbnailFrame: thumbnail)) else { return false }
        pins.open(request)
        return true
    }

    /// "Pin Last Capture": the newest screenshot of this session, else the newest in history.
    func pinLastCapture() {
        if let record = lastRecord {
            if let request = pinRequest(for: record, origin: .menu) { pins.open(request) }
            return
        }
        guard let newest = recentCaptures().first(where: { $0.kind == .image && $0.state == .complete }),
              let record = record(forHistoryID: newest.id),
              let request = pinRequest(for: record, origin: .menu) else { return }
        pins.open(request)
    }

    /// The history window's Pin button, P and context menu. Recordings are never pinned.
    func pin(historyItems items: [CaptureItem]) {
        for item in items where item.kind == .image && item.state == .complete {
            guard let record = record(forHistoryID: item.id),
                  let request = pinRequest(for: record, origin: .history) else { continue }
            pins.open(request)
        }
    }

    /// The current image (the edited one when shown) at its point size. The capture's own screen
    /// rect places it only for the unedited image, since an edit changes the size (design D47).
    private func pinRequest(for record: CaptureRecord, origin: PinOrigin) -> PinRequest? {
        guard let itemID = record.item?.id else {
            log.warning("pin: \(record.cardID) has no history item yet")
            return nil
        }
        let image = record.current
        let placed = record.showingEdited ? nil : (record.screenRect ?? record.item?.screenRect)
        return PinRequest(
            itemID: itemID, image: image.cgImage, pointSize: image.pointSize,
            screenRect: record.mode == .fullscreen ? nil : placed,
            isWindowCapture: record.mode == .window && !record.showingEdited,
            fileURL: record.currentURL, createdAt: record.createdAt, origin: origin
        )
    }

    /// Cmd+C on a pin: the pin's image as it was captured.
    private func copyPin(_ pin: PinModel) -> Bool {
        let image = CapturedImage(cgImage: pin.image, scale: Self.scale(of: pin))
        let fileURL = pin.fileURL
        Task { _ = await copyToClipboard(image, fileURL: fileURL) }
        return true
    }

    /// Cmd+S on a pin: the image into the save folder with the file name pattern.
    private func savePin(_ pin: PinModel) {
        let image = CapturedImage(cgImage: pin.image, scale: Self.scale(of: pin))
        let folder = paths.saveFolder(for: settings)
        let pattern = settings.general.fileNamePattern
        let date = pin.createdAt
        let log = log
        Task.detached(priority: .userInitiated) {
            do {
                let url = try AppWiring.write(image, toFolder: folder, pattern: pattern, date: date, app: nil)
                log.info("pin: saved \(url.lastPathComponent)")
            } catch {
                log.error("pin save: \(error)")
            }
        }
    }

    private static func scale(of pin: PinModel) -> Double {
        pin.pointSize.width > 0 ? Double(pin.image.width) / pin.pointSize.width : 2
    }
}
