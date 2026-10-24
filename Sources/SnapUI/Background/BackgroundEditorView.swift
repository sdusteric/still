import AppKit
import Observation
import SnapCore
import SwiftUI

/// The four Background tabs (design 10.4).
public enum BackgroundTab: String, CaseIterable, Identifiable, Sendable {
    case gradient, color, image, none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gradient: "Gradient"
        case .color: "Color"
        case .image: "Image"
        case .none: "None"
        }
    }

    init(_ fill: BackgroundFill) {
        switch fill {
        case .gradient: self = .gradient
        case .solid: self = .color
        case .image: self = .image
        case .none: self = .none
        }
    }
}

/// What the editor asks the app to do. Every closure is injected, so the view runs in tests and
/// shots without touching the pasteboard, the disk or the preset file.
public struct BackgroundEditorActions {
    /// The full-size render for the clipboard. The editor closes after it.
    public var copy: (BeautifyRenderer.Output, BackgroundPreset) -> Void
    /// The full-size render for the save folder.
    public var save: (BeautifyRenderer.Output, BackgroundPreset) -> Void
    public var close: () -> Void
    /// A new or changed preset to store.
    public var savePreset: (BackgroundPreset) -> Void
    /// Star a preset as the default.
    public var setDefault: (String) -> Void
    public var deletePreset: (String) -> Void
    /// "Choose Image..." (`NSOpenPanel` in the app): the chosen path, or nil when cancelled.
    public var chooseImage: () -> String?

    public init(
        copy: @escaping (BeautifyRenderer.Output, BackgroundPreset) -> Void = { _, _ in },
        save: @escaping (BeautifyRenderer.Output, BackgroundPreset) -> Void = { _, _ in },
        close: @escaping () -> Void = {},
        savePreset: @escaping (BackgroundPreset) -> Void = { _ in },
        setDefault: @escaping (String) -> Void = { _ in },
        deletePreset: @escaping (String) -> Void = { _ in },
        chooseImage: @escaping () -> String? = { nil }
    ) {
        self.copy = copy
        self.save = save
        self.close = close
        self.savePreset = savePreset
        self.setDefault = setDefault
        self.deletePreset = deletePreset
        self.chooseImage = chooseImage
    }
}

/// State of the Background editor: the capture, the preset being edited and the live preview.
/// The preview is rendered by `BeautifyRenderer` at preview scale, at most once per run loop
/// turn however many controls change (design 10.4, M11).
@MainActor
@Observable
public final class BackgroundEditorModel {
    /// The preview area of a 920 x 640 window: the width left of the sidebar and the height above
    /// the caption, less 28 pt padding.
    public static let previewArea = CGSize(
        width: Theme.BackgroundEditor.windowSize.width - Theme.BackgroundEditor.sidebarWidth
            - 2 * Theme.BackgroundEditor.previewPadding,
        height: Theme.BackgroundEditor.windowSize.height - 2 * Theme.BackgroundEditor.previewPadding - 40
    )
    /// Preview pixels per point on screen.
    static let previewBackingScale = 2.0

    public let source: CGImage
    /// Pixels per point of `source`.
    public let scale: Double
    @ObservationIgnored let analysis: EdgeAnalysis?

    /// The values being edited. Every change schedules one preview render.
    public var preset: BackgroundPreset {
        didSet {
            if preset != oldValue { schedulePreview() }
        }
    }
    /// The stored presets, for the preset popup.
    public var presets: [BackgroundPreset]
    public var defaultPresetID: String
    /// The tab shown; follows `preset.background` and can sit on Image before a file is chosen.
    public var tab: BackgroundTab
    /// The colour of the custom colour well.
    public var customColor: RGBAColor

    public private(set) var preview: CGImage?
    public private(set) var previewScale: Double = 1
    /// The preview's size on screen: the canvas fitted into `previewArea`, never enlarged.
    public private(set) var previewDisplaySize = CGSize.zero
    /// Full-size geometry of the current preset, for the caption.
    public private(set) var geometry: BeautifyGeometry?
    public private(set) var errorMessage: String?

    @ObservationIgnored public var actions: BackgroundEditorActions
    @ObservationIgnored private var previewScheduled = false
    @ObservationIgnored private var lastGradient: GradientID
    @ObservationIgnored private var lastSolid: RGBAColor
    @ObservationIgnored private var lastImage: BackgroundFill?

    public init(
        source: CGImage,
        scale: Double,
        preset: BackgroundPreset,
        presets: [BackgroundPreset] = [BackgroundPreset.factoryDefault],
        defaultPresetID: String = BackgroundPreset.factoryID,
        actions: BackgroundEditorActions = BackgroundEditorActions()
    ) {
        self.source = source
        self.scale = scale > 0 ? scale : 1
        self.analysis = EdgeAnalysis.analyze(source)
        self.preset = preset
        self.presets = presets.isEmpty ? [preset] : presets
        self.defaultPresetID = defaultPresetID
        self.tab = BackgroundTab(preset.background)
        self.actions = actions
        var gradient = BackgroundFill.defaultGradient
        var solid = SolidSwatch.all.first { $0.name == "Snow" }?.color ?? .white
        switch preset.background {
        case .gradient(let id): gradient = id
        case .solid(let color): solid = color
        case .image: lastImage = preset.background
        case .none: break
        }
        lastGradient = gradient
        lastSolid = solid
        customColor = solid
        renderPreview()
    }

    // MARK: Derived

    public var isDefault: Bool { preset.id == defaultPresetID }

    /// The stored version of the preset being edited; Reset returns to it.
    public var storedPreset: BackgroundPreset {
        presets.first { $0.id == preset.id } ?? BackgroundPreset.factoryDefault
    }

    public var isModified: Bool { preset != storedPreset }

    /// `914 × 588 pt · 1828 × 1176 px`.
    public var caption: String {
        guard let geometry else { return "" }
        let points = "\(Int(geometry.canvasPoints.width.rounded())) \u{00D7} \(Int(geometry.canvasPoints.height.rounded())) pt"
        let pixels = "\(geometry.canvasSize.width) \u{00D7} \(geometry.canvasSize.height) px"
        return "\(points) \u{00B7} \(pixels)"
    }

    // MARK: Editing

    public func select(_ fill: BackgroundFill) {
        switch fill {
        case .gradient(let id): lastGradient = id
        case .solid(let color):
            lastSolid = color
            if !SolidSwatch.all.contains(where: { $0.color == color }) { customColor = color }
        case .image: lastImage = fill
        case .none: break
        }
        tab = BackgroundTab(fill)
        preset.background = fill
    }

    /// Switching tabs applies that tab's last choice; Image waits for a file when none was chosen.
    public func selectTab(_ newTab: BackgroundTab) {
        tab = newTab
        switch newTab {
        case .gradient: preset.background = .gradient(lastGradient)
        case .color: preset.background = .solid(lastSolid)
        case .image: if let lastImage { preset.background = lastImage }
        case .none: preset.background = .none
        }
    }

    public func chooseImage() {
        guard let path = actions.chooseImage() else { return }
        select(.image(path: path, blur: imageBlur))
    }

    public var imageBlur: Double {
        if case .image(_, let blur) = preset.background { return blur }
        return 0
    }

    public var imagePath: String? {
        if case .image(let path, _) = preset.background { return path }
        return nil
    }

    public func setImageBlur(_ blur: Double) {
        guard let path = imagePath else { return }
        select(.image(path: path, blur: min(max(blur, BackgroundPreset.blurRange.lowerBound), BackgroundPreset.blurRange.upperBound)))
    }

    public func setRatio(_ ratio: AspectRatio?) {
        preset.ratio = ratio
    }

    public func reset() {
        let stored = storedPreset
        preset = stored
        tab = BackgroundTab(stored.background)
    }

    // MARK: Presets

    public func selectPreset(id: String) {
        guard let stored = presets.first(where: { $0.id == id }) else { return }
        preset = stored
        tab = BackgroundTab(stored.background)
    }

    /// Stores the current values as a new preset named `name` and switches to it.
    public func saveAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var new = preset
        new.id = PresetStore.makeID()
        new.name = trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed
        presets.append(new)
        preset = new
        actions.savePreset(new)
    }

    /// Stores the current values into the selected preset and stars it.
    public func setAsDefault() {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        actions.savePreset(preset)
        defaultPresetID = preset.id
        actions.setDefault(preset.id)
    }

    public var canDeletePreset: Bool {
        presets.count > 1 && presets.contains { $0.id == preset.id }
    }

    public func deletePreset() {
        guard canDeletePreset else { return }
        let id = preset.id
        presets.removeAll { $0.id == id }
        actions.deletePreset(id)
        if defaultPresetID == id, let first = presets.first { defaultPresetID = first.id }
        selectPreset(id: defaultPresetID)
    }

    // MARK: Output

    /// The full-size render for Copy and Save.
    public func renderFull() -> BeautifyRenderer.Output? {
        do {
            if let analysis {
                return try BeautifyRenderer.render(source, scale: scale, preset: preset, analysis: analysis)
            }
            return try BeautifyRenderer.render(source, scale: scale, preset: preset)
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    public func copy() {
        guard let output = renderFull() else { return }
        actions.copy(output, preset)
        actions.close()
    }

    public func save() {
        guard let output = renderFull() else { return }
        actions.save(output, preset)
    }

    public func close() {
        actions.close()
    }

    // MARK: Preview

    private func schedulePreview() {
        guard !previewScheduled else { return }
        previewScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            previewScheduled = false
            renderPreview()
        }
    }

    /// Renders the preview now. The output scale fits the canvas into the preview area at 2x.
    public func renderPreview() {
        guard let analysis else {
            errorMessage = "The capture cannot be read."
            return
        }
        let full = BeautifyRenderer.geometry(
            width: source.width, height: source.height, scale: scale, preset: preset, analysis: analysis
        )
        geometry = full
        let area = Self.previewArea
        let fit = min(area.width / full.canvasPoints.width, area.height / full.canvasPoints.height, 1)
        let target = min(scale, Self.previewBackingScale * fit)
        do {
            let output = try BeautifyRenderer.render(
                source, scale: scale, preset: preset, outputScale: target, analysis: analysis
            )
            preview = output.image
            previewScale = target / fit
            previewDisplaySize = CGSize(width: full.canvasPoints.width * fit, height: full.canvasPoints.height * fit)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }
}

/// The Background editor content: live preview on the left, a 300 pt sidebar on the right
/// (design 10.4, 17.6, mockup section 3).
public struct BackgroundEditorView: View {
    @Bindable var model: BackgroundEditorModel
    @State private var naming = false
    @State private var newName = ""

    public init(model: BackgroundEditorModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            PreviewPane(model: model)
            Rectangle().fill(Theme.Colors.separator.color).frame(width: 1)
            sidebar
                .frame(width: Theme.BackgroundEditor.sidebarWidth - 1)
                .background(Theme.Colors.sidebar.color)
        }
        .background(Theme.Colors.sidebar.color)
        .frame(
            minWidth: Theme.BackgroundEditor.windowSize.width, maxWidth: .infinity,
            minHeight: Theme.BackgroundEditor.windowSize.height, maxHeight: .infinity
        )
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { model.saveAsPreset(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current background and spacing as a preset.")
        }
    }

    private var padding: NSEdgeInsets { Theme.BackgroundEditor.sidebarPadding }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    PresetPopup(model: model) {
                        newName = ""
                        naming = true
                    }
                    heading("Background")
                    backgroundSection
                    heading("Spacing")
                    spacingSection
                    heading("Canvas")
                    canvasSection
                }
                .frame(width: Theme.BackgroundEditor.sidebarWidth - 1 - padding.left - padding.right, alignment: .leading)
                .padding(.top, padding.top)
                .padding(.leading, padding.left)
                .padding(.trailing, padding.right)
                .padding(.bottom, padding.bottom)
            }
            .scrollBounceBehavior(.basedOnSize)
            Rectangle().fill(Theme.Colors.separator.color).frame(height: 1)
            footer
                .padding(.horizontal, padding.left)
                .padding(.vertical, Theme.Spacing.s)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.groupHeading.font)
            .foregroundStyle(Theme.Colors.text.color)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Background", selection: Binding(get: { model.tab }, set: { model.selectTab($0) })) {
                ForEach(BackgroundTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            switch model.tab {
            case .gradient:
                SwatchGrid(swatches: Swatch.gradients, selection: model.preset.background) { model.select($0) }
            case .color:
                SwatchGrid(
                    swatches: Swatch.solids, selection: model.preset.background,
                    onSelect: { model.select($0) },
                    customColor: Binding(
                        get: { model.customColor.swiftUIColor },
                        set: { model.select(.solid(RGBAColor($0))) }
                    )
                )
            case .image:
                imageControls
            case .none:
                Text("Transparent canvas, for pasting onto slides.")
                    .font(Theme.Typography.caption.font)
                    .foregroundStyle(Theme.Colors.text2.color)
                    .frame(height: 2 * Theme.Controls.swatchSize + Theme.Controls.swatchGap, alignment: .top)
            }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.imagePath.map { URL(filePath: $0).lastPathComponent } ?? "No image chosen")
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(model.imagePath == nil ? Theme.Colors.text2.color : Theme.Colors.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Choose Image\u{2026}") { model.chooseImage() }
            }
            SliderRow(
                title: "Blur", value: Binding(get: { model.imageBlur }, set: { model.setImageBlur($0) }),
                range: BackgroundPreset.blurRange
            )
            .disabled(model.imagePath == nil)
        }
        .frame(minHeight: 2 * Theme.Controls.swatchSize + Theme.Controls.swatchGap, alignment: .top)
    }

    // MARK: Spacing

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SliderRow(title: "Padding", value: $model.preset.padding, range: BackgroundPreset.paddingRange)
            SliderRow(title: "Inset", value: $model.preset.inset, range: BackgroundPreset.insetRange)
            SliderRow(
                title: "Corners",
                value: Binding(get: { model.preset.cornerRadius * 100 }, set: { model.preset.cornerRadius = $0 / 100 }),
                range: 0...100, percent: true
            )
            SliderRow(title: "Shadow", value: $model.preset.shadow, range: BackgroundPreset.shadowRange)
        }
    }

    // MARK: Canvas

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ratio").font(Theme.Typography.body.font)
                Spacer()
                Picker("Ratio", selection: ratioBinding) {
                    Text("Auto").tag("auto")
                    ForEach(AspectRatio.presets, id: \.label) { entry in
                        Text(entry.label).tag(entry.label)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack(alignment: .center) {
                Text("Align")
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(model.preset.ratio == nil ? Theme.Colors.text2.color : Theme.Colors.text.color)
                Spacer()
                AlignmentGrid(selection: $model.preset.alignment, isEnabled: model.preset.ratio != nil)
            }
            HStack {
                Text("Auto-balance").font(Theme.Typography.body.font)
                Spacer()
                Toggle("Auto-balance", isOn: $model.preset.autoBalance)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .help("Trims uneven blank margins so the content sits evenly on the card")
        }
    }

    private var ratioBinding: Binding<String> {
        Binding(
            get: {
                guard let ratio = model.preset.ratio else { return "auto" }
                return AspectRatio.presets.first { $0.ratio == ratio }?.label ?? "auto"
            },
            set: { label in
                model.setRatio(AspectRatio.presets.first { $0.label == label }?.ratio)
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Reset") { model.reset() }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.text2.color)
                .disabled(!model.isModified)
            Spacer()
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Copy") { model.copy() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            // Cmd+C copies and closes too; Esc closes.
            Button("") { model.copy() }
                .keyboardShortcut("c", modifiers: .command)
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Button("") { model.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .font(Theme.Typography.button.font)
    }
}

/// Label 54 pt, slider, 40 pt value field (design 17.6).
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Shows the value as a percentage ("12%").
    var percent = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.Typography.body.font)
                .frame(width: Theme.BackgroundEditor.sliderLabelWidth, alignment: .leading)
            Slider(value: $value, in: range)
                .labelsHidden()
                .accessibilityLabel(title)
            Group {
                if percent {
                    TextField(title, value: fractionValue, format: .percent.precision(.fractionLength(0)))
                } else {
                    TextField(title, value: clampedValue, format: .number.precision(.fractionLength(0)))
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(Theme.Typography.body.font.monospacedDigit())
            .frame(width: Theme.BackgroundEditor.sliderValueWidth)
        }
        .frame(height: 28)
    }

    /// The value as a fraction for the percent field: 12 shows as "12%".
    private var fractionValue: Binding<Double> {
        Binding(
            get: { value.rounded() / 100 },
            set: { value = min(max($0 * 100, range.lowerBound), range.upperBound) }
        )
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { value.rounded() },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

/// The preset popup at the top of the sidebar: star, name, "Default" (design 17.6).
private struct PresetPopup: View {
    let model: BackgroundEditorModel
    let onSaveAs: () -> Void

    var body: some View {
        Menu {
            ForEach(model.presets) { preset in
                Button {
                    model.selectPreset(id: preset.id)
                } label: {
                    if preset.id == model.preset.id {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
            Divider()
            Button("Save Preset\u{2026}", action: onSaveAs)
            Button("Set as Default") { model.setAsDefault() }
                .disabled(model.isDefault && !model.isModified)
            Button("Delete") { model.deletePreset() }
                .disabled(!model.canDeletePreset)
        } label: {
            HStack(spacing: 6) {
                if model.isDefault {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Colors.star.color)
                }
                Text(presetTitle).foregroundStyle(Theme.Colors.text.color)
                Spacer(minLength: 4)
                if model.isDefault {
                    Text("Default").foregroundStyle(Theme.Colors.text2.color)
                }
            }
            .font(Theme.Typography.body.font)
        }
        .menuStyle(.button)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Controls.popupFullWidthHeight)
        .accessibilityLabel("Preset")
    }

    /// The gradient's name stands in for a preset still called "Default", as in the mockup.
    private var presetTitle: String {
        let name = model.preset.name
        if name == "Default", case .gradient(let id) = model.preset.background { return id.displayName }
        return model.isModified ? "\(name) (edited)" : name
    }
}

/// The live preview on `canvas`, aspect-fit, with the size caption (design 17.6).
private struct PreviewPane: View {
    let model: BackgroundEditorModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                if let preview = model.preview {
                    Image(decorative: preview, scale: model.previewScale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: model.previewDisplaySize.width, height: model.previewDisplaySize.height)
                        .background {
                            if model.preset.background == .none { Checkerboard() }
                        }
                        .accessibilityLabel("Preview")
                } else if let message = model.errorMessage {
                    Text(message).font(Theme.Typography.body.font).foregroundStyle(Theme.Colors.text2.color)
                }
            }
            .frame(maxWidth: BackgroundEditorModel.previewArea.width, maxHeight: BackgroundEditorModel.previewArea.height)
            Spacer(minLength: 0)
            Text(model.caption)
                .font(Theme.Typography.caption.font.monospacedDigit())
                .foregroundStyle(Theme.Colors.text2.color)
        }
        .padding(Theme.BackgroundEditor.previewPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.canvas.color)
    }
}

/// The transparency checkerboard, shown only behind the None background.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell = 8.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var row = 0
            var y = 0.0
            while y < size.height {
                var x = row.isMultiple(of: 2) ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(white: 0.86)))
                    x += 2 * cell
                }
                y += cell
                row += 1
            }
        }
    }
}

// MARK: Demo

/// A sample capture for demos and shots: a notes window drawn in code, with transparent corners
/// like a window capture. Nothing from the screen.
public enum DemoCapture {
    public static let pointSize = CGSize(width: 842, height: 516)

    public static func notesWindow(dark: Bool, scale: Double = 2) -> CGImage? {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let context = SyntheticImages.makeContext(width: width, height: height) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(origin: .zero, size: pointSize)
        let background = dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white
        let sidebar = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.965, alpha: 1)
        let text = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.11, alpha: 1)
        let secondary = dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        let code = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.955, alpha: 1)

        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.clip()
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        context.setFillColor(sidebar.cgColor)
        context.fill(CGRect(x: 0, y: 34, width: 190, height: pointSize.height - 34))
        context.setFillColor((dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor)
        context.fill(CGRect(x: 0, y: 33.5, width: pointSize.width, height: 0.5))
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: 14 + Double(index) * 18, y: 11, width: 12, height: 12))
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        func draw(_ string: String, _ point: CGPoint, size: Double, weight: NSFont.Weight = .regular,
                  color: NSColor, mono: Bool = false) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
        }
        draw("Screenshots, the quiet way", CGPoint(x: 340, y: 9), size: 12, weight: .semibold, color: text)
        draw("Drafts", CGPoint(x: 16, y: 50), size: 10, weight: .semibold, color: secondary)
        let selected = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.35 : 0.18)
        context.setFillColor(selected.cgColor)
        context.fill(CGRect(x: 8, y: 66, width: 174, height: 22))
        draw("Screenshots, the quiet ...", CGPoint(x: 16, y: 69), size: 11, color: text)
        draw("Notes on a menu bar app", CGPoint(x: 16, y: 94), size: 11, color: secondary)
        draw("Why I stopped using pr...", CGPoint(x: 16, y: 116), size: 11, color: secondary)
        draw("Published", CGPoint(x: 16, y: 146), size: 10, weight: .semibold, color: secondary)
        draw("Moving off a subscription", CGPoint(x: 16, y: 166), size: 11, color: secondary)
        draw("A calmer download ma...", CGPoint(x: 16, y: 188), size: 11, color: secondary)

        draw("Screenshots, the quiet way", CGPoint(x: 220, y: 56), size: 22, weight: .semibold, color: text)
        draw("I take about a screenshot and a half a day. Most go straight into a chat or a draft, so the",
             CGPoint(x: 220, y: 98), size: 12, color: text)
        draw("tool should stay out of the way and leave the clipboard ready.", CGPoint(x: 220, y: 116), size: 12, color: text)
        context.setFillColor(code.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 220, y: 146, width: 590, height: 80), cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        draw("$ snapctl beautify shot.png --preset dusk", CGPoint(x: 232, y: 156), size: 10.5, color: secondary, mono: true)
        draw("padding 21  inset 21  corners 12%  shadow 32", CGPoint(x: 232, y: 172), size: 10.5, color: text, mono: true)
        draw("wrote shot (edited).png  1828 x 1176", CGPoint(x: 232, y: 188), size: 10.5, color: text, mono: true)
        draw("export SNAP_TOKEN=sk_4f9a81c2e07b3d", CGPoint(x: 232, y: 204), size: 10.5, color: text, mono: true)
        draw("The only edit I ever make is a gradient behind the window. That is one click now, and the",
             CGPoint(x: 220, y: 248), size: 12, color: text)
        draw("result is already on the clipboard.", CGPoint(x: 220, y: 266), size: 12, color: text)
        draw("What changed", CGPoint(x: 220, y: 298), size: 14, weight: .semibold, color: text)
        let bullets = [
            "Capture is instant and never takes focus from the app below.",
            "The card in the corner offers Background, Annotate and Save.",
            "Dragging the card into a chat attaches the file.",
        ]
        for (index, bullet) in bullets.enumerated() {
            draw("\u{2022}  " + bullet, CGPoint(x: 226, y: 326 + Double(index) * 20), size: 12, color: text)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// The Background editor with a sample capture and the default preset, for tests and shots.
public enum BackgroundEditorDemo {
    public static let size = Theme.BackgroundEditor.windowSize

    public static func makeModel(dark: Bool = false) -> BackgroundEditorModel? {
        guard let capture = DemoCapture.notesWindow(dark: dark) else { return nil }
        return BackgroundEditorModel(source: capture, scale: 2, preset: .factoryDefault)
    }

    /// The editor content in a hosting view of the window size, with the appearance set.
    public static func makeView(dark: Bool = false) -> NSView {
        let view: NSView
        if let model = makeModel(dark: dark) {
            view = NSHostingView(rootView: BackgroundEditorView(model: model))
        } else {
            view = NSView()
        }
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }
}
