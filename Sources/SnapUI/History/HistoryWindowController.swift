import AppKit
import Observation
import Quartz
import SnapCore
import SwiftUI
import Synchronization

/// What the history window lists: every item and the folder's total size.
public struct HistorySnapshot: Sendable {
    public var items: [CaptureItem]
    public var totalBytes: Int64

    public init(items: [CaptureItem], totalBytes: Int64) {
        self.items = items
        self.totalBytes = totalBytes
    }
}

/// What a history button, key or context menu row does (design 20.3).
public enum HistoryCommand: Sendable, Hashable, CaseIterable {
    case showInQuickAccess, copy, pin, annotate, reveal, trash, quickLook

    public var title: String {
        switch self {
        case .showInQuickAccess: "Show in Quick Access"
        case .copy: "Copy"
        case .pin: "Pin to Screen"
        case .annotate: "Open in Annotate"
        case .reveal: "Reveal in Finder"
        case .trash: "Move to Trash"
        case .quickLook: "Quick Look"
        }
    }
}

/// One context menu row.
public struct HistoryMenuRow: Sendable, Hashable {
    public var command: HistoryCommand
    public var isEnabled: Bool
    public var separatorBefore: Bool
}

/// How a click changes the selection: a plain click, Cmd-click or Shift-click.
public enum HistorySelectMode: Sendable, Hashable {
    case replace, toggle, extend
}

public enum HistoryDirection: Sendable, Hashable {
    case left, right, up, down
}

/// Keys in the history window (design 20.3).
public enum HistoryKey: Sendable, Hashable {
    case showInQuickAccess, quickLook, copy, pin, trash, focusSearch, clearSearch, selectAll
    case move(HistoryDirection, extend: Bool)

    /// `characters` is `charactersIgnoringModifiers`.
    public init?(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        switch keyCode {
        case 36, 76: self = .showInQuickAccess
            return
        case 49: self = .quickLook
            return
        case 53: self = .clearSearch
            return
        case 51, 117:
            guard command else { return nil }
            self = .trash
            return
        case 123: self = .move(.left, extend: shift)
            return
        case 124: self = .move(.right, extend: shift)
            return
        case 125: self = .move(.down, extend: shift)
            return
        case 126: self = .move(.up, extend: shift)
            return
        default: break
        }
        switch (characters?.lowercased(), command) {
        case ("c", true): self = .copy
        case ("f", true): self = .focusSearch
        case ("a", true): self = .selectAll
        case ("p", false): self = .pin
        default: return nil
        }
    }
}

/// What the grid area shows.
public enum HistoryContent: Sendable, Hashable {
    case grid
    /// No captures at all in the kept period.
    case empty
    /// The search matched nothing: `No captures match “notes”`.
    case noResults(String)
    /// The kind filter matched nothing, with no search.
    case emptyFilter(HistoryQuery.KindFilter)
}

/// What the app does for history commands. Supplied by the app wiring.
public struct HistoryActions {
    /// Shows each item's Quick Access card again with a fresh timer, without the clipboard.
    public var showInQuickAccess: @MainActor ([CaptureItem]) -> Void
    /// Copies images, or a recording's file URL; true on success.
    public var copy: @MainActor ([CaptureItem]) -> Bool
    public var pin: @MainActor ([CaptureItem]) -> Void
    public var annotate: @MainActor (CaptureItem) -> Void
    public var reveal: @MainActor ([CaptureItem]) -> Void
    /// Moves the item folders to the Trash (`FileManager.trashItem`); returns the ids moved.
    public var trash: @MainActor ([String]) -> Set<String>
    public var openFolder: @MainActor () -> Void

    public init(
        showInQuickAccess: @escaping @MainActor ([CaptureItem]) -> Void = { _ in },
        copy: @escaping @MainActor ([CaptureItem]) -> Bool = { _ in false },
        pin: @escaping @MainActor ([CaptureItem]) -> Void = { _ in },
        annotate: @escaping @MainActor (CaptureItem) -> Void = { _ in },
        reveal: @escaping @MainActor ([CaptureItem]) -> Void = { _ in },
        trash: @escaping @MainActor ([String]) -> Set<String> = { _ in [] },
        openFolder: @escaping @MainActor () -> Void = {}
    ) {
        self.showInQuickAccess = showInQuickAccess
        self.copy = copy
        self.pin = pin
        self.annotate = annotate
        self.reveal = reveal
        self.trash = trash
        self.openFolder = openFolder
    }
}

/// Quick Look for the selection. The live one is `QuickLookPreviewer`; tests record the calls.
@MainActor
public protocol HistoryPreviewing: AnyObject {
    func preview(_ urls: [URL], selectedIndex: Int)
}

/// The history window's state (design 20.3): items, kind filter, search, day sections, the grid
/// rows, selection, button states, context menu, keys and the footer. Pure: items come from an
/// injected loader, dates from an injected context, and every effect goes through `actions`.
@Observable
public final class HistoryWindowModel {
    public private(set) var items: [CaptureItem] = []
    public private(set) var totalBytes: Int64 = 0
    public var filter: HistoryQuery.KindFilter = .all {
        didSet { pruneSelection() }
    }
    public var searchText = "" {
        didSet { pruneSelection() }
    }
    public private(set) var selection: Set<String> = []
    /// The tile keys move from, and the end Shift extends to.
    public private(set) var focusID: String?
    public private(set) var anchorID: String?
    /// Grid columns at the current width; the view sets it.
    public var columns = 4
    /// The tile the view scrolls to, set by `reveal`.
    public private(set) var scrollTarget: String?
    /// Bumped by Cmd+F; the view focuses the search field when it changes.
    public private(set) var searchFocusRequest = 0
    public private(set) var loadError: String?
    /// How long screenshots are kept, for the subtitle, footer and empty states.
    public var retention: ScreenshotRetention = .thirtyDays
    /// The Capture Area shortcut for the empty state's key cap, nil when unset.
    public var captureAreaShortcut: String?

    @ObservationIgnored public var actions: HistoryActions
    /// Reduce Motion, read when a trash removes tiles (M28).
    @ObservationIgnored public var reduceMotion: @MainActor () -> Bool = { false }
    @ObservationIgnored public weak var previewer: (any HistoryPreviewing)?
    @ObservationIgnored private let load: @MainActor () throws -> HistorySnapshot
    @ObservationIgnored private let dateContext: @MainActor () -> HistoryDateContext

    public init(
        load: @escaping @MainActor () throws -> HistorySnapshot,
        context: @escaping @MainActor () -> HistoryDateContext,
        captureAreaShortcut: String? = "\u{21E7}\u{2318}4",
        actions: HistoryActions = HistoryActions(),
        previewer: (any HistoryPreviewing)? = nil
    ) {
        self.load = load
        self.dateContext = context
        self.captureAreaShortcut = captureAreaShortcut
        self.actions = actions
        self.previewer = previewer
    }

    // MARK: Loading

    /// Reads the folder again: on open, on becoming key and on the history-changed notification.
    /// Shows one capture from a Shelf search result: clears the search and the filter, selects
    /// it and asks the view to scroll to it. An unknown id selects nothing.
    public func reveal(_ id: String) {
        searchText = ""
        filter = .all
        guard items.contains(where: { $0.id == id }) else {
            clearSelection()
            scrollTarget = nil
            return
        }
        select(id)
        scrollTarget = id
    }

    public func reload() {
        do {
            let snapshot = try load()
            items = snapshot.items
            totalBytes = snapshot.totalBytes
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
        pruneSelection()
    }

    // MARK: Query and layout

    public var query: HistoryQuery { HistoryQuery(kind: filter, text: searchText) }
    public var context: HistoryDateContext { dateContext() }

    public var sections: [HistoryDaySection] {
        let context = context
        return HistoryQuery.group(query.filter(items, context: context), context: context)
    }

    /// Ids in display order: day by day, newest first.
    public var orderedIDs: [String] { sections.flatMap { $0.items.map(\.id) } }

    /// The grid as rows of ids, section by section, at the current column count.
    public var rows: [[String]] {
        let columns = max(columns, 1)
        return sections.flatMap { section in
            stride(from: 0, to: section.items.count, by: columns).map { start in
                section.items[start..<min(start + columns, section.items.count)].map(\.id)
            }
        }
    }

    /// Columns of 164 pt tiles with 16 pt gaps inside 28 pt side padding: four at 760 pt.
    nonisolated public static func columns(forWidth width: Double) -> Int {
        let tile = Theme.History.tileSize.width
        let gap = Theme.History.columnGap
        let usable = width - 2 * Theme.History.sidePadding + gap
        return max(Int((usable / (tile + gap)).rounded(.down)), 1)
    }

    public var content: HistoryContent {
        if items.isEmpty { return .empty }
        if !orderedIDs.isEmpty { return .grid }
        if query.isSearching { return .noResults(searchText.trimmingCharacters(in: .whitespaces)) }
        return .emptyFilter(filter)
    }

    public func item(_ id: String) -> CaptureItem? { items.first { $0.id == id } }

    // MARK: Footer

    /// `12 captures`, `41 MB`, `kept for 3 days`; the size is left out when there is nothing.
    public var footerParts: [String] {
        let count = items.count
        var parts = ["\(count) \(count == 1 ? "capture" : "captures")"]
        if count > 0 { parts.append(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) }
        parts.append(HistoryCopy.footerKept(retention))
        return parts
    }

    public var canPin: Bool { isEnabled(.pin) }
    public var canCopy: Bool { isEnabled(.copy) }
    public var canShowInQuickAccess: Bool { isEnabled(.showInQuickAccess) }

    // MARK: Selection

    /// Selected items in display order.
    public var selectedItems: [CaptureItem] {
        orderedIDs.filter(selection.contains).compactMap(item)
    }

    public func isSelected(_ id: String) -> Bool { selection.contains(id) }

    public func select(_ id: String, mode: HistorySelectMode = .replace) {
        guard orderedIDs.contains(id) else { return }
        switch mode {
        case .replace:
            selection = [id]
            anchorID = id
        case .toggle:
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
        case .extend:
            let anchor = anchorID.flatMap { orderedIDs.contains($0) ? $0 : nil } ?? id
            selection = Set(range(from: anchor, to: id))
            anchorID = anchor
        }
        focusID = id
    }

    public func selectAll() {
        selection = Set(orderedIDs)
        anchorID = orderedIDs.first
        focusID = orderedIDs.last
    }

    public func clearSelection() {
        selection = []
        anchorID = nil
        focusID = nil
    }

    /// Arrow keys: left and right in display order, up and down by grid row across sections.
    public func move(_ direction: HistoryDirection, extend: Bool = false) {
        let ordered = orderedIDs
        guard !ordered.isEmpty else { return }
        guard let focus = focusID, ordered.contains(focus) else {
            select(ordered[0])
            return
        }
        let target: String
        switch direction {
        case .left, .right:
            guard let index = ordered.firstIndex(of: focus) else { return }
            let next = direction == .left ? index - 1 : index + 1
            target = ordered[min(max(next, 0), ordered.count - 1)]
        case .up, .down:
            let rows = rows
            guard let row = rows.firstIndex(where: { $0.contains(focus) }),
                  let column = rows[row].firstIndex(of: focus) else { return }
            let next = direction == .up ? row - 1 : row + 1
            guard rows.indices.contains(next) else { return }
            target = rows[next][min(column, rows[next].count - 1)]
        }
        select(target, mode: extend ? .extend : .replace)
    }

    private func range(from anchor: String, to id: String) -> [String] {
        let ordered = orderedIDs
        guard let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: id) else { return [id] }
        return Array(ordered[min(start, end)...max(start, end)])
    }

    /// Keeps the selection to what is listed after a reload, a filter or a search.
    private func pruneSelection() {
        let visible = Set(orderedIDs)
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
        if let focus = focusID, !visible.contains(focus) { focusID = nil }
        if let anchor = anchorID, !visible.contains(anchor) { anchorID = nil }
    }

    // MARK: Commands

    /// Interrupted recordings offer Reveal and Move to Trash only (design 20.4); recordings cannot
    /// be pinned or annotated; Annotate takes one capture.
    public func isEnabled(_ command: HistoryCommand, for items: [CaptureItem]? = nil) -> Bool {
        let items = items ?? selectedItems
        guard !items.isEmpty else { return false }
        let complete = items.allSatisfy { $0.state == .complete }
        switch command {
        case .reveal, .trash: return true
        case .showInQuickAccess, .copy, .quickLook: return complete
        case .pin: return complete && items.allSatisfy { $0.kind == .image } && items.count <= PinBoard.capacity
        case .annotate: return complete && items.count == 1 && items[0].kind == .image
        }
    }

    public func perform(_ command: HistoryCommand) {
        let selected = selectedItems
        guard isEnabled(command, for: selected) else { return }
        switch command {
        case .showInQuickAccess: actions.showInQuickAccess(selected)
        case .copy: _ = actions.copy(selected)
        case .pin: actions.pin(selected)
        case .annotate: actions.annotate(selected[0])
        case .reveal: actions.reveal(selected)
        case .trash:
            let trashed = actions.trash(selected.map(\.id))
            guard !trashed.isEmpty else { return }
            // M28: the trashed tiles leave with their own removal transition; the rest spring.
            withAnimation(HistoryMotion.reflow(reduceMotion: reduceMotion())) {
                items.removeAll { trashed.contains($0.id) }
            }
            pruneSelection()
            reload()
        case .quickLook:
            let urls = selected.map(Self.previewURL)
            let index = focusID.flatMap { focus in selected.firstIndex { $0.id == focus } } ?? 0
            previewer?.preview(urls, selectedIndex: index)
        }
    }

    /// The file Quick Look and drag-out use: the current PNG, or a recording's mp4.
    public static func previewURL(_ item: CaptureItem) -> URL {
        item.kind == .video ? item.originalURL : item.currentURL
    }

    /// Files a tile drag carries: every selected item when the dragged tile is selected.
    public func dragURLs(for id: String) -> [URL] {
        let dragged = selection.contains(id) ? selectedItems : item(id).map { [$0] } ?? []
        return dragged.map(Self.previewURL)
    }

    /// Double-click: shows the item's card again.
    public func open(_ id: String) {
        select(id)
        perform(.showInQuickAccess)
    }

    /// The context menu of a tile; a right-click on an unselected tile selects it first.
    public func contextMenu(for id: String) -> [HistoryMenuRow] {
        if !selection.contains(id) { select(id) }
        let order: [HistoryCommand] = [.showInQuickAccess, .copy, .pin, .annotate, .reveal, .trash]
        return order.map { command in
            HistoryMenuRow(command: command, isEnabled: isEnabled(command), separatorBefore: command == .trash || command == .reveal)
        }
    }

    // MARK: Search and keys

    public func clearSearch() { searchText = "" }

    public func focusSearch() { searchFocusRequest += 1 }

    /// A key in the window, outside the search field; true when handled.
    @discardableResult
    public func handle(_ key: HistoryKey) -> Bool {
        switch key {
        case .showInQuickAccess:
            guard canShowInQuickAccess else { return false }
            perform(.showInQuickAccess)
        case .quickLook:
            guard isEnabled(.quickLook) else { return false }
            perform(.quickLook)
        case .copy:
            guard canCopy else { return false }
            perform(.copy)
        case .pin:
            guard canPin else { return false }
            perform(.pin)
        case .trash:
            guard isEnabled(.trash) else { return false }
            perform(.trash)
        case .focusSearch: focusSearch()
        case .clearSearch:
            guard !searchText.isEmpty else { return false }
            clearSearch()
        case .selectAll: selectAll()
        case .move(let direction, let extend): move(direction, extend: extend)
        }
        return true
    }
}

// MARK: Window

/// The capture history window (design 20.3, D52): a standard titled window, one instance, 760 x
/// 560 by default, minimum 560 x 400. It activates Snap because the user opened it and it has a
/// search field. Made on the first `show()`, never in tests or shot mode.
public final class HistoryWindowController: NSObject, NSWindowDelegate {
    /// Posted in-process when a capture is stored, edited, swept or trashed; the window reloads.
    public static let historyDidChange = Notification.Name("dev.sdusteric.snap.historyDidChange")

    public let model: HistoryWindowModel
    private let thumbnails: any HistoryThumbnailProviding
    private let frameChanged: @MainActor (CGRect) -> Void
    private var initialFrame: CGRect?
    private var window: HistoryWindow?
    private let previewer = QuickLookPreviewer()
    private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - frame: the autosaved frame from `state.json`, `NSScreen` coordinates.
    ///   - frameChanged: stores the frame after a move or resize.
    public init(
        model: HistoryWindowModel,
        thumbnails: any HistoryThumbnailProviding = ThumbnailCache(),
        frame: CGRect? = nil,
        frameChanged: @escaping @MainActor (CGRect) -> Void = { _ in }
    ) {
        self.model = model
        self.thumbnails = thumbnails
        self.initialFrame = frame
        self.frameChanged = frameChanged
        super.init()
        model.previewer = previewer
        model.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        model.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func close() {
        window?.close()
    }

    private func makeWindow() -> HistoryWindow {
        let size = Theme.History.windowSize
        let window = HistoryWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "History"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the 52 pt title bar the SwiftUI toolbar row sits in.
        window.toolbar = NSToolbar(identifier: "history")
        window.toolbarStyle = .unified
        window.contentMinSize = Theme.History.minimumSize
        window.isReleasedWhenClosed = false
        window.model = model
        window.previewer = previewer
        window.delegate = self
        window.contentView = NSHostingView(rootView: HistoryView(model: model, thumbnails: thumbnails))
        if let frame = initialFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        observer = NotificationCenter.default.addObserver(
            forName: Self.historyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.model.reload()
            }
        }
        return window
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }

    public func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame { frameChanged(frame) }
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        if let frame = window?.frame { frameChanged(frame) }
    }
}

/// Routes the grid keys to the model when the search field is not editing, and takes Quick Look
/// panel control for the selection.
final class HistoryWindow: NSWindow {
    weak var model: HistoryWindowModel?
    weak var previewer: QuickLookPreviewer?

    override func keyDown(with event: NSEvent) {
        if !(firstResponder is NSText), let model,
           let key = HistoryKey(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags),
           model.handle(key) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let model,
           let key = HistoryKey(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags) {
            switch key {
            case .focusSearch:
                return model.handle(key)
            case .copy, .trash, .selectAll:
                // Inside the search field these keys belong to the text.
                if !(firstResponder is NSText), model.handle(key) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let model, !model.searchText.isEmpty {
            model.clearSearch()
        } else {
            super.cancelOperation(sender)
        }
    }

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel?) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
        MainActor.assumeIsolated { panel?.dataSource = previewer }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
        MainActor.assumeIsolated { panel?.dataSource = nil }
    }
}

/// Quick Look through the shared `QLPreviewPanel` (design 20.3, M26: the system's own zoom).
public final class QuickLookPreviewer: NSObject, HistoryPreviewing, QLPreviewPanelDataSource {
    // The panel asks from its own callbacks, which are not main-actor isolated in the SDK.
    private let urls = Mutex<[URL]>([])

    public func preview(_ urls: [URL], selectedIndex: Int) {
        self.urls.withLock { $0 = urls }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(selectedIndex, 0), max(urls.count - 1, 0))
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        urls.withLock { $0.count }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        let url = urls.withLock { $0.indices.contains(index) ? $0[index] : nil }
        return url.map { $0 as NSURL }
    }
}
