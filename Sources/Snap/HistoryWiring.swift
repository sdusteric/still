import AppKit
import Foundation
import SnapCore
import SnapUI

/// The capture history window in the app (design 20.3): its model and loader, the commands it
/// sends back (copy, Copy Text, trash, reveal) and its stored frame.
extension AppWiring {

    /// "Capture History..." or its shortcut: one window, activated because the user opened it.
    func openHistoryWindow() {
        let controller = historyWindow ?? makeHistoryWindow()
        historyWindow = controller
        controller.model.captureAreaShortcut = settings.shortcuts.captureArea.map { HotkeyCombo($0).displayString }
        controller.model.retention = settings.general.screenshotRetention
        controller.show()
    }

    /// A Shelf search result: History opens with the capture selected (Recall design 7.5a).
    func revealInHistory(_ id: String) {
        openHistoryWindow()
        historyWindow?.model.reveal(id)
    }

    private func makeHistoryWindow() -> HistoryWindowController {
        let history = history
        let model = HistoryWindowModel(
            load: { [textIndex] in try AppWiring.historySnapshot(history, textIndex: textIndex) },
            context: { HistoryDateContext(now: Date()) },
            // Adding or removing an item folder changes the folder's date; edits post historyDidChange.
            changeStamp: { Self.modificationDate(of: history.directory) },
            actions: HistoryActions(
                showInQuickAccess: { [weak self] items in
                    // Oldest first, so the first selected ends up on top of the stack.
                    for item in items.reversed() { self?.showRecentCapture(id: item.id) }
                },
                copy: { [weak self] items in self?.copyHistoryItems(items) ?? false },
                copyText: { [weak self] items in
                    Task {
                        guard let self else { return }
                        let outcome = await self.copyText(of: items)
                        self.showHintMessage(outcome.message, warning: outcome != .copied)
                    }
                },
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

    /// Every item, the folder size and the text read from each screenshot, for History search.
    /// Runs off the main thread.
    nonisolated private static func historySnapshot(_ history: HistoryStore, textIndex: CaptureTextIndex) throws -> HistorySnapshot {
        let items = try history.allItems()
        let texts = textIndex.texts(for: items, ocr: OCRStore(history: history))
        return HistorySnapshot(items: items, totalBytes: try history.totalBytes(), texts: texts)
    }

    /// A folder's modification date, nil when it cannot be read. `FileManager`, not
    /// `URL.resourceValues`, which caches the value on the URL.
    private static func modificationDate(of folder: URL) -> Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path(percentEncoded: false))
            return attributes[.modificationDate] as? Date
        } catch {
            return nil
        }
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
    func trashHistoryItems(_ ids: [String]) -> Set<String> {
        var trashed = Set<String>()
        for id in ids {
            do {
                if try history.trash(id: id) { trashed.insert(id) }
            } catch {
                log.error("history: cannot move \(id) to the Trash: \(error)")
            }
        }
        if !trashed.isEmpty {
            forgetRecords(ofItems: trashed)
            historyChanged()
        }
        let removed = Array(trashed)
        Task { [recall] in await recall.remove(removed) }
        return trashed
    }
}
