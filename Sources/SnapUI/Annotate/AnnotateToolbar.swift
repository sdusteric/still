import AppKit
import Observation
import SnapCore
import SwiftUI

/// The nine tools with their keys (design sections 11 and 20.8). Pixelate is the first style of
/// Redact, and pressing P again cycles the styles.
public enum AnnotateTool: String, CaseIterable, Identifiable, Sendable {
    case select, crop, rectangle, arrow, text, highlight, redact, step, freehand

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        case .rectangle: "Rectangle"
        case .arrow: "Arrow"
        case .text: "Text"
        case .highlight: "Highlight"
        case .redact: "Redact"
        case .step: "Steps"
        case .freehand: "Freehand"
        }
    }

    /// The single key that picks the tool: V C R A T H P N F.
    public var key: String {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .rectangle: "r"
        case .arrow: "a"
        case .text: "t"
        case .highlight: "h"
        case .redact: "p"
        case .step: "n"
        case .freehand: "f"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redact: "text.redaction"
        case .step: "1.circle"
        case .freehand: "scribble"
        }
    }

    public init?(key: String) {
        guard let tool = AnnotateTool.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = tool
    }
}

extension RedactStyle {
    var symbol: String {
        switch self {
        case .pixelate: "squareshape.split.3x3"
        case .blur: "circle.grid.3x3"
        case .blackout: "rectangle.fill"
        }
    }

    /// The keys that reach the style: P once, twice or three times.
    var keyHint: String {
        switch self {
        case .pixelate: "P"
        case .blur: "P P"
        case .blackout: "P P P"
        }
    }
}

/// What the annotate editor asks the app to do. All injected, so the editor runs without the
/// pasteboard or the disk in tests and shots.
public struct AnnotateActions {
    /// Cmd+C: the flattened image for the clipboard.
    public var copy: (CGImage, Double) -> Void
    /// Cmd+S: writes the flattened image to the save folder and returns the file, nil on failure.
    public var save: (CGImage, Double) -> URL?
    /// Shift+Cmd+S: the save panel.
    public var saveAs: (CGImage, Double) -> Void
    /// Opens the Background editor on the flattened image.
    public var background: (CGImage, Double) -> Void
    /// The toast's Reveal link.
    public var reveal: (URL) -> Void
    /// Shown in the toast: "Saved to Downloads".
    public var saveFolderName: String
    /// The remembered highlight color and Redact style the editor starts with (design 20.8).
    public var settings: AnnotateSettings
    /// Called when the user changes the highlight color or the Redact style.
    public var settingsChanged: (AnnotateSettings) -> Void

    public init(
        copy: @escaping (CGImage, Double) -> Void = { _, _ in },
        save: @escaping (CGImage, Double) -> URL? = { _, _ in nil },
        saveAs: @escaping (CGImage, Double) -> Void = { _, _ in },
        background: @escaping (CGImage, Double) -> Void = { _, _ in },
        reveal: @escaping (URL) -> Void = { _ in },
        saveFolderName: String = "Downloads",
        settings: AnnotateSettings = AnnotateSettings(),
        settingsChanged: @escaping (AnnotateSettings) -> Void = { _ in }
    ) {
        self.copy = copy
        self.save = save
        self.saveAs = saveAs
        self.background = background
        self.reveal = reveal
        self.saveFolderName = saveFolderName
        self.settings = settings
        self.settingsChanged = settingsChanged
    }
}

/// Editor state shared by the toolbar and the canvas.
@MainActor
@Observable
public final class AnnotateEditorModel {
    /// Colors in the color well menu; the first is the default (`annotateRed`).
    public static let palette: [(name: String, color: RGBAColor)] = [
        ("Red", AnnotationItem.defaultColor),
        ("Orange", RGBAColor(hex: "#FF9F0A") ?? .black),
        ("Yellow", RGBAColor(hex: "#FFD60A") ?? .black),
        ("Green", RGBAColor(hex: "#30D158") ?? .black),
        ("Blue", RGBAColor(hex: "#0A84FF") ?? .black),
        ("Purple", RGBAColor(hex: "#BF5AF2") ?? .black),
        ("Black", .black),
        ("White", .white),
    ]

    /// Colors of the highlight well; the first is the default (#FFD60A).
    public static let highlightPalette: [(name: String, color: RGBAColor)] = [
        ("Yellow", AnnotateSettings.defaultHighlightColor),
        ("Green", RGBAColor(hex: "#30D158") ?? .black),
        ("Pink", RGBAColor(hex: "#FF375F") ?? .black),
        ("Orange", RGBAColor(hex: "#FF9F0A") ?? .black),
        ("Blue", RGBAColor(hex: "#64D2FF") ?? .black),
    ]

    public var tool: AnnotateTool = .rectangle {
        didSet {
            if tool != oldValue { onToolChange?(oldValue) }
        }
    }
    /// The highlight tool's own remembered color, so a red stroke color never makes it unreadable.
    public var highlightColor: RGBAColor = AnnotateSettings.defaultHighlightColor {
        didSet {
            guard highlightColor != oldValue else { return }
            onHighlightChange?()
            notifySettings()
        }
    }
    public var redactStyle: RedactStyle = .pixelate {
        didSet {
            guard redactStyle != oldValue else { return }
            onRedactStyleChange?()
            notifySettings()
        }
    }
    /// The Redact style menu is open.
    public var styleMenuOpen = false
    public var color: RGBAColor = AnnotationItem.defaultColor {
        didSet { onStyleChange?() }
    }
    public var strokeWidth: Double = AnnotationItem.defaultWidth {
        didSet { onStyleChange?() }
    }
    public internal(set) var canUndo = false
    public internal(set) var canRedo = false
    public internal(set) var zoomLabel = "Fit"

    @ObservationIgnored public var actions: AnnotateActions
    @ObservationIgnored var onToolChange: ((AnnotateTool) -> Void)?
    @ObservationIgnored var onStyleChange: (() -> Void)?
    @ObservationIgnored var onHighlightChange: (() -> Void)?
    @ObservationIgnored var onRedactStyleChange: (() -> Void)?
    @ObservationIgnored weak var canvas: AnnotateCanvasView?

    public init(actions: AnnotateActions = AnnotateActions()) {
        self.actions = actions
        highlightColor = actions.settings.highlightColor
        redactStyle = actions.settings.redactStyle
    }

    private func notifySettings() {
        actions.settingsChanged(AnnotateSettings(highlightColor: highlightColor, redactStyle: redactStyle))
    }

    /// A tool key or click. Pressing P with Redact already active cycles Pixelate, Blur, Black-out.
    public func pick(_ picked: AnnotateTool) {
        if picked == .redact, tool == .redact {
            redactStyle = redactStyle.next
        } else {
            tool = picked
        }
    }

    public func undo() { canvas?.undo() }
    public func redo() { canvas?.redo() }
    public func copy() { canvas?.copyImage() }
    public func save() { canvas?.saveImage() }
    public func background() { canvas?.openBackground() }
}

/// The unified 52 pt toolbar (design 17.6): tool group, color well, stroke popup, Undo and Redo,
/// then Background, Copy and Save on the trailing side. `leadingInset` leaves room for the
/// traffic lights when the toolbar sits in the title bar.
public struct AnnotateToolbar: View {
    @Bindable var model: AnnotateEditorModel
    var leadingInset: Double
    /// Nil inside an `NSToolbar`, which sets the height itself.
    var barHeight: Double?

    public init(model: AnnotateEditorModel, leadingInset: Double = 78, barHeight: Double? = Theme.Annotate.toolbarHeight) {
        self.model = model
        self.leadingInset = leadingInset
        self.barHeight = barHeight
    }

    public var body: some View {
        HStack(spacing: 10) {
            toolGroup
            if model.tool != .crop {
                divider
                optionsSlot
            }
            divider
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .disabled(!model.canUndo)
                .help("Undo (\u{2318}Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless)
                .disabled(!model.canRedo)
                .help("Redo (\u{21E7}\u{2318}Z)")
            Spacer(minLength: 12)
            Button { model.background() } label: { Label("Background", systemImage: "wand.and.sparkles") }
                .help("Open the Background editor on this image")
            Button { model.copy() } label: { Label("Copy", systemImage: "square.on.square") }
                .help("Copy (\u{2318}C)")
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .help("Save to \(model.actions.saveFolderName) (\u{2318}S)")
        }
        .font(Theme.Typography.body.font)
        .padding(.leading, leadingInset)
        .padding(.trailing, Theme.Spacing.m)
        .frame(height: barHeight.map { CGFloat($0) })
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colors.separatorStrong.color)
            .frame(width: 1, height: 18)
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(AnnotateTool.allCases) { tool in
                let selected = model.tool == tool
                Button {
                    model.pick(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(selected ? Theme.Colors.accentText.color : Theme.Colors.text.color)
                        .frame(width: Theme.Annotate.toolButtonSize.width, height: Theme.Annotate.toolButtonSize.height)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.Colors.button.color)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(tool.key.uppercased()))")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Colors.fill.color))
    }

    /// The active tool's options (design 20.8): stroke color and width, the highlight color, or the
    /// Redact style.
    @ViewBuilder private var optionsSlot: some View {
        switch model.tool {
        case .highlight:
            highlightWell
        case .redact:
            styleMenu
        case .select, .crop, .rectangle, .arrow, .text, .step, .freehand:
            colorWell
            strokeMenu
        }
    }

    private var highlightWell: some View {
        Menu {
            ForEach(AnnotateEditorModel.highlightPalette, id: \.name) { entry in
                Button {
                    model.highlightColor = entry.color
                } label: {
                    if entry.color == model.highlightColor {
                        Label(entry.name, systemImage: "checkmark")
                    } else {
                        Text(entry.name)
                    }
                }
            }
        } label: {
            Circle()
                .fill(model.highlightColor.swiftUIColor.opacity(AnnotationItem.highlightOpacity + 0.3))
                .overlay(Circle().strokeBorder(Theme.Colors.separatorStrong.color, lineWidth: 0.5))
                .frame(width: Theme.Annotate.colorWellSize, height: Theme.Annotate.colorWellSize)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Highlight color")
        .accessibilityLabel("Highlight color")
    }

    /// The Redact style popup: the current style's icon and name, and a menu of the three.
    private var styleMenu: some View {
        Button {
            model.styleMenuOpen.toggle()
        } label: {
            HStack(spacing: Theme.AnnotateM2.stylePopupSpacing) {
                Image(systemName: model.redactStyle.symbol).font(.system(size: 12))
                Text(model.redactStyle.title).font(Theme.Typography.caption.font)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.Colors.text.color)
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: Theme.Controls.popupHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Colors.button.color))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Colors.buttonEdge.color, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $model.styleMenuOpen, arrowEdge: .bottom) {
            RedactStyleMenu(model: model, framed: false)
        }
        .help("Redact style (P cycles)")
        .accessibilityLabel("Redact style: \(model.redactStyle.title)")
    }

    private var colorWell: some View {
        Menu {
            ForEach(AnnotateEditorModel.palette, id: \.name) { entry in
                Button {
                    model.color = entry.color
                } label: {
                    if entry.color == model.color {
                        Label(entry.name, systemImage: "checkmark")
                    } else {
                        Text(entry.name)
                    }
                }
            }
        } label: {
            Circle()
                .fill(model.color.swiftUIColor)
                .overlay(Circle().strokeBorder(Theme.Colors.separatorStrong.color, lineWidth: 0.5))
                .frame(width: Theme.Annotate.colorWellSize, height: Theme.Annotate.colorWellSize)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Color")
        .accessibilityLabel("Color")
    }

    private var strokeMenu: some View {
        Menu {
            ForEach(Theme.Annotate.strokeWidths, id: \.self) { width in
                Button {
                    model.strokeWidth = width
                } label: {
                    if width == model.strokeWidth {
                        Label("\(Int(width)) pt", systemImage: "checkmark")
                    } else {
                        Text("\(Int(width)) pt")
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: model.strokeWidth >= 7 ? .bold : model.strokeWidth >= 4 ? .semibold : .light))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Line width: \(Int(model.strokeWidth)) pt")
        .accessibilityLabel("Line width")
    }
}

/// The Redact style menu (mockup 12): the three styles with their keys and the line about
/// reversibility. Shown in a popover from the toolbar, and drawn framed over the canvas for the
/// shot, where no real menu can be opened.
struct RedactStyleMenu: View {
    @Bindable var model: AnnotateEditorModel
    /// Draws the menu's own background, edge and shadow (the shot).
    var framed: Bool

    static let note = "Black-out is the only style that cannot be reversed."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RedactStyle.allCases, id: \.self) { style in
                row(style)
            }
            Rectangle()
                .fill(Theme.Colors.separator.color)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            Text(Self.note)
                .font(Theme.AnnotateM2.styleMenuNoteStyle.font)
                .foregroundStyle(Theme.Colors.text2.color)
                .lineSpacing(Theme.AnnotateM2.styleMenuNoteStyle.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: Theme.AnnotateM2.styleMenuWidth, alignment: .leading)
        .background {
            if framed {
                // An opaque base under the menu tint, so the capture never shows through the text.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Colors.window.color)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Colors.menu.color))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.Colors.cardEdge.color, lineWidth: Theme.Materials.edgeWidth)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            }
        }
        .padding(framed ? Self.shadowInset : 0)
    }

    /// Room around a framed menu for its shadow.
    static let shadowInset = 20.0

    private func row(_ style: RedactStyle) -> some View {
        let selected = model.redactStyle == style
        return Button {
            model.redactStyle = style
            model.styleMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(style.title).font(Theme.Typography.body.font)
                Spacer(minLength: 8)
                Text(style.keyHint)
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.Colors.text2.color)
            }
            .foregroundStyle(selected ? Color.white : Theme.Colors.text.color)
            .padding(.horizontal, 8)
            .frame(height: Theme.Controls.buttonHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.Colors.accent.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
