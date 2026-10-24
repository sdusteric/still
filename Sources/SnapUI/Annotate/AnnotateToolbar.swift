import AppKit
import Observation
import SnapCore
import SwiftUI

/// The six M1 tools with their keys (design section 11).
public enum AnnotateTool: String, CaseIterable, Identifiable, Sendable {
    case select, crop, rectangle, arrow, text, pixelate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        case .rectangle: "Rectangle"
        case .arrow: "Arrow"
        case .text: "Text"
        case .pixelate: "Pixelate"
        }
    }

    /// The single key that picks the tool: V C R A T P.
    public var key: String {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .rectangle: "r"
        case .arrow: "a"
        case .text: "t"
        case .pixelate: "p"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        }
    }

    public init?(key: String) {
        guard let tool = AnnotateTool.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = tool
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

    public init(
        copy: @escaping (CGImage, Double) -> Void = { _, _ in },
        save: @escaping (CGImage, Double) -> URL? = { _, _ in nil },
        saveAs: @escaping (CGImage, Double) -> Void = { _, _ in },
        background: @escaping (CGImage, Double) -> Void = { _, _ in },
        reveal: @escaping (URL) -> Void = { _ in },
        saveFolderName: String = "Downloads"
    ) {
        self.copy = copy
        self.save = save
        self.saveAs = saveAs
        self.background = background
        self.reveal = reveal
        self.saveFolderName = saveFolderName
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

    public var tool: AnnotateTool = .rectangle {
        didSet {
            if tool != oldValue { onToolChange?(oldValue) }
        }
    }
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
    @ObservationIgnored weak var canvas: AnnotateCanvasView?

    public init(actions: AnnotateActions = AnnotateActions()) {
        self.actions = actions
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
            divider
            colorWell
            strokeMenu
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
            Button { model.background() } label: { Label("Background", systemImage: "wand.and.stars") }
                .help("Open the Background editor on this image")
            Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
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
                    model.tool = tool
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
