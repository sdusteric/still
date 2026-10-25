import AppKit
import SnapCore
import SwiftUI

/// What a tile's AppKit event layer calls.
struct HistoryTileHandler {
    var select: @MainActor (HistorySelectMode) -> Void
    var open: @MainActor () -> Void
    var dragURLs: @MainActor () -> [URL]
    var menu: @MainActor () -> [HistoryMenuRow]
    var perform: @MainActor (HistoryCommand) -> Void
}

/// One history tile (design 20.3, mockup 9): a 164 x 112 box on `thumbnailBacking` with the
/// current image aspect-fit, badges (duration, wand, Interrupted), the selection ring 4 pt
/// outside, and the caption with the time and the app.
struct HistoryTile: View {
    let item: CaptureItem
    let time: String
    let isSelected: Bool
    let thumbnails: any HistoryThumbnailProviding
    /// Nil in shots: the AppKit event layer cannot be drawn offscreen.
    let handler: HistoryTileHandler?

    @State private var loaded: CGImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.History.tileRadius, style: .continuous)
    }

    private var thumbnailURL: URL? { item.thumbnailURL }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.History.captionGap) {
            box
            caption
        }
        .frame(width: Theme.History.tileSize.width, alignment: .leading)
        .task(id: thumbnailURL) {
            guard let url = thumbnailURL, loaded == nil else { return }
            loaded = await thumbnails.thumbnail(for: url)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var image: CGImage? {
        loaded ?? thumbnailURL.flatMap { thumbnails.cachedThumbnail(for: $0) }
    }

    private var box: some View {
        let size = Theme.History.tileSize
        return ZStack {
            Theme.Colors.thumbnailBacking.color
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Theme.Colors.thumbnailStroke.color, lineWidth: Theme.History.tileStrokeWidth)
        }
        .overlay(alignment: .topLeading) {
            if item.isEdited && item.kind == .image {
                editedChip.padding(Theme.History.badgeInset)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Group {
                if item.state == .interrupted {
                    interruptedPill
                } else if item.kind == .video {
                    durationPill
                }
            }
            .padding(Theme.History.badgeInset)
        }
        .overlay {
            if isSelected {
                // The swatch ring rule (17.4): 2 pt accent, 4 pt outside the box. No animation (M26).
                let offset = Theme.History.selectionRingOffset
                RoundedRectangle(cornerRadius: Theme.History.tileRadius + offset - 1, style: .continuous)
                    .strokeBorder(Theme.Colors.accent.color, lineWidth: Theme.History.selectionRingWidth)
                    .padding(-offset)
            }
        }
        .overlay {
            if let handler {
                HistoryTileEventView(handler: handler, image: image)
            }
        }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Text(time)
                .font(Theme.History.captionTimeStyle.font)
                .foregroundStyle(Theme.Colors.text.color)
            Text(item.sourceApp ?? (item.kind == .video ? "Recording" : "Screenshot"))
                .font(Theme.History.captionAppStyle.font)
                .foregroundStyle(Theme.Colors.text2.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 2)
    }

    private var durationPill: some View {
        HStack(spacing: Theme.QuickAccessM2.durationPillSpacing) {
            Image(systemName: "play.fill")
                .font(.system(size: Theme.QuickAccessM2.durationGlyphSize, weight: .bold))
            Text(QuickAccessCardModel.durationText(item.durationSeconds ?? 0))
                .font(Theme.History.badgeStyle.font)
        }
        .foregroundStyle(Theme.Colors.chipText.color)
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .frame(height: Theme.History.durationPillHeight)
        .background(Capsule().fill(Theme.Colors.dimensionPill.color))
    }

    private var interruptedPill: some View {
        Text("Interrupted")
            .font(Theme.History.badgeStyle.font)
            .foregroundStyle(Theme.Colors.chipText.color)
            .padding(.horizontal, 7)
            .frame(height: Theme.History.durationPillHeight)
            .background(Capsule().fill(Theme.Colors.interruptedPill.color))
    }

    private var editedChip: some View {
        Image(systemName: "wand.and.sparkles")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Colors.chipText.color)
            .frame(width: Theme.History.editedChipSize, height: Theme.History.editedChipSize)
            .background(Circle().fill(Theme.Colors.chip.color))
            .overlay(Circle().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
    }

    private var accessibilityText: String {
        var parts = [item.kind == .video ? "Recording" : "Screenshot", time]
        if let app = item.sourceApp { parts.append(app) }
        if item.state == .interrupted { parts.append("Interrupted") }
        if item.isEdited { parts.append("Edited") }
        return parts.joined(separator: ", ")
    }
}

/// The tile's AppKit layer: click, Cmd-click and Shift-click select, a double-click shows the
/// card, a drag drags the file URLs with `.copy` (as the card does), a right-click opens the
/// context menu.
struct HistoryTileEventView: NSViewRepresentable {
    var handler: HistoryTileHandler
    var image: CGImage?

    func makeNSView(context: Context) -> HistoryTileEventSourceView {
        let view = HistoryTileEventSourceView()
        view.handler = handler
        view.image = image
        return view
    }

    func updateNSView(_ view: HistoryTileEventSourceView, context: Context) {
        view.handler = handler
        view.image = image
    }
}

final class HistoryTileEventSourceView: NSView, NSDraggingSource {
    var handler: HistoryTileHandler?
    var image: CGImage?
    private var downPoint: CGPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let handler else { return }
        if event.clickCount == 2 {
            handler.open()
            return
        }
        let flags = event.modifierFlags
        let mode: HistorySelectMode = flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .extend : .replace)
        handler.select(mode)
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !dragging, let handler else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= ThumbnailDragSourceView.decisionDistance else { return }
        dragging = true
        let urls = handler.dragURLs()
        guard !urls.isEmpty else { return }
        let dragImage = ThumbnailDragSourceView.dragImage(from: image, displaySize: bounds.size)
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: ThumbnailDragSourceView.pasteboardWriter(for: url))
            let offset = Double(index) * 4
            item.setDraggingFrame(
                CGRect(x: point.x - dragImage.size.width / 2 + offset, y: point.y - dragImage.size.height / 2 + offset,
                       width: dragImage.size.width, height: dragImage.size.height),
                contents: dragImage
            )
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
        dragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        ThumbnailDragSourceView.operationMask(for: context)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let handler else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in handler.menu() {
            if row.separatorBefore { menu.addItem(.separator()) }
            let item = HistoryMenuAction.item(row) { handler.perform($0) }
            menu.addItem(item)
        }
        return menu
    }
}

/// A context menu row as an `NSMenuItem` that runs one `HistoryCommand`.
final class HistoryMenuAction: NSObject {
    private let command: HistoryCommand
    private let run: @MainActor (HistoryCommand) -> Void

    private init(command: HistoryCommand, run: @escaping @MainActor (HistoryCommand) -> Void) {
        self.command = command
        self.run = run
    }

    @objc func fire(_ sender: Any?) { run(command) }

    static func item(_ row: HistoryMenuRow, run: @escaping @MainActor (HistoryCommand) -> Void) -> NSMenuItem {
        let action = HistoryMenuAction(command: row.command, run: run)
        let item = NSMenuItem(title: row.command.title, action: #selector(HistoryMenuAction.fire(_:)), keyEquivalent: "")
        if row.command == .trash {
            item.keyEquivalent = "\u{8}"
            item.keyEquivalentModifierMask = [.command]
        }
        item.target = action
        // The item holds its target weakly; keep the action alive as long as the item.
        item.representedObject = action
        item.isEnabled = row.isEnabled
        return item
    }
}
