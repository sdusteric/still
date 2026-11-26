import AppKit
import Foundation
import SnapCore
import SnapUI

/// The menu's last-capture and Recent Captures actions: menu thumbnails, Capture Previous Area,
/// Copy Text, and opening an image file or the clipboard's image as a capture.
extension AppWiring {

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

    /// A small thumbnail of a history item for the menu. Made off the main thread after every
    /// history change; a miss (the first menu after launch) decodes here once.
    func menuThumbnail(for id: String) -> CGImage? {
        if let cached = menuThumbnails[id] { return cached }
        let url: URL?
        do {
            url = try history.item(id: id)?.thumbnailURL
        } catch {
            url = nil
        }
        let thumbnail = url.flatMap { Self.makeMenuThumbnail($0) }
        menuThumbnails[id] = thumbnail
        return thumbnail
    }

    /// Renders the Recent Captures thumbnails in the background and swaps them in, so an edit or a
    /// new capture never makes the next menu decode full-size PNGs on the main thread.
    func refreshMenuThumbnails() {
        menuThumbnailTask?.cancel()
        let history = history
        let log = log
        menuThumbnailTask = Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) { () -> [String: CGImage] in
                let items: [CaptureItem]
                do {
                    items = try history.recent(limit: MenuModel.recentLimit)
                } catch {
                    log.warning("menu thumbnails: \(error)")
                    return [:]
                }
                var thumbnails: [String: CGImage] = [:]
                for item in items {
                    if let url = item.thumbnailURL, let image = AppWiring.makeMenuThumbnail(url) { thumbnails[item.id] = image }
                }
                return thumbnails
            }.value
            guard !Task.isCancelled else { return }
            self?.menuThumbnails = fresh
        }
    }

    nonisolated private static func makeMenuThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: menuThumbnailPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Previous area and Copy Text

    /// "Capture Previous Area" is enabled once an area was captured and its display is still here.
    var hasPreviousArea: Bool {
        guard let area = stateStore.state.lastArea else { return false }
        return coordinator.displays.isEmpty || area.restore(on: coordinator.displays) != nil
    }

    /// "Capture Previous Area": the last confirmed area again, at once, with no overlay.
    func capturePreviousArea(eventTime: TimeInterval? = nil) {
        guard !coordinator.isCapturing, scrollSession == nil, let area = stateStore.state.lastArea,
              permissionAllowsCapture("previous area") else { return }
        overlay.options = OverlayController.Options(settings: settings)
        Task {
            if coordinator.displays.isEmpty { await refreshDisplays() }
            guard area.restore(on: coordinator.displays) != nil else {
                showHintMessage("The previous area's display changed")
                return
            }
            guard let ticket = await coordinator.runPreviousArea(area, eventTime: eventTime),
                  let cardID = cardForTrace[ObjectIdentifier(ticket.result.trace)] else { return }
            records[cardID]?.stored = ticket.stored
        }
    }

    /// A one-line chip near the pointer.
    func showHintMessage(_ message: String, warning: Bool = true) {
        guard let screen = AppWiring.screenUnderPointer() else { return }
        hint.show(message: message, warning: warning, near: NSEvent.mouseLocation, visibleFrame: screen.visibleFrame)
    }

    /// Reads the text in screenshots (cached `ocr.json` first) and copies it, one capture after
    /// another with a blank line between them.
    func copyText(of items: [CaptureItem]) async -> CaptureText.Outcome {
        let ocr = OCRStore(history: history)
        let recognizer = textRecognizer
        var texts: [String] = []
        for item in items where item.kind == .image {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try await CaptureText.read(item, ocr: ocr, recognizer: recognizer)
                }.value
                if let text { texts.append(text) }
            } catch {
                log.warning("copy text \(item.id): \(error)")
                return .failed
            }
        }
        guard !texts.isEmpty else { return .noText }
        do {
            try clipboard.writeText(texts.joined(separator: "\n\n"))
        } catch {
            log.warning("copy text: \(error)")
            return .failed
        }
        return .copied
    }

    /// Copy Text on a card: waits for the capture to be stored, then reads its current image.
    func copyCardText(_ cardID: String) async -> CaptureText.Outcome {
        guard let record = records[cardID] else { return .failed }
        var item = record.item
        if item == nil { item = await record.stored?.value?.item }
        guard let item else { return .failed }
        return await copyText(of: [item])
    }

    /// The history item of the newest complete screenshot, waiting for one still being stored.
    private func lastScreenshotItem() async -> CaptureItem? {
        if let record = lastRecord {
            // Never fall back to an older capture: a newest one that failed to store has no text to copy.
            if let item = record.item { return item.kind == .image ? item : nil }
            return await record.stored?.value?.item
        }
        return recentCaptures().first { $0.state == .complete && $0.kind == .image }
    }

    /// "Copy Text from Last Capture": on its card when the card is open, else a chip near the pointer.
    func copyLastCaptureText() {
        if let record = lastRecord, quickAccess.card(record.cardID) != nil {
            Task { await quickAccess.perform(.copyText, on: record.cardID) }
            return
        }
        Task {
            guard let item = await lastScreenshotItem() else {
                showHintMessage("The last capture has no screenshot to read")
                return
            }
            let outcome = await copyText(of: [item])
            showHintMessage(outcome.message, warning: outcome != .copied)
        }
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

    // MARK: Open Image

    /// "Open Image...": a PNG, JPEG or HEIC file becomes a capture in history with its card.
    func openImageFile() {
        NSApp.activate()
        guard let path = Self.chooseImage() else { return }
        let url = URL(filePath: path)
        do {
            importImage(try PNGReader.read(url), name: url.deletingPathExtension().lastPathComponent)
        } catch {
            log.warning("open image \(url.lastPathComponent): \(error)")
            showHintMessage("Can't open that image")
        }
    }

    /// The clipboard holds an image Snap can open.
    var hasClipboardImage: Bool {
        // Only the types Open Clipboard Image reads, so the item never leads to "no image".
        NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
    }

    /// "Open Clipboard Image": the copied image becomes a capture with its card.
    func openClipboardImage() {
        let pasteboard = NSPasteboard.general
        let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard let data else {
            showHintMessage("The clipboard has no image")
            return
        }
        do {
            importImage(try PNGReader.read(data), name: nil)
        } catch {
            log.warning("open clipboard image: \(error)")
            showHintMessage("Can't open the clipboard image")
        }
    }

    /// Writes the image to history like a capture, then shows its card.
    private func importImage(_ image: CapturedImage, name: String?) {
        do {
            let png = try PNGWriter.data(for: image.cgImage, scale: image.scale)
            let now = Date()
            // History names may not hold ":" or start with "."; a bare name falls back to the pattern.
            let cleaned = name?.replacingOccurrences(of: ":", with: "-").drop { $0 == "." }
            let fileName = cleaned.flatMap { $0.isEmpty ? nil : "\($0).png" }
                ?? FileNamer(pattern: settings.general.fileNamePattern).fileName(date: now, app: nil) { _ in false }
            let item = try history.add(
                pngData: png, fileName: fileName, mode: .area, scale: image.scale, createdAt: now,
                pixelSize: PixelSize(width: image.cgImage.width, height: image.cgImage.height)
            )
            historyChanged()
            publishShelfStatus()
            Task { [recall] in await recall.enqueue(item.id) }
            _ = reopen(historyID: item.id, showCard: true)
        } catch {
            log.warning("open image: \(error)")
            showHintMessage("Can't open that image")
        }
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
            // One record per capture: an older one with a closed card would act on stale edits.
            for (cardID, old) in records where old.item?.id == id && quickAccess.card(cardID) == nil {
                records[cardID] = nil
                recordOrder.removeAll { $0 == cardID }
                if let trace = old.trace { cardForTrace[ObjectIdentifier(trace)] = nil }
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
}
