import AppKit
import SnapCore
import SwiftUI

/// The history window's content (design 20.3, mockup 9): the 52 pt toolbar (title, subtitle, kind
/// filter, search), day sections of tiles, the empty and no-results states, and the 48 pt footer
/// with counts, size and the Pin, Copy and Show in Quick Access buttons. Selection, search and
/// filter change at once (M26); a trashed tile fades and shrinks while the rest spring (M28).
public struct HistoryView: View {
    @Bindable var model: HistoryWindowModel
    let thumbnails: any HistoryThumbnailProviding
    /// Shots draw the traffic lights the real window's title bar provides.
    let drawsTrafficLights: Bool
    /// False in shots: tiles get no AppKit event layer.
    let interactive: Bool

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: HistoryWindowModel,
        thumbnails: any HistoryThumbnailProviding,
        drawsTrafficLights: Bool = false,
        interactive: Bool = true
    ) {
        self.model = model
        self.thumbnails = thumbnails
        self.drawsTrafficLights = drawsTrafficLights
        self.interactive = interactive
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            hairline
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            hairline
            footer
        }
        .background(Theme.Colors.desk.color)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.Colors.deskSeparator.color).frame(height: 1)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.History.toolbarSpacing) {
            if drawsTrafficLights {
                HStack(spacing: 8) {
                    ForEach([UInt32(0xFF5F57), 0xFEBC2E, 0x28C840], id: \.self) { hex in
                        Circle().fill(Color(nsColor: ThemeRGBA(hex: hex).nsColor)).frame(width: 12, height: 12)
                    }
                }
            } else {
                Color.clear.frame(width: 52, height: 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(Theme.History.titleStyle.font)
                    .foregroundStyle(Theme.Colors.deskText.color)
                Text(HistoryCopy.subtitle(model.retention))
                    .font(Theme.History.subtitleStyle.font)
                    .foregroundStyle(Theme.Colors.deskText2.color)
            }
            .padding(.leading, Theme.History.titleLeadingInset)
            Spacer(minLength: 0)
            HistoryFilterControl(selection: $model.filter)
            searchField
        }
        .padding(.horizontal, 18)
        // The hairline under it is part of the 52 pt.
        .frame(height: Theme.History.toolbarHeight - 1)
        .background(Theme.Colors.deskBar.color)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.deskText2.color)
            TextField("Search by app or date", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body.font)
                .focused($searchFocused)
                .onExitCommand { model.clearSearch() }
        }
        .padding(.horizontal, 9)
        .frame(width: Theme.History.searchFieldSize.width, height: Theme.History.searchFieldSize.height)
        .background(
            RoundedRectangle(cornerRadius: Theme.History.searchFieldRadius, style: .continuous)
                .fill(Theme.Colors.deskFill.color)
        )
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.content {
        case .grid:
            grid
        case .empty:
            emptyState
        case .noResults(let text):
            message(
                symbol: "magnifyingglass", title: "No captures match \u{201C}\(text)\u{201D}", text: nil,
                button: ("Clear Search", { model.clearSearch() })
            )
        case .emptyFilter(let filter):
            message(
                symbol: filter == .videos ? "record.circle" : "photo",
                title: HistoryCopy.filterEmpty(videos: filter == .videos, model.retention),
                text: nil, button: nil
            )
        }
    }

    private var grid: some View {
        let context = model.context
        let columns = max(model.columns, 1)
        return ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.sections) { section in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(section.title)
                            .font(Theme.History.sectionHeadingStyle.font)
                            .foregroundStyle(Theme.Colors.deskText.color)
                        Text("\(section.items.count)")
                            .font(Theme.History.sectionCountStyle.font)
                            .foregroundStyle(Theme.Colors.deskText2.color)
                            .padding(.horizontal, Theme.History.sectionCountPadding)
                            .background(Capsule().fill(Theme.Colors.deskFill.color))
                    }
                    .padding(.top, Theme.History.sectionTopSpacing)
                    .padding(.bottom, Theme.History.sectionBottomSpacing)
                    // One layout per section, so a tile keeps its identity when a trash moves it to
                    // another row and can spring there (M28).
                    HistoryTileGrid(columns: columns) {
                        ForEach(section.items) { item in
                            tile(item, context: context)
                                .id(item.id)
                                .transition(HistoryMotion.tileRemoval(reduceMotion: reduceMotion))
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.History.sidePadding)
            .padding(.top, Theme.History.bodyTopPadding)
            .padding(.bottom, Theme.History.sectionTopSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        // A Shelf search result: jump to the tile, no animation.
        .onChange(of: model.scrollTarget, initial: true) { _, target in
            if let target { proxy.scrollTo(target, anchor: .center) }
        }
        }
        .onGeometryChange(for: Int.self) { proxy in
            HistoryWindowModel.columns(forWidth: proxy.size.width)
        } action: { columns in
            if model.columns != columns { model.columns = columns }
        }
    }

    private func tile(_ item: CaptureItem, context: HistoryDateContext) -> some View {
        let id = item.id
        let handler = interactive ? HistoryTileHandler(
            select: { [model] mode in model.select(id, mode: mode) },
            open: { [model] in model.open(id) },
            dragURLs: { [model] in model.dragURLs(for: id) },
            menu: { [model] in model.contextMenu(for: id) },
            perform: { [model] command in model.perform(command) }
        ) : nil
        return HistoryTile(
            item: item, time: context.timeText(for: item.createdAt), isSelected: model.isSelected(id),
            thumbnails: thumbnails, handler: handler
        )
    }

    // MARK: Empty states

    private var emptyState: some View {
        message(symbol: "clock.arrow.circlepath", title: HistoryCopy.emptyTitle(model.retention), text: emptyText, button: nil)
    }

    /// The shortcut is a key cap, the real current one, or the menu item when it is unset.
    private var emptyText: AttributedString {
        var text = AttributedString(HistoryCopy.emptyBody(model.retention))
        if let shortcut = model.captureAreaShortcut {
            text += AttributedString("Press ")
            var key = AttributedString("\u{2009}\(shortcut)\u{2009}")
            key.font = .system(size: 12, weight: .semibold)
            key.foregroundColor = Theme.Colors.deskText.color
            key.backgroundColor = Theme.Colors.deskFill.color
            text += key
            text += AttributedString(" to take one.")
        } else {
            text += AttributedString("Use Capture Area in the menu bar to take one.")
        }
        return text
    }

    private func message(symbol: String, title: String, text: AttributedString?, button: (String, () -> Void)?) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.Colors.deskText2.color)
                .frame(width: Theme.History.emptyIconSize, height: Theme.History.emptyIconSize)
                .background(
                    RoundedRectangle(cornerRadius: Theme.History.emptyIconRadius, style: .continuous)
                        .fill(Theme.Colors.deskFill.color)
                )
                .padding(.bottom, Theme.History.emptyIconGap)
            Text(title)
                .font(Theme.History.emptyTitleStyle.font)
                .foregroundStyle(Theme.Colors.deskText.color)
            if let text {
                Text(text)
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(Theme.Colors.deskText2.color)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Theme.Typography.body.lineSpacing)
                    .frame(maxWidth: Theme.History.emptyTextMaxWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.History.emptyTextGap)
            }
            if let button {
                Button(button.0, action: button.1)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.History.footerSpacing) {
            HStack(spacing: 7) {
                ForEach(Array(model.footerParts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Circle()
                            .fill(Theme.Colors.historyFooterDot.color)
                            .frame(width: Theme.History.footerDotSize, height: Theme.History.footerDotSize)
                    }
                    Text(part)
                }
            }
            .font(Theme.History.footerStyle.font)
            .foregroundStyle(Theme.Colors.deskText2.color)
            .lineLimit(1)
            Spacer(minLength: 0)
            if model.items.isEmpty {
                Button { model.actions.openFolder() } label: {
                    Label("Open Folder", systemImage: "folder")
                        .font(Theme.Typography.button.font)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.deskText2.color)
                .help("Open the history folder in Finder")
            } else {
                Button { model.actions.openFolder() } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.deskText2.color)
                .help("Open History Folder")
                .accessibilityLabel("Open History Folder")
                .padding(.trailing, Theme.Spacing.xxs)
                Button { model.perform(.pin) } label: {
                    Label("Pin", systemImage: "pin")
                }
                .disabled(!model.canPin)
                .help("Pin to Screen (P)")
                Button { model.perform(.copy) } label: {
                    Label("Copy", systemImage: "square.on.square")
                }
                .disabled(!model.canCopy)
                .help("Copy (\u{2318}C)")
                Button("Show in Quick Access") { model.perform(.showInQuickAccess) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.brand.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canShowInQuickAccess)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.leading, Theme.History.footerLeadingPadding)
        .padding(.trailing, Theme.History.footerTrailingPadding)
        .frame(height: Theme.History.footerHeight - 1)
        .background(Theme.Colors.deskBar.color)
    }
}

/// The kind filter, drawn as the mockup's segmented control (9): a `fill` track with radius 9 and
/// 2 pt padding, 22 pt segments with radius 7, the selected one raised.
struct HistoryFilterControl: View {
    @Binding var selection: HistoryQuery.KindFilter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 1) {
            ForEach(HistoryQuery.KindFilter.allCases, id: \.self) { filter in
                let selected = filter == selection
                Button { selection = filter } label: {
                    Text(filter.title)
                        .font(.system(size: Theme.Typography.caption.size, weight: selected ? .medium : .regular))
                        .foregroundStyle(Theme.Colors.deskText.color)
                        .padding(.horizontal, 10)
                        .frame(height: Theme.Controls.segmentedHeight)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Theme.HUD.segmentRadius, style: .continuous)
                                    .fill(Theme.Colors.deskGroup.color)
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 1, y: 1)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.HUD.segmentRadius, style: .continuous)
                                            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.1), lineWidth: 0.5)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Theme.HUD.segmentTrackRadius, style: .continuous)
                .fill(Theme.Colors.deskFill.color)
        )
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }
}

/// Tiles in rows of `columns`, 16 pt apart, rows 14 pt apart, from the top-left: the same places
/// the earlier rows of `HStack`s gave, with every tile a direct child so moves animate.
struct HistoryTileGrid: Layout {
    let columns: Int

    private func metrics(_ subviews: Subviews) -> (tile: CGSize, rows: Int, columns: Int) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let tile = CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
        let columns = max(min(self.columns, subviews.count), 1)
        return (tile, (subviews.count + columns - 1) / columns, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let (tile, rows, columns) = metrics(subviews)
        return CGSize(
            width: Double(columns) * tile.width + Double(columns - 1) * Theme.History.columnGap,
            height: Double(rows) * tile.height + Double(rows - 1) * Theme.History.rowGap
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let (tile, _, _) = metrics(subviews)
        let columns = max(self.columns, 1)
        for (index, subview) in subviews.enumerated() {
            let point = CGPoint(
                x: bounds.minX + Double(index % columns) * (tile.width + Theme.History.columnGap),
                y: bounds.minY + Double(index / columns) * (tile.height + Theme.History.rowGap)
            )
            subview.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(tile))
        }
    }
}

/// History motion (design 20.12 M26 and M28).
public enum HistoryMotion {
    /// M28: a trashed tile fades and shrinks to 0.96 over 120 ms on the exit curve; under Reduce
    /// Motion it only fades in 100 ms.
    public static func tileRemoval(reduceMotion: Bool) -> AnyTransition {
        let insertion = AnyTransition.identity
        guard !reduceMotion else {
            return .asymmetric(insertion: insertion, removal: .opacity.animation(.easeOut(duration: Theme.Motion.reducedMotionFade)))
        }
        return .asymmetric(
            insertion: insertion,
            removal: .opacity.combined(with: .scale(scale: Theme.Motion.historyTileExitScale))
                .animation(Theme.Motion.exit(Theme.Motion.historyTileExit))
        )
    }

    /// The tiles that stay move to their new places on the spring, or jump under Reduce Motion.
    public static func reflow(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Theme.Motion.spring
    }
}
