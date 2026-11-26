import AppKit
import Observation
import SnapCore
import SwiftUI

/// The annotate canvas (design 11, 17.6): the capture on `canvas`, the annotations, selection
/// handles, the crop overlay and the zoom pill, all drawn in `draw(_:)` (a layer background would
/// not show in `cacheDisplay`). Editing goes through `AnnotationDocument`; undo is an
/// `UndoManager` over document snapshots.
public final class AnnotateCanvasView: NSView {
    public enum Zoom: Equatable, Sendable {
        /// Fit the visible area, never above 100%.
        case fit
        /// View points per image point, 0.25 to 8.
        case scale(Double)
    }

    static let zoomRange = 0.25...8.0
    static let padding = 24.0
    static let handleHitRadius = 7.0
    static let cropDim = 0.5

    public private(set) var document: AnnotationDocument {
        didSet {
            pixelCache = pixelCache.filter { id, entry in
                document.item(id).map { $0.box == entry.box && $0.kind == entry.kind } ?? false
            }
            needsDisplay = true
        }
    }
    public internal(set) var selection: UUID? {
        didSet { needsDisplay = true }
    }
    public private(set) var zoom: Zoom = .fit {
        didSet {
            model.zoomLabel = zoomLabel
            needsDisplay = true
        }
    }
    /// The crop being edited while the Crop tool is active, in image points.
    public private(set) var cropDraft: CGRect?
    public let model: AnnotateEditorModel
    public let toast = ToastState()

    private let history = UndoManager()
    private var pan = CGPoint.zero
    private var drag: Drag = .none
    private var textOverlay: TextEditingOverlay?
    private var pixelCache: [UUID: (box: CGRect, kind: AnnotationKind, image: CGImage)] = [:]
    /// Where the current highlight drag started: Shift reshapes it around this point.
    private var dragPress = CGPoint.zero
    private let toastHost: NSHostingView<ToastView>

    private enum Drag {
        case none
        case creating(AnnotationItem)
        case moving(UUID, start: CGPoint, before: AnnotationDocument, original: AnnotationItem)
        case resizing(UUID, AnnotationHandle, before: AnnotationDocument)
        case cropNew(start: CGPoint)
        case cropMove(start: CGPoint, original: CGRect)
        case cropResize(AnnotationHandle, original: CGRect)
    }

    public init(document: AnnotationDocument, model: AnnotateEditorModel = AnnotateEditorModel()) {
        self.document = document
        self.model = model
        toastHost = NSHostingView(rootView: ToastView(state: toast))
        super.init(frame: CGRect(origin: .zero, size: Theme.Annotate.windowSize))
        history.levelsOfUndo = 200
        history.groupsByEvent = false
        model.canvas = self
        model.onToolChange = { [weak self] previous in self?.toolChanged(from: previous) }
        model.onStyleChange = { [weak self] in self?.applyStyleToSelection() }
        model.onHighlightChange = { [weak self] in self?.applyHighlightColorToSelection() }
        model.onRedactStyleChange = { [weak self] in self?.applyRedactStyleToSelection() }
        model.zoomLabel = zoomLabel
        toast.onReveal = { [weak self] url in self?.model.actions.reveal(url) }
        addSubview(toastHost)
        layoutToast()
        if model.tool == .crop { cropDraft = document.outputRect }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Annotated capture")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    override public var undoManager: UndoManager? { history }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutToast()
    }

    private func layoutToast() {
        let size = CGSize(width: 360, height: 56)
        toastHost.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 24,
                                 width: size.width, height: size.height)
    }

    // MARK: Layout

    /// The image region shown: the whole image while cropping, otherwise the crop.
    var visibleImageRect: CGRect {
        model.tool == .crop ? document.imageBounds : document.outputRect
    }

    /// View points per image point.
    public var displayScale: Double {
        switch zoom {
        case .scale(let value):
            return value
        case .fit:
            let visible = visibleImageRect
            let width = max(bounds.width - 2 * Self.padding, 1)
            let height = max(bounds.height - 2 * Self.padding, 1)
            return min(width / max(visible.width, 1), height / max(visible.height, 1), 1)
        }
    }

    /// Where the visible image region sits in the view.
    var imageFrame: CGRect {
        let visible = visibleImageRect
        let scale = displayScale
        let size = CGSize(width: visible.width * scale, height: visible.height * scale)
        return CGRect(
            x: ((bounds.width - size.width) / 2 + pan.x).rounded(),
            y: ((bounds.height - size.height) / 2 + pan.y).rounded(),
            width: size.width, height: size.height
        )
    }

    func viewPoint(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        let visible = visibleImageRect
        let scale = displayScale
        return CGPoint(x: frame.minX + (point.x - visible.minX) * scale, y: frame.minY + (point.y - visible.minY) * scale)
    }

    func imagePoint(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        let visible = visibleImageRect
        let scale = displayScale
        return CGPoint(x: visible.minX + (point.x - frame.minX) / scale, y: visible.minY + (point.y - frame.minY) / scale)
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        let origin = viewPoint(CGPoint(x: rect.minX, y: rect.minY))
        let scale = displayScale
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    public var zoomLabel: String {
        switch zoom {
        case .fit: "Fit"
        case .scale(let value): "\(Int((value * 100).rounded()))%"
        }
    }

    var zoomPillRect: CGRect {
        let size = CGSize(width: 56, height: 24)
        return CGRect(
            x: bounds.width - Theme.Annotate.zoomPillInset - size.width,
            y: bounds.height - Theme.Annotate.zoomPillInset - size.height,
            width: size.width, height: size.height
        )
    }

    // MARK: Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = ThemeColor.isDark(effectiveAppearance)
        context.setFillColor(Theme.Colors.canvas.cgColor(dark: dark))
        context.fill(bounds)

        let frame = imageFrame
        let scale = displayScale
        let visible = visibleImageRect

        // A soft drop shadow under the image, as in the mockup.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.18))
        context.setFillColor(CGColor(gray: dark ? 0.1 : 1, alpha: 1))
        context.fill(frame)
        context.restoreGState()

        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: frame.minX - visible.minX * scale, y: frame.minY - visible.minY * scale)
        context.scaleBy(x: scale, y: scale)
        drawImage(in: context, scale: scale)
        // Redactions sit on the base image and everything else above them, as in the export.
        for item in document.items where item.kind.isRedact {
            drawRedact(item, in: context)
        }
        let numbers = document.stepNumbers
        for item in document.items where !item.kind.isRedact && item.id != textOverlay?.itemID {
            AnnotationPainter.draw(item, number: numbers[item.id] ?? 1, in: context)
        }
        if case .creating(let item) = drag {
            if item.kind.isRedact {
                drawRedactPreview(item, in: context, scale: scale)
            } else {
                AnnotationPainter.draw(item, number: numbers.count + 1, in: context)
            }
        }
        context.restoreGState()

        if model.tool == .crop, let crop = cropDraft {
            drawCropOverlay(viewRect(crop), imageFrame: frame, in: context)
        } else if let id = selection, let item = document.item(id) {
            drawSelection(item, in: context)
        }
        drawZoomPill(in: context, dark: dark)
    }

    private func drawImage(in context: CGContext, scale: Double) {
        let bounds = document.imageBounds
        context.saveGState()
        context.interpolationQuality = scale * document.scale >= 2 ? .none : .high
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(document.image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    private func drawRedact(_ item: AnnotationItem, in context: CGContext) {
        let box = item.box.intersection(document.imageBounds)
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        if item.kind == .blackout {
            context.saveGState()
            context.setFillColor(Theme.Colors.blackout.cgColor(dark: false))
            context.fill(box)
            context.restoreGState()
            return
        }
        let mosaic: CGImage
        if let cached = pixelCache[item.id], cached.box == item.box, cached.kind == item.kind {
            mosaic = cached.image
        } else {
            let pixels = CGRect(
                x: box.minX * document.scale, y: box.minY * document.scale,
                width: box.width * document.scale, height: box.height * document.scale
            )
            let made = item.kind == .blur
                ? Flattener.blurred(document.image, region: pixels)
                : Flattener.pixelated(document.image, region: pixels)
            guard let image = made else { return }
            mosaic = image
            if document.item(item.id) != nil { pixelCache[item.id] = (item.box, item.kind, image) }
        }
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(mosaic, in: CGRect(origin: .zero, size: box.size))
        context.restoreGState()
    }

    /// While a redact region is being dragged: the pixelate mosaic live, a veil for blur and
    /// black-out (the effect appears when the region is committed).
    private func drawRedactPreview(_ item: AnnotationItem, in context: CGContext, scale: Double) {
        switch item.kind {
        case .pixelate:
            drawRedact(item, in: context)
        default:
            let box = item.box
            context.saveGState()
            context.setFillColor(CGColor(gray: item.kind == .blackout ? 0 : 1, alpha: item.kind == .blackout ? 0.55 : 0.3))
            context.fill(box)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / max(scale, 0.01))
            context.stroke(box)
            context.restoreGState()
        }
    }

    private func drawSelection(_ item: AnnotationItem, in context: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        if item.kind == .step {
            drawStepRing(item, in: context, accent: accent)
            return
        }
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(Theme.Annotate.selectionBorderWidth)
        let outset = selectionOutset(item)
        let outline = viewRect(item.kind == .text || item.kind == .freehand ? item.bounds : item.box)
            .insetBy(dx: -outset, dy: -outset)
        if item.kind != .arrow {
            context.stroke(outline)
        }
        for handle in item.handles {
            let point = item.kind == .arrow ? viewPoint(item.handlePoint(handle)) : handle.point(on: outline)
            drawHandle(at: point, in: context, accent: accent)
        }
        context.restoreGState()
    }

    /// A selected step shows a 1.5 pt accent ring 2.5 pt outside its circle (design 20.8).
    private func drawStepRing(_ item: AnnotationItem, in context: CGContext, accent: CGColor) {
        let circle = viewRect(item.box)
        let width = Theme.AnnotateM2.stepSelectionRingWidth
        let inset = -(Theme.AnnotateM2.stepSelectionRingOffset + width / 2)
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(width)
        context.strokeEllipse(in: circle.insetBy(dx: inset, dy: inset))
        context.restoreGState()
    }

    /// How far the selection outline sits outside an item, in view points: clear of a rectangle's
    /// stroke (mockup 4), so the accent line never covers the annotation color.
    private func selectionOutset(_ item: AnnotationItem) -> Double {
        let gap = 2.0
        return item.kind == .rectangle ? item.width * displayScale / 2 + gap : gap
    }

    private func drawHandle(at point: CGPoint, in context: CGContext, accent: CGColor) {
        let size = Theme.Annotate.handleSize
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: rect)
        context.setStrokeColor(accent)
        context.setLineWidth(Theme.Annotate.selectionBorderWidth)
        context.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
    }

    private func drawCropOverlay(_ crop: CGRect, imageFrame: CGRect, in context: CGContext) {
        context.saveGState()
        context.addRect(imageFrame)
        context.addRect(crop)
        context.setFillColor(CGColor(gray: 0, alpha: Self.cropDim))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1)
        context.stroke(crop.insetBy(dx: 0.5, dy: 0.5))
        let accent = NSColor.controlAccentColor.cgColor
        for handle in AnnotationHandle.boxHandles {
            drawHandle(at: handle.point(on: crop), in: context, accent: accent)
        }
        context.restoreGState()
    }

    private func drawZoomPill(in context: CGContext, dark: Bool) {
        let rect = zoomPillRect
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(gray: 0, alpha: 0.16))
        context.addPath(path)
        context.setFillColor(Theme.Colors.card.cgColor(dark: dark))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(Theme.Colors.cardEdge.cgColor(dark: dark))
        context.setLineWidth(Theme.Materials.edgeWidth)
        context.strokePath()
        context.restoreGState()

        let color = NSColor(cgColor: Theme.Colors.text.cgColor(dark: dark)) ?? .labelColor
        let text = NSAttributedString(string: zoomLabel, attributes: [
            .font: Theme.Typography.captionMedium.nsFont, .foregroundColor: color,
        ])
        let textSize = text.size()
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold).applying(.init(paletteColors: [color])))
        let chevronSize = chevron?.size ?? .zero
        let gap = 4.0
        let width = textSize.width + gap + chevronSize.width
        let originX = rect.midX - width / 2
        text.draw(at: CGPoint(x: originX, y: rect.midY - textSize.height / 2))
        // The view is flipped; the symbol must not come out pointing up.
        chevron?.draw(
            in: CGRect(
                x: originX + textSize.width + gap, y: rect.midY - chevronSize.height / 2,
                width: chevronSize.width, height: chevronSize.height
            ),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    // MARK: Tools and style

    private func toolChanged(from previous: AnnotateTool) {
        endTextEditing(commit: true)
        if model.tool == .crop {
            cropDraft = document.outputRect
            selection = nil
        } else {
            cropDraft = nil
        }
        if previous == .crop || model.tool == .crop { pan = .zero }
        needsDisplay = true
    }

    private func applyStyleToSelection() {
        guard let id = selection, var item = document.item(id) else { return }
        switch item.kind {
        case .rectangle, .arrow, .text, .step, .freehand: break
        case .pixelate, .blur, .blackout, .highlight: return
        }
        let before = document
        item.color = model.color
        if item.kind != .text { item.width = model.strokeWidth }
        var next = document
        next.update(item)
        apply(next, undoFrom: before, name: "Change Style")
    }

    private func applyHighlightColorToSelection() {
        guard let id = selection, var item = document.item(id), item.kind == .highlight else { return }
        let before = document
        item.color = model.highlightColor
        var next = document
        next.update(item)
        apply(next, undoFrom: before, name: "Change Highlight")
    }

    /// A selected redact region takes the new style (its kind changes, its box stays).
    private func applyRedactStyleToSelection() {
        guard let id = selection, var item = document.item(id), item.kind.isRedact,
              item.kind != model.redactStyle.kind else { return }
        let before = document
        item.kind = model.redactStyle.kind
        var next = document
        next.update(item)
        apply(next, undoFrom: before, name: "Change Redact Style")
    }

    // MARK: Undo

    private func apply(_ next: AnnotationDocument, undoFrom before: AnnotationDocument, name: String) {
        guard next != before else { return }
        document = next
        registerUndo(restoring: before, name: name)
        updateUndoState()
    }

    private func registerUndo(restoring snapshot: AnnotationDocument, name: String) {
        // Each edit is its own undo step, with or without a run loop turn between edits.
        let grouped = !history.isUndoing && !history.isRedoing
        if grouped { history.beginUndoGrouping() }
        defer { if grouped { history.endUndoGrouping() } }
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let current = target.document
                target.document = snapshot
                if let id = target.selection, snapshot.item(id) == nil { target.selection = nil }
                target.registerUndo(restoring: current, name: name)
                target.updateUndoState()
            }
        }
        history.setActionName(name)
    }

    private func updateUndoState() {
        model.canUndo = history.canUndo
        model.canRedo = history.canRedo
    }

    public func undo() {
        endTextEditing(commit: true)
        if history.canUndo { history.undo() }
        updateUndoState()
    }

    public func redo() {
        if history.canRedo { history.redo() }
        updateUndoState()
    }

    // MARK: Editing commands

    public func deleteSelection() {
        guard let id = selection else { return }
        var next = document
        next.delete(id)
        selection = nil
        apply(next, undoFrom: document, name: "Delete")
    }

    public func duplicateSelection() {
        guard let id = selection else { return }
        var next = document
        guard let copy = next.duplicate(id) else { return }
        apply(next, undoFrom: document, name: "Duplicate")
        selection = copy
    }

    public func nudgeSelection(dx: Int, dy: Int, large: Bool) {
        guard let id = selection else { return }
        var next = document
        next.nudge(id, dx: dx, dy: dy, large: large)
        apply(next, undoFrom: document, name: "Move")
    }

    /// Return in the Crop tool.
    public func applyCrop() {
        guard let draft = cropDraft else { return }
        var next = document
        next.crop(to: draft)
        apply(next, undoFrom: document, name: "Crop")
        model.tool = .select
    }

    /// Esc in the Crop tool.
    public func cancelCrop() {
        model.tool = .select
    }

    /// Adds `item` on top as one undoable step and selects it.
    public func addItem(_ item: AnnotationItem) {
        var next = document
        next.add(item)
        apply(next, undoFrom: document, name: "Add \(item.kind.rawValue.capitalized)")
        selection = item.id
    }

    public func setSelection(_ id: UUID?) {
        selection = id
    }

    public func toggleZoom() {
        zoom = zoom == .fit ? .scale(1) : .fit
        pan = .zero
    }

    // MARK: Output

    /// The document flattened at full resolution: crop applied, items burned in.
    public func flattened() -> CGImage? {
        endTextEditing(commit: true)
        do {
            return try Flattener.flatten(document)
        } catch {
            return nil
        }
    }

    public func copyImage() {
        guard let image = flattened() else { return }
        model.actions.keep(document)
        model.actions.copy(image, document.scale)
        toast.show("Copied", reveal: nil)
    }

    public func saveImage() {
        guard let image = flattened() else { return }
        model.actions.keep(document)
        if let url = model.actions.save(image, document.scale) {
            toast.show("Saved to \(model.actions.saveFolderName)", reveal: url)
        } else {
            toast.show("Could not save the image", reveal: nil)
        }
    }

    public func saveImageAs() {
        guard let image = flattened() else { return }
        model.actions.keep(document)
        model.actions.saveAs(image, document.scale)
    }

    public func openBackground() {
        guard let image = flattened() else { return }
        model.actions.keep(document)
        model.actions.background(image, document.scale)
    }

    // MARK: Mouse

    override public func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if zoomPillRect.contains(location) {
            toggleZoom()
            return
        }
        endTextEditing(commit: true)
        window?.makeFirstResponder(self)
        let point = imagePoint(location)
        let radius = Self.handleHitRadius / displayScale

        if model.tool == .crop {
            beginCropDrag(at: point, radius: radius)
            return
        }
        // Handles are drawn on the outset outline, so the hit radius grows by the outset.
        let handleRadius = radius + (selection.flatMap { document.item($0) }.map(selectionOutset) ?? 0) / displayScale
        if let id = selection, let handle = document.handle(of: id, at: point, radius: handleRadius) {
            drag = .resizing(id, handle, before: document)
            return
        }
        if model.tool == .text, event.clickCount >= 1, let id = document.hitTest(point, tolerance: radius),
           document.item(id)?.kind == .text {
            selection = id
            if event.clickCount >= 2 {
                beginTextEditing(existing: id)
            } else {
                drag = .moving(id, start: point, before: document, original: document.item(id) ?? .pixelate(.zero))
            }
            return
        }
        if let id = hitTestForTool(point, tolerance: radius), let item = document.item(id) {
            selection = id
            if event.clickCount >= 2, item.kind == .text {
                beginTextEditing(existing: id)
                return
            }
            drag = .moving(id, start: point, before: document, original: item)
            return
        }
        selection = nil
        switch model.tool {
        case .select, .crop:
            drag = .none
        case .rectangle:
            drag = .creating(AnnotationItem(
                kind: .rectangle, start: point, end: point, color: model.color, width: model.strokeWidth,
                filled: event.modifierFlags.contains(.option)
            ))
        case .arrow:
            drag = .creating(.arrow(from: point, to: point, color: model.color, width: model.strokeWidth))
        case .redact:
            drag = .creating(.redact(CGRect(origin: point, size: .zero), style: model.redactStyle))
        case .highlight:
            dragPress = point
            drag = .creating(.highlight(CGRect(origin: point, size: .zero), color: model.highlightColor))
        case .step:
            addItem(.step(at: point, color: model.color, width: model.strokeWidth))
        case .freehand:
            drag = .creating(.freehand([point], color: model.color, width: model.strokeWidth))
        case .text:
            beginTextEditing(newAt: point)
        }
    }

    /// The item a press selects. Highlights and redact regions are areas: with a drawing tool
    /// active they would swallow every press inside them, so only the Select tool (or an item
    /// that is already selected) takes them.
    private func hitTestForTool(_ point: CGPoint, tolerance: Double) -> UUID? {
        guard model.tool != .select else { return document.hitTest(point, tolerance: tolerance) }
        return document.items.last { item in
            let isArea = item.kind == .highlight || item.kind.isRedact
            return item.contains(point, tolerance: tolerance) && (!isArea || item.id == selection)
        }?.id
    }

    override public func mouseDragged(with event: NSEvent) {
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .creating(var item):
            if item.kind == .arrow {
                item.end = shift ? AnnotationItem.snap45(point, from: item.start) : point
            } else if item.kind == .freehand {
                item.points = FreehandPath.appending(point, to: item.points)
                item.end = item.points.last ?? point
            } else if item.kind == .highlight {
                (item.start, item.end) = AnnotationItem.highlightCorners(press: dragPress, to: point, constrain: shift)
            } else {
                item.end = shift ? Self.square(from: item.start, to: point) : point
                if item.kind == .rectangle { item.filled = event.modifierFlags.contains(.option) }
            }
            drag = .creating(item)
            needsDisplay = true
        case .moving(_, let start, let before, let original):
            var next = before
            next.update(original.offset(by: point.x - start.x, point.y - start.y))
            document = next
        case .resizing(let id, let handle, _):
            var next = document
            next.resize(id, handle: handle, to: point, constrain: shift)
            document = next
        case .cropNew(let start):
            cropDraft = Self.clampedCrop(CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)
            ), to: document.imageBounds)
            needsDisplay = true
        case .cropMove(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            let bounds = document.imageBounds
            moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
            cropDraft = moved
            needsDisplay = true
        case .cropResize(let handle, let original):
            let item = AnnotationItem.pixelate(original).resized(handle, to: point)
            var rect = item.box
            if shift, original.height > 0 {
                let ratio = original.width / original.height
                rect.size.height = rect.width / ratio
                if [.topLeft, .topRight, .top].contains(handle) { rect.origin.y = original.maxY - rect.height }
            }
            cropDraft = Self.clampedCrop(rect, to: document.imageBounds)
            needsDisplay = true
        }
    }

    override public func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .creating(var item):
            if item.kind == .freehand {
                item.points = FreehandPath.appending(imagePoint(convert(event.locationInWindow, from: nil)), to: item.points)
                item.end = item.points.last ?? item.end
            }
            if item.isMeaningful {
                addItem(item)
            } else {
                needsDisplay = true
            }
        case .moving(_, _, let before, _):
            if document != before {
                registerUndo(restoring: before, name: "Move")
                updateUndoState()
            }
        case .resizing(_, _, let before):
            if document != before {
                registerUndo(restoring: before, name: "Resize")
                updateUndoState()
            }
        case .none, .cropNew, .cropMove, .cropResize:
            break
        }
    }

    override public func magnify(with event: NSEvent) {
        let next = displayScale * (1 + event.magnification)
        zoom = .scale(min(max(next, Self.zoomRange.lowerBound), Self.zoomRange.upperBound))
    }

    override public func scrollWheel(with event: NSEvent) {
        guard zoom != .fit else { return }
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        needsDisplay = true
    }

    private func beginCropDrag(at point: CGPoint, radius: Double) {
        let crop = cropDraft ?? document.outputRect
        if let handle = AnnotationHandle.boxHandles.first(where: {
            let anchor = $0.point(on: crop)
            return hypot(anchor.x - point.x, anchor.y - point.y) <= radius
        }) {
            drag = .cropResize(handle, original: crop)
        } else if crop.contains(point) {
            drag = .cropMove(start: point, original: crop)
        } else {
            drag = .cropNew(start: point)
        }
    }

    static func square(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let side = max(abs(point.x - start.x), abs(point.y - start.y))
        return CGPoint(x: start.x + (point.x >= start.x ? side : -side), y: start.y + (point.y >= start.y ? side : -side))
    }

    static func clampedCrop(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? rect : clipped
    }

    // MARK: Text

    private func beginTextEditing(newAt point: CGPoint) {
        let item = AnnotationItem.text("", at: point, color: model.color)
        startOverlay(for: item, isNew: true)
    }

    private func beginTextEditing(existing id: UUID) {
        guard let item = document.item(id) else { return }
        startOverlay(for: item, isNew: false)
    }

    private func startOverlay(for item: AnnotationItem, isNew: Bool) {
        let scale = displayScale
        let overlay = TextEditingOverlay(
            itemID: item.id, text: item.text, fontSize: item.fontSize * scale, color: item.color
        )
        overlay.onCommit = { [weak self] text in
            guard let self else { return }
            textOverlay = nil
            commitText(text, for: item, isNew: isNew)
            // As on cancel: Delete, the arrows and the tool letters reach the canvas again.
            window?.makeFirstResponder(self)
        }
        overlay.onCancel = { [weak self] in
            self?.textOverlay = nil
            self?.needsDisplay = true
            self?.window?.makeFirstResponder(self)
        }
        textOverlay = overlay
        overlay.begin(in: self, at: viewPoint(item.start))
        needsDisplay = true
    }

    private func commitText(_ text: String, for item: AnnotationItem, isNew: Bool) {
        var edited = item
        edited.text = text
        if isNew {
            if edited.isMeaningful { addItem(edited) }
        } else {
            var next = document
            if edited.isMeaningful {
                next.update(edited)
            } else {
                next.delete(item.id)
                selection = nil
            }
            apply(next, undoFrom: document, name: "Edit Text")
        }
        needsDisplay = true
    }

    private func endTextEditing(commit: Bool) {
        guard let overlay = textOverlay else { return }
        if commit { overlay.commit() } else { overlay.cancel() }
    }

    // MARK: Keys

    override public func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 51, 117:
            deleteSelection()
            return
        case 123:
            nudgeSelection(dx: -1, dy: 0, large: shift)
            return
        case 124:
            nudgeSelection(dx: 1, dy: 0, large: shift)
            return
        case 125:
            nudgeSelection(dx: 0, dy: 1, large: shift)
            return
        case 126:
            nudgeSelection(dx: 0, dy: -1, large: shift)
            return
        case 36, 76:
            if model.tool == .crop {
                applyCrop()
            } else if let id = selection, document.item(id)?.kind == .text {
                beginTextEditing(existing: id)
            }
            return
        case 53:
            if model.tool == .crop {
                cancelCrop()
            } else {
                selection = nil
            }
            return
        default:
            break
        }
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers, let tool = AnnotateTool(key: characters) {
            model.pick(tool)
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard textOverlay == nil, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if shift { redo() } else { undo() }
        case "c":
            copyImage()
        case "s":
            if shift { saveImageAs() } else { saveImage() }
        case "d":
            duplicateSelection()
        case "0":
            toggleZoom()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

// MARK: Toast

/// The "Saved to Downloads" toast with a Reveal link: rises 8 pt and fades in over 160 ms, holds
/// 1.5 s, fades out over 200 ms (M12).
@MainActor
@Observable
public final class ToastState {
    public private(set) var message: String?
    public private(set) var revealURL: URL?
    public private(set) var isVisible = false
    @ObservationIgnored var onReveal: ((URL) -> Void)?
    @ObservationIgnored private var generation = 0

    public init() {}

    public func show(_ message: String, reveal url: URL?) {
        self.message = message
        revealURL = url
        generation += 1
        let current = generation
        withAnimation(Theme.Motion.enter(Theme.Motion.toastIn)) { isVisible = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Annotate.toastHoldSeconds + Theme.Motion.toastIn))
            guard let self, generation == current else { return }
            withAnimation(Theme.Motion.exit(Theme.Motion.toastOut)) { isVisible = false }
        }
    }

    func reveal() {
        if let revealURL { onReveal?(revealURL) }
    }
}

struct ToastView: View {
    let state: ToastState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let message = state.message {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.success.color)
                    Text(message).font(Theme.Typography.bodyEmphasis.font)
                    if state.revealURL != nil {
                        Button("Reveal") { state.reveal() }
                            .buttonStyle(.link)
                            .font(Theme.Typography.body.font)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Theme.Materials.card))
                .overlay(Capsule().strokeBorder(Theme.Colors.cardEdge.color, lineWidth: Theme.Materials.edgeWidth))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .opacity(state.isVisible ? 1 : 0)
                .offset(y: state.isVisible || reduceMotion ? 0 : Theme.Annotate.toastRise)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(state.isVisible)
    }
}
