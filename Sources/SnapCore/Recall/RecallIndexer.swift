import Foundation

/// What the search settings allow (Recall design 7.7).
public struct RecallOptions: Sendable, Equatable {
    public var enabled: Bool
    public var previews: Bool
    public var excludedApps: [String]

    public init(enabled: Bool, previews: Bool, excludedApps: [String]) {
        self.enabled = enabled
        self.previews = previews
        self.excludedApps = excludedApps
    }

    public init(_ general: GeneralSettings) {
        self.init(enabled: general.searchInShelf, previews: general.searchPreviews, excludedApps: general.searchExcludedApps)
    }

    func excludes(_ app: String?) -> Bool {
        guard let app else { return false }
        return excludedApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }
}

/// Reads screenshots one at a time and keeps Snap's recall folder in step with the history
/// (Recall design 7.1 to 7.6). Every id carries a generation: a remove or a newer enqueue bumps
/// it, and an OCR that finishes with an old generation writes nothing.
public actor RecallIndexer {
    private let history: HistoryStore
    private let ocr: OCRStore
    private let recognizer: any TextRecognizer
    private let writer: RecallWriter
    private let log: Log?
    private let now: @Sendable () -> Date
    private var options: RecallOptions
    private var queue: [(id: String, force: Bool)] = []
    private var generations: [String: Int] = [:]
    private var current: String?
    private var worker: Task<Void, Never>?
    private var onPendingChange: @Sendable (Int) -> Void = { _ in }
    private var lastReported: Int?

    public init(
        history: HistoryStore, ocr: OCRStore, recognizer: any TextRecognizer, writer: RecallWriter,
        options: RecallOptions, log: Log?, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.history = history
        self.ocr = ocr
        self.recognizer = recognizer
        self.writer = writer
        self.options = options
        self.log = log
        self.now = now
    }

    /// Screenshots waiting for OCR, the one being read included.
    public var pending: Int { queue.count + (current == nil ? 0 : 1) }

    public func setOnPendingChange(_ handler: @escaping @Sendable (Int) -> Void) {
        onPendingChange = handler
    }

    /// Queues one capture. `force` drops the cached OCR first: the capture was edited.
    public func enqueue(_ id: String, force: Bool = false) {
        guard options.enabled else { return }
        generations[id, default: 0] += 1
        if force { discardOCR(id) }
        queue.removeAll { $0.id == id }
        queue.append((id, force))
        startWorker()
    }

    public func remove(_ ids: [String]) {
        for id in ids {
            generations[id, default: 0] += 1
            queue.removeAll { $0.id == id }
            do {
                try writer.remove(id: id)
            } catch {
                log?.warning("recall: cannot remove \(id): \(error)")
            }
        }
        reportPending()
    }

    public func update(options newOptions: RecallOptions) {
        let old = options
        options = newOptions
        if !newOptions.enabled {
            queue.removeAll()
            for id in generations.keys { generations[id, default: 0] += 1 }
            do {
                try writer.removeAll()
            } catch {
                log?.warning("recall: cannot clear the recall folder: \(error)")
            }
            reportPending()
            return
        }
        if !old.enabled {
            reconcile()
            return
        }
        if old.previews && !newOptions.previews {
            do {
                try writer.removePreviews()
            } catch {
                log?.warning("recall: cannot remove previews: \(error)")
            }
        }
        if newOptions.excludedApps != old.excludedApps || (!old.previews && newOptions.previews) {
            // Excluded apps lose their entries; newly allowed ones and missing previews are rebuilt.
            for item in screenshots() {
                if newOptions.excludes(item.sourceApp) {
                    remove([item.id])
                } else if old.excludes(item.sourceApp) || (!old.previews && newOptions.previews) {
                    enqueue(item.id)
                }
            }
        }
    }

    /// Removes entries without a screenshot and queues screenshots without an entry, newest first.
    public func reconcile() {
        guard options.enabled else { return }
        let items = screenshots()
        let known = Set(items.map(\.id))
        let stored: Set<String>
        do {
            stored = try writer.storedIDs()
        } catch {
            log?.warning("recall: cannot list the recall folder: \(error)")
            return
        }
        remove(Array(stored.subtracting(known)))
        for item in items.sorted(by: { $0.createdAt > $1.createdAt })
        where !stored.contains(item.id) && !options.excludes(item.sourceApp) && !queue.contains(where: { $0.id == item.id }) {
            generations[item.id, default: 0] += 1
            queue.append((item.id, false))
        }
        startWorker()
    }

    /// Returns when the queue is empty. For tests and the command line.
    public func drain() async {
        while let worker {
            await worker.value
            if self.worker == worker { break }
        }
    }

    // MARK: Work

    private func startWorker() {
        reportPending()
        guard worker == nil, !queue.isEmpty else { return }
        // OCR is background work: never at the priority of the capture that queued it.
        worker = Task(priority: .utility) { [weak self] in await self?.run() }
    }

    private func run() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            current = next.id
            reportPending()
            await process(next.id, generation: generations[next.id, default: 0])
            current = nil
        }
        worker = nil
        reportPending()
    }

    private func process(_ id: String, generation: Int) async {
        guard options.enabled, let item = item(id), item.kind == .image else { return }
        if options.excludes(item.sourceApp) {
            remove([id])
            return
        }
        var result = ocr.load(id: id)
        if result == nil {
            do {
                result = try await recognizer.recognize(imageAt: item.currentURL)
            } catch {
                log?.warning("recall: OCR failed for \(id): \(error)")
                return
            }
        }
        // The capture may have been edited, trashed or swept while it was being read.
        guard let result, generations[id, default: 0] == generation, options.enabled, let fresh = self.item(id),
              fresh.currentURL.lastPathComponent == result.imageName else { return }
        do {
            try ocr.save(result, id: id)
            let raw = result.lines.map(\.text)
            let lines = SecretFilter.redact(raw)
            var context: [String: String] = [:]
            if let app = fresh.sourceApp { context["source_app"] = app }
            let entry = RecallEntry(
                id: id, title: fresh.sourceApp ?? "Screenshot", createdAt: fresh.createdAt, updatedAt: now(),
                language: result.language, context: context, segments: lines.map(RecallEntry.Segment.init(text:)))
            // A preview of a capture with a hidden secret could show it, so it gets none.
            let showPreview = options.previews && lines == raw
            try writer.write(entry, previewFrom: showPreview ? fresh.currentURL : nil)
        } catch {
            log?.warning("recall: cannot write the entry for \(id): \(error)")
        }
    }

    private func item(_ id: String) -> CaptureItem? {
        do {
            return try history.item(id: id)
        } catch {
            return nil
        }
    }

    private func screenshots() -> [CaptureItem] {
        do {
            return try history.allItems().filter { $0.kind == .image }
        } catch {
            log?.warning("recall: cannot list history: \(error)")
            return []
        }
    }

    private func discardOCR(_ id: String) {
        do {
            try ocr.discard(id: id)
        } catch {
            log?.warning("recall: cannot discard ocr.json for \(id): \(error)")
        }
    }

    private func reportPending() {
        let value = pending
        guard value != lastReported else { return }
        lastReported = value
        onPendingChange(value)
    }
}
