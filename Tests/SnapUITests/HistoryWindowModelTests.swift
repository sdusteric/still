import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

@MainActor
final class RecordingPreviewer: HistoryPreviewing {
    var previews: [([URL], Int)] = []
    func preview(_ urls: [URL], selectedIndex: Int) { previews.append((urls, selectedIndex)) }
}

@MainActor
final class HistoryActionLog {
    var calls: [String] = []
    var trashable: Set<String> = []
    var removed: Set<String> = []

    func actions() -> HistoryActions {
        HistoryActions(
            showInQuickAccess: { items in self.calls.append("card " + items.map(\.id).joined(separator: ",")) },
            copy: { items in
                self.calls.append("copy " + items.map(\.id).joined(separator: ","))
                return true
            },
            pin: { items in self.calls.append("pin " + items.map(\.id).joined(separator: ",")) },
            annotate: { item in self.calls.append("annotate \(item.id)") },
            reveal: { items in self.calls.append("reveal " + items.map(\.id).joined(separator: ",")) },
            trash: { ids in
                self.calls.append("trash " + ids.joined(separator: ","))
                let moved = Set(ids).intersection(self.trashable)
                self.removed.formUnion(moved)
                return moved
            },
            openFolder: { self.calls.append("open folder") }
        )
    }
}

@MainActor
@Suite struct HistoryWindowModelTests {
    let log = HistoryActionLog()
    let previewer = RecordingPreviewer()
    /// Saturday 2026-10-24 14:05 UTC.
    let now = Date(timeIntervalSince1970: 1_792_850_700)
    let utc = TimeZone(identifier: "UTC") ?? .current

    func item(
        _ id: String, hoursAgo: Double, app: String = "Notes", kind: CaptureKind = .image,
        state: CaptureState = .complete, edited: Bool = false
    ) -> CaptureItem {
        let folder = URL(filePath: "/tmp/snap-history-test/\(id)", directoryHint: .isDirectory)
        return CaptureItem(
            id: id, createdAt: now.addingTimeInterval(-hoursAgo * 3600), mode: .area, scale: 2,
            originalURL: folder.appending(path: kind == .video ? "Snap \(id).mp4" : "Snap \(id).png"),
            editedURL: edited ? folder.appending(path: "Snap \(id) (edited).png") : nil,
            sourceApp: app, kind: kind, state: state, durationSeconds: kind == .video ? 42 : nil,
            posterURL: kind == .video ? folder.appending(path: "Snap \(id) poster.png") : nil
        )
    }

    /// Today: a (14:00 Notes), b (13:00 Safari, edited), c (11:00 video), d (09:00 Figma),
    /// e (08:00 Messages). Yesterday: f (20:05 interrupted video), g (10:05 Terminal).
    var fixture: [CaptureItem] {
        [
            item("a", hoursAgo: 0.08),
            item("b", hoursAgo: 1.08, app: "Safari", edited: true),
            item("c", hoursAgo: 3.08, app: "Terminal", kind: .video),
            item("d", hoursAgo: 5.08, app: "Figma"),
            item("e", hoursAgo: 6.08, app: "Messages"),
            item("f", hoursAgo: 18, app: "Safari", kind: .video, state: .interrupted),
            item("g", hoursAgo: 28, app: "Terminal"),
        ]
    }

    func makeModel(_ items: [CaptureItem]? = nil, bytes: Int64 = 41_000_000) async -> HistoryWindowModel {
        let items = items ?? fixture
        let now = now
        let utc = utc
        let log = log
        let model = HistoryWindowModel(
            load: { @MainActor in HistorySnapshot(items: items.filter { !log.removed.contains($0.id) }, totalBytes: bytes) },
            context: { HistoryDateContext(now: now, calendar: Calendar(identifier: .gregorian), timeZone: utc) },
            actions: log.actions(),
            previewer: previewer
        )
        await model.reload().value
        return model
    }

    // MARK: Sections and layout

    @Test func groupsByDayNewestFirstWithCounts() async {
        let model = await makeModel()
        #expect(model.sections.map(\.title) == ["Today", "Yesterday"])
        #expect(model.sections.map { $0.items.count } == [5, 2])
        #expect(model.orderedIDs == ["a", "b", "c", "d", "e", "f", "g"])
        #expect(model.content == .grid)
    }

    @Test func fourColumnsAtTheDefaultWidthAndMoreAsItGrows() async {
        #expect(HistoryWindowModel.columns(forWidth: 760) == 4)
        #expect(HistoryWindowModel.columns(forWidth: 560) == 2)
        #expect(HistoryWindowModel.columns(forWidth: 940) == 5)
        #expect(HistoryWindowModel.columns(forWidth: 100) == 1)
        let model = await makeModel()
        #expect(model.rows == [["a", "b", "c", "d"], ["e"], ["f", "g"]])
        model.columns = 2
        #expect(model.rows == [["a", "b"], ["c", "d"], ["e"], ["f", "g"]])
    }

    @Test func filterAndSearchNarrowTheListAndThePruneSelection() async {
        let model = await makeModel()
        model.select("a")
        model.filter = .videos
        #expect(model.orderedIDs == ["c", "f"])
        #expect(model.selection.isEmpty)
        model.filter = .all
        model.searchText = "safari yesterday"
        #expect(model.orderedIDs == ["f"])
        model.searchText = "safari"
        #expect(model.orderedIDs == ["b", "f"])
    }

    @Test func emptyNoResultsAndEmptyFilterStates() async {
        let empty = await makeModel([], bytes: 0)
        #expect(empty.content == .empty)
        #expect(empty.footerParts == ["0 captures", "screenshots kept for 30 days"])
        empty.retention = .threeDays
        #expect(empty.footerParts == ["0 captures", "kept for 3 days"])
        let model = await makeModel([item("a", hoursAgo: 1)])
        model.searchText = "  notes2 "
        #expect(model.content == .noResults("notes2"))
        model.clearSearch()
        model.filter = .videos
        #expect(model.content == .emptyFilter(.videos))
    }

    @Test func footerShowsCountSizeAndRetention() async {
        let model = await makeModel()
        let size = ByteCountFormatter.string(fromByteCount: 41_000_000, countStyle: .file)
        #expect(model.footerParts == ["7 captures", size, "screenshots kept for 30 days"])
        #expect(size.contains("41"))
        #expect(await makeModel([item("a", hoursAgo: 1)], bytes: 2048).footerParts.first == "1 capture")
    }

    // MARK: Selection

    @Test func clickCommandClickAndShiftClickSelect() async {
        let model = await makeModel()
        model.select("b")
        #expect(model.selection == ["b"])
        model.select("d", mode: .toggle)
        #expect(model.selection == ["b", "d"])
        model.select("b", mode: .toggle)
        #expect(model.selection == ["d"])
        model.select("a")
        model.select("e", mode: .extend)
        #expect(model.selection == ["a", "b", "c", "d", "e"])
        #expect(model.selectedItems.map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test func arrowsMoveAcrossTheGridAndSections() async {
        let model = await makeModel()
        model.move(.right)
        #expect(model.selection == ["a"])
        model.move(.right)
        #expect(model.selection == ["b"])
        model.move(.down)
        #expect(model.selection == ["e"])
        model.move(.down)
        #expect(model.selection == ["f"])
        model.select("d")
        model.move(.down)
        #expect(model.selection == ["e"])
        model.move(.up)
        #expect(model.selection == ["a"])
        model.move(.left)
        #expect(model.selection == ["a"])
        model.move(.right, extend: true)
        #expect(model.selection == ["a", "b"])
    }

    // MARK: Buttons, commands, menu

    @Test func buttonsAreDisabledWithNothingSelected() async {
        let model = await makeModel()
        #expect(!model.canPin && !model.canCopy && !model.canShowInQuickAccess)
        model.select("a")
        #expect(model.canPin && model.canCopy && model.canShowInQuickAccess)
    }

    @Test func recordingsCannotBePinnedAndInterruptedOnesOnlyRevealAndTrash() async {
        let model = await makeModel()
        model.select("c")
        #expect(!model.canPin && model.canCopy && model.canShowInQuickAccess)
        #expect(!model.isEnabled(.annotate))
        model.select("f")
        #expect(!model.canPin && !model.canCopy && !model.canShowInQuickAccess)
        let rows = model.contextMenu(for: "f")
        #expect(rows.filter(\.isEnabled).map(\.command) == [.reveal, .trash])
        #expect(rows.map(\.command) == [.showInQuickAccess, .copy, .pin, .annotate, .reveal, .trash])
    }

    @Test func returnShowsTheCardAndKeysRunCommands() async {
        let model = await makeModel()
        #expect(!model.handle(.showInQuickAccess))
        model.select("a")
        #expect(model.handle(.showInQuickAccess))
        #expect(model.handle(.copy))
        #expect(model.handle(.pin))
        model.open("c")
        #expect(log.calls == ["card a", "copy a", "pin a", "card c"])
        #expect(!model.handle(.pin))
    }

    @Test func spaceOpensQuickLookWithTheCurrentFiles() async {
        let model = await makeModel()
        model.select("b")
        model.select("c", mode: .toggle)
        #expect(model.handle(.quickLook))
        let preview = previewer.previews.first
        #expect(preview?.0.map(\.lastPathComponent) == ["Snap b (edited).png", "Snap c.mp4"])
        #expect(preview?.1 == 1)
    }

    @Test func contextMenuSelectsAnUnselectedTileFirst() async {
        let model = await makeModel()
        model.select("a")
        model.select("b", mode: .toggle)
        _ = model.contextMenu(for: "b")
        #expect(model.selection == ["a", "b"])
        _ = model.contextMenu(for: "d")
        #expect(model.selection == ["d"])
        model.perform(.annotate)
        #expect(log.calls == ["annotate d"])
    }

    @Test func trashRemovesTheItemsAndReloads() async {
        log.trashable = ["b"]
        let model = await makeModel()
        model.select("b")
        #expect(model.handle(.trash))
        #expect(log.calls == ["trash b"])
        #expect(!model.orderedIDs.contains("b"))
        #expect(model.selection.isEmpty)
    }

    @Test func trashedTilesLeaveOnTheExitCurveWhileTheRestSpring() async {
        #expect(HistoryMotion.reflow(reduceMotion: false) == Theme.Motion.spring)
        #expect(HistoryMotion.reflow(reduceMotion: true) == nil)
        #expect(Theme.Motion.historyTileExit == 0.120)
        #expect(Theme.Motion.historyTileExitScale == 0.96)
        log.trashable = ["a"]
        let model = await makeModel()
        var asked = 0
        model.reduceMotion = {
            asked += 1
            return true
        }
        model.select("a")
        #expect(model.handle(.trash))
        #expect(asked == 1)
        #expect(!model.orderedIDs.contains("a"))
    }

    @Test func theTileGridPlacesTilesInRowsWithTheDesignGaps() async throws {
        let tiles = (0..<6).map { index in
            Color.clear.frame(width: Theme.History.tileSize.width, height: 134).id(index)
        }
        let view = HistoryTileGrid(columns: 4) { ForEach(0..<6, id: \.self) { tiles[$0] } }
        let renderer = ImageRenderer(content: view)
        let image = try #require(renderer.cgImage)
        #expect(Double(image.width) == 4 * Theme.History.tileSize.width + 3 * Theme.History.columnGap)
        #expect(Double(image.height) == 2 * 134 + Theme.History.rowGap)
    }

    @Test func dragCarriesTheSelectionWhenTheDraggedTileIsSelected() async {
        let model = await makeModel()
        model.select("a")
        model.select("c", mode: .toggle)
        #expect(model.dragURLs(for: "c").map(\.lastPathComponent) == ["Snap a.png", "Snap c.mp4"])
        #expect(model.dragURLs(for: "d").map(\.lastPathComponent) == ["Snap d.png"])
    }

    @Test func searchKeysFocusAndClear() async {
        let model = await makeModel()
        #expect(model.handle(.focusSearch))
        #expect(model.searchFocusRequest == 1)
        #expect(!model.handle(.clearSearch))
        model.searchText = "notes"
        #expect(model.handle(.clearSearch))
        #expect(model.searchText.isEmpty)
        #expect(HistoryKey(characters: "f", keyCode: 3, modifiers: .command) == .focusSearch)
        #expect(HistoryKey(characters: nil, keyCode: 51, modifiers: .command) == .trash)
        #expect(HistoryKey(characters: nil, keyCode: 51, modifiers: []) == nil)
        #expect(HistoryKey(characters: "p", keyCode: 35, modifiers: []) == .pin)
        #expect(HistoryKey(characters: nil, keyCode: 125, modifiers: .shift) == .move(.down, extend: true))
    }

    // MARK: Shot scenes

    @Test func demoScenesRenderWithoutAWindow() async throws {
        let (model, _) = HistoryDemo.makeModel()
        #expect(model.sections.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(model.items.count == 12)
        #expect(model.selection.count == 1)
        #expect(model.items.contains { $0.state == .interrupted })
        #expect(model.items.contains { $0.isEdited })
        #expect(model.items.contains { $0.kind == .video && $0.state == .complete })
        let (empty, _) = HistoryDemo.makeModel(empty: true)
        #expect(empty.content == .empty)
        for isEmpty in [false, true] {
            let view = HistoryDemo.makeView(empty: isEmpty, dark: false)
            let image = try #require(OffscreenRender.cacheDisplay(view, scale: 2))
            #expect(image.width == 1520 && image.height == 1120)
        }
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }
}

extension HistoryWindowModelTests {
    @Test func revealSelectsAndClearsSearch() async {
        let model = await makeModel()
        model.searchText = "terminal"
        model.filter = .videos
        model.reveal("d")
        #expect(model.searchText.isEmpty)
        #expect(model.filter == .all)
        #expect(model.selection == ["d"])
        #expect(model.scrollTarget == "d")
    }

    @Test func revealUnknownIDSelectsNothing() async {
        let model = await makeModel()
        model.select("a")
        model.reveal("zzz")
        #expect(model.selection.isEmpty)
        #expect(model.scrollTarget == nil)
    }
}
