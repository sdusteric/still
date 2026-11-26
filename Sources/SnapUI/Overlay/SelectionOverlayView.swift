import AppKit
import QuartzCore
import SnapCore

/// Where the overlay is in one capture.
public enum OverlayPhase: Sendable, Hashable {
    /// Before the drag: the dim, the optional magnifier with coordinates, hint bar.
    case idle
    /// Mouse down: the selection is cut out of the dim and the magnifier shows the size.
    case dragging
    /// Instant capture off, after mouse up: handles and a size chip until Return.
    case adjusting
}

/// What the all-in-one HUD adds to one display's overlay (design 20.5, 20.6). Points are global
/// top-left, as in `SelectionOverlayState`.
public struct HUDOverlayDrawing: Sendable, Hashable {
    public var mode: HUDMode
    public var target: CaptureMode
    /// The toolbar's top-left corner when the toolbar is on this display.
    public var toolbarOrigin: CGPoint?
    /// Replaces the size chip's text: "Too small to record", "Not enough disk space".
    public var notice: String?
    /// The Fullscreen target is this display: accent 14% fill and a label chip.
    public var highlightsDisplay: Bool
    /// The display's name for the Fullscreen label chip, when known.
    public var displayName: String?
    /// After Record is confirmed: the area, window or display being recorded. The toolbar and the
    /// handles are gone; the dim stays outside it with the selection border (20.6).
    public var recordTarget: CGRect?
    /// Seconds left in the countdown, drawn in the disc over `recordTarget`.
    public var countdown: Int?

    public init(
        mode: HUDMode = .screenshot,
        target: CaptureMode = .area,
        toolbarOrigin: CGPoint? = nil,
        notice: String? = nil,
        highlightsDisplay: Bool = false,
        displayName: String? = nil,
        recordTarget: CGRect? = nil,
        countdown: Int? = nil
    ) {
        self.mode = mode
        self.target = target
        self.toolbarOrigin = toolbarOrigin
        self.notice = notice
        self.highlightsDisplay = highlightsDisplay
        self.displayName = displayName
        self.recordTarget = recordTarget
        self.countdown = countdown
    }
}

/// Everything one display's overlay draws. A plain value, so the shot mode and tests render the
/// view with `cacheDisplay` and no panel. Points are global top-left, as the pipeline uses them.
public struct SelectionOverlayState: Sendable, Equatable {
    public var display: DisplayInfo
    /// The display's frozen image; nil until the capture arrives (the live screen shows through).
    public var frozenImage: CGImage?
    /// `.area` or `.window`.
    public var mode: CaptureMode
    public var phase: OverlayPhase
    /// Nil when the pointer is on another display.
    public var pointer: CGPoint?
    public var selection: CGRect?
    public var hoveredWindow: WindowInfo?
    public var showsMagnifier: Bool
    public var showsKeyHints: Bool
    /// The HUD's toolbar, target and countdown; nil for the plain Cmd+Shift+4 overlay.
    public var hud: HUDOverlayDrawing?

    public init(
        display: DisplayInfo,
        frozenImage: CGImage? = nil,
        mode: CaptureMode = .area,
        phase: OverlayPhase = .idle,
        pointer: CGPoint? = nil,
        selection: CGRect? = nil,
        hoveredWindow: WindowInfo? = nil,
        showsMagnifier: Bool = true,
        showsKeyHints: Bool = true,
        hud: HUDOverlayDrawing? = nil
    ) {
        self.display = display
        self.frozenImage = frozenImage
        self.mode = mode
        self.phase = phase
        self.pointer = pointer
        self.selection = selection
        self.hoveredWindow = hoveredWindow
        self.showsMagnifier = showsMagnifier
        self.showsKeyHints = showsKeyHints
        self.hud = hud
    }

    public static func == (lhs: SelectionOverlayState, rhs: SelectionOverlayState) -> Bool {
        lhs.display == rhs.display && lhs.frozenImage === rhs.frozenImage && lhs.mode == rhs.mode
            && lhs.phase == rhs.phase && lhs.pointer == rhs.pointer && lhs.selection == rhs.selection
            && lhs.hoveredWindow == rhs.hoveredWindow && lhs.showsMagnifier == rhs.showsMagnifier
            && lhs.showsKeyHints == rhs.showsKeyHints
            && lhs.hud == rhs.hud
    }

    /// The display's bounds in view coordinates (display-local, top-left origin).
    public var bounds: CGRect { CGRect(origin: .zero, size: display.frameTopLeft.size) }

    /// A global rect in this display's view coordinates.
    public func local(_ rect: CGRect) -> CGRect { CoordinateSpace.localRect(rect, in: display) }

    public func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - display.frameTopLeft.minX, y: point.y - display.frameTopLeft.minY)
    }

    /// The selection when it lies on this display.
    var localSelection: CGRect? {
        guard let selection, mode == .area, phase != .idle, hud?.recordTarget == nil else { return nil }
        let rect = local(selection)
        return rect.intersects(bounds) ? rect : nil
    }

    var localWindow: CGRect? {
        guard mode == .window, let window = hoveredWindow else { return nil }
        let rect = local(window.frame).intersection(bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    var localPointer: CGPoint? {
        guard let pointer else { return nil }
        let point = local(pointer)
        return bounds.insetBy(dx: -0.5, dy: -0.5).contains(point) ? point : nil
    }

    /// Record mode shows the live screen, so there is nothing to magnify.
    var drawsMagnifier: Bool {
        mode == .area && phase != .adjusting && showsMagnifier && localPointer != nil && showsFrozenImage
            && hud?.recordTarget == nil
    }
    /// The HUD's toolbar replaces the hint bar.
    var drawsHints: Bool { showsKeyHints && hud == nil && (mode == .window || phase == .idle) }

    /// HUD Record mode hides the frozen layer and shows the live screen (D59).
    public var showsFrozenImage: Bool { hud?.mode != .record }

    /// The HUD's record target in this display's coordinates.
    var localRecordTarget: CGRect? {
        guard let target = hud?.recordTarget else { return nil }
        let rect = local(target).intersection(bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// The toolbar's frame in this display's coordinates.
    var localToolbar: CGRect? {
        guard let hud, hud.recordTarget == nil, let origin = hud.toolbarOrigin else { return nil }
        return CGRect(origin: local(origin), size: AllInOneToolbarLayout.layout(for: hud.mode).size)
    }
}

/// The 8 handles of an editable selection (instant capture off).
public enum SelectionHandle: CaseIterable, Sendable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// The handle within `slop` points of `point` (top-left space, so minY is the top edge).
    public static func hit(_ point: CGPoint, rect: CGRect, slop: Double = 6) -> SelectionHandle? {
        allCases.first { handle in
            let center = handle.point(in: rect)
            return abs(center.x - point.x) <= slop && abs(center.y - point.y) <= slop
        }
    }
}

/// Drawing helpers shared by the overlay's layers. They expect a flipped (top-left) context.
enum OverlayDrawing {
    static var chipFont: NSFont { Theme.Typography.chip.nsFont }

    static func textAttributes(_ font: NSFont, color: NSColor = Theme.Colors.chipText.light.nsColor)
        -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    static func textWidth(_ text: String, font: NSFont) -> Double {
        ceil((text as NSString).size(withAttributes: textAttributes(font)).width)
    }

    /// Draws a text line vertically centred on `centerY`, starting at `x`.
    static func drawText(_ text: String, font: NSFont, x: Double, centerY: Double, color: NSColor? = nil) {
        let attributes = textAttributes(font, color: color ?? Theme.Colors.chipText.light.nsColor)
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: x, y: centerY - size.height / 2), withAttributes: attributes)
    }

    /// The chip surface: `chip` fill and a 0.5 pt white 18% ring (17.2). No shadow or blur (rule 2).
    static func drawChip(_ rect: CGRect, radius: Double, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(Theme.Colors.chip.cgColor(dark: false))
        context.fillPath()
        let ring = Theme.Overlay.chipRingWidth
        let inset = rect.insetBy(dx: ring / 2, dy: ring / 2)
        context.addPath(CGPath(
            roundedRect: inset, cornerWidth: radius - ring / 2, cornerHeight: radius - ring / 2, transform: nil
        ))
        context.setStrokeColor(Theme.Colors.chipRing.cgColor(dark: false))
        context.setLineWidth(ring)
        context.strokePath()
    }

    /// A one-line chip (22 pt, radius 11, padding 9) with `text` centred.
    static func chipSize(_ text: String) -> CGSize {
        CGSize(
            width: textWidth(text, font: chipFont) + 2 * Theme.Overlay.chipHorizontalPadding,
            height: Theme.Overlay.chipHeight
        )
    }

    static func drawTextChip(_ text: String, in rect: CGRect, context: CGContext) {
        drawChip(rect, radius: Theme.Overlay.chipRadius, context: context)
        drawText(text, font: chipFont, x: rect.minX + Theme.Overlay.chipHorizontalPadding, centerY: rect.midY)
    }

    /// Draws `image` upright into `rect` of a flipped context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// `640 × 400`: whole points, tabular digits come from the font.
    static func sizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) \u{00D7} \(Int(size.height.rounded()))"
    }
}

/// The hint bar at the bottom centre (17.6): label, then key and label pairs, with dividers.
enum OverlayHintBar {
    enum Item: Equatable {
        case text(String)
        case key(String, String)
    }

    static func items(for mode: CaptureMode) -> [Item] {
        switch mode {
        case .window:
            [.text("Click to capture"), .key("Space", "Area"), .key("\u{2325}", "Toggle shadow"), .key("Esc", "Cancel")]
        case .area, .fullscreen:
            [.text("Drag to capture"), .key("Space", "Window"), .key("Esc", "Cancel")]
        }
    }

    static let padding = 14.0
    static let dividerMargin = 12.0
    static let keyGap = 7.0
    static let keyHeight = 18.0
    static let keyPadding = 5.0
    static let keyRadius = 5.0
    static var labelFont: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var keyFont: NSFont { .systemFont(ofSize: 11, weight: .semibold) }

    static func keyWidth(_ key: String) -> Double {
        max(keyHeight, OverlayDrawing.textWidth(key, font: keyFont) + 2 * keyPadding)
    }

    static func itemWidth(_ item: Item) -> Double {
        switch item {
        case .text(let label): OverlayDrawing.textWidth(label, font: labelFont)
        case .key(let key, let label): keyWidth(key) + keyGap + OverlayDrawing.textWidth(label, font: labelFont)
        }
    }

    static func size(for list: [Item]) -> CGSize {
        let content = list.reduce(0) { $0 + itemWidth($1) } + Double(max(list.count - 1, 0)) * (2 * dividerMargin + 1)
        return CGSize(width: content + 2 * padding, height: Theme.Overlay.hintBarHeight)
    }

    static func frame(for mode: CaptureMode, in bounds: CGRect) -> CGRect {
        let size = size(for: items(for: mode))
        return CGRect(
            x: (bounds.midX - size.width / 2).rounded(),
            y: bounds.maxY - Theme.Overlay.hintBarBottomInset - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func draw(mode: CaptureMode, in bounds: CGRect, context: CGContext) {
        draw(items: items(for: mode), in: frame(for: mode, in: bounds), context: context)
    }

    /// A chip bar of `list` in `bar` (the countdown hint uses it too).
    static func draw(items list: [Item], in bar: CGRect, context: CGContext) {
        OverlayDrawing.drawChip(bar, radius: Theme.Overlay.hintBarRadius, context: context)
        var x = bar.minX + padding
        for (index, item) in list.enumerated() {
            switch item {
            case .text(let label):
                OverlayDrawing.drawText(label, font: labelFont, x: x, centerY: bar.midY)
            case .key(let key, let label):
                let width = keyWidth(key)
                let keyRect = CGRect(x: x, y: bar.midY - keyHeight / 2, width: width, height: keyHeight)
                context.addPath(CGPath(roundedRect: keyRect, cornerWidth: keyRadius, cornerHeight: keyRadius, transform: nil))
                context.setFillColor(CGColor(gray: 1, alpha: 0.18))
                context.fillPath()
                let keyText = OverlayDrawing.textWidth(key, font: keyFont)
                OverlayDrawing.drawText(key, font: keyFont, x: keyRect.midX - keyText / 2, centerY: bar.midY)
                OverlayDrawing.drawText(label, font: labelFont, x: x + width + keyGap, centerY: bar.midY)
            }
            x += itemWidth(item)
            if index < list.count - 1 {
                x += dividerMargin
                context.setFillColor(CGColor(gray: 1, alpha: 0.22))
                context.fill(CGRect(x: x, y: bar.midY - 6, width: 1, height: 12))
                x += 1 + dividerMargin
            }
        }
    }
}

/// One display's selection overlay (design 7, 17.6), drawn with Core Graphics in `draw(_:)`:
/// flat fills only, no material, no animation. Backgrounds are drawn here too, because
/// `cacheDisplay` does not capture a layer's `backgroundColor`.
public final class SelectionOverlayView: NSView {
    public var state: SelectionOverlayState {
        didSet {
            guard state != oldValue else { return }
            invalidate(from: oldValue, to: state)
        }
    }

    /// The live panel shows the frozen image in a layer behind this view (no redraw on the hotkey
    /// path); shots and tests draw it here.
    public var drawsFrozenImage: Bool {
        didSet { if drawsFrozenImage != oldValue { needsDisplay = true } }
    }

    /// The live panel animates the countdown digit in a `CountdownView` above this view (M22);
    /// shots and tests draw it here.
    public var drawsCountdownDigit: Bool {
        didSet { if drawsCountdownDigit != oldValue { needsDisplay = true } }
    }

    /// Receives mouse and key events, already in global top-left points.
    public weak var eventSink: (any OverlayEventSink)?

    public init(state: SelectionOverlayState, drawsFrozenImage: Bool = true, drawsCountdownDigit: Bool = true) {
        self.state = state
        self.drawsFrozenImage = drawsFrozenImage
        self.drawsCountdownDigit = drawsCountdownDigit
        super.init(frame: state.bounds)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public var acceptsFirstResponder: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let accent = Theme.Colors.accent.nsColor.cgColor
        context.saveGState()
        defer { context.restoreGState() }

        if drawsFrozenImage, state.showsFrozenImage, let image = state.frozenImage {
            context.interpolationQuality = .none
            OverlayDrawing.drawImage(image, in: bounds, context: context)
        }

        if let hud = state.hud, hud.recordTarget != nil {
            drawRecordHold(hud, context: context, bounds: bounds)
            return
        }

        drawDim(context: context, bounds: bounds)

        if let selection = state.localSelection {
            drawSelectionBorder(selection, context: context)
            if state.phase == .adjusting {
                drawHandles(selection, accent: accent, context: context)
                let text = sizeChipText(for: selection)
                OverlayDrawing.drawTextChip(text, in: sizeChipFrame(for: selection, text: text, bounds: bounds), context: context)
            }
        }

        if let hud = state.hud, hud.highlightsDisplay {
            drawDisplayHighlight(bounds, accent: accent, context: context)
            let text = displayLabel(hud)
            let size = OverlayDrawing.chipSize(text)
            OverlayDrawing.drawTextChip(text, in: CGRect(
                x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                width: size.width, height: size.height
            ), context: context)
        }

        if let window = state.localWindow, let info = state.hoveredWindow {
            drawWindowHighlight(window, accent: accent, context: context)
            let text = Self.windowLabel(info)
            OverlayDrawing.drawTextChip(text, in: windowLabelFrame(for: window, text: text, bounds: bounds), context: context)
        }

        if state.drawsMagnifier, let pointer = state.localPointer {
            let selection = state.phase == .dragging ? state.localSelection : nil
            let glass = MagnifierLayer.glassFrame(pointer: pointer, selection: selection, bounds: bounds)
            MagnifierLayer.draw(
                in: context, image: state.frozenImage, pointer: pointer, selection: selection, glass: glass,
                bounds: bounds, accent: accent
            )
            let caption = magnifierCaption(pointer: pointer, selection: selection)
            let size = OverlayDrawing.chipSize(caption)
            OverlayDrawing.drawTextChip(
                caption, in: MagnifierLayer.captionFrame(glass: glass, captionWidth: size.width), context: context
            )
        }

        if state.drawsHints {
            OverlayHintBar.draw(mode: state.mode, in: bounds, context: context)
        }

        if let hud = state.hud, let toolbar = state.localToolbar {
            AllInOneToolbar.draw(
                mode: hud.mode, target: hud.target, origin: toolbar.origin, context: context, accent: accent,
                record: Theme.Colors.record.cgColor(for: effectiveAppearance)
            )
        }
    }

    /// After Record: the dim outside the target, the selection border around an area or window,
    /// and the countdown disc and hint. A fullscreen target is left undimmed (20.6).
    private func drawRecordHold(_ hud: HUDOverlayDrawing, context: CGContext, bounds: CGRect) {
        let target = state.localRecordTarget
        let path = CGMutablePath()
        path.addRect(bounds)
        if let target { path.addRect(target) }
        context.addPath(path)
        context.setFillColor(Theme.Colors.dim.cgColor(dark: false))
        context.fillPath(using: .evenOdd)
        guard let target else { return }
        if target != bounds { drawSelectionBorder(target, context: context) }
        if let seconds = hud.countdown {
            CountdownLayout.draw(seconds: seconds, target: target, bounds: bounds, withDigit: drawsCountdownDigit, context: context)
        }
    }

    /// The size chip text, or the HUD's notice ("Too small to record").
    func sizeChipText(for selection: CGRect) -> String {
        state.hud?.notice ?? OverlayDrawing.sizeText(selection.size)
    }

    /// The Fullscreen target's label: `Studio Display | 2560 × 1440`, or the size alone.
    func displayLabel(_ hud: HUDOverlayDrawing) -> String {
        let size = OverlayDrawing.sizeText(state.display.frameTopLeft.size)
        guard let name = hud.displayName, !name.isEmpty else { return size }
        return "\(name)  |  \(size)"
    }

    private func drawDisplayHighlight(_ rect: CGRect, accent: CGColor, context: CGContext) {
        context.setFillColor(accent.copy(alpha: 0.14) ?? accent)
        context.fill(rect)
        let border = Theme.Overlay.windowHighlightBorder
        context.setStrokeColor(accent)
        context.setLineWidth(border)
        context.stroke(rect.insetBy(dx: border / 2, dy: border / 2))
    }

    private func drawDim(context: CGContext, bounds: CGRect) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection = state.localSelection {
            path.addRect(selection)
        } else if let window = state.localWindow {
            let radius = Theme.Overlay.windowHighlightRadius
            path.addPath(CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.addPath(path)
        context.setFillColor(Theme.Colors.dim.cgColor(dark: false))
        context.fillPath(using: .evenOdd)
    }

    private func drawSelectionBorder(_ rect: CGRect, context: CGContext) {
        let width = Theme.Overlay.selectionBorderWidth
        context.setLineWidth(width)
        context.setStrokeColor(Theme.Colors.selectionHairline.cgColor(dark: false))
        context.stroke(rect.insetBy(dx: -width / 2, dy: -width / 2))
        context.setStrokeColor(Theme.Colors.selectionBorder.cgColor(dark: false))
        context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
    }

    private func drawHandles(_ rect: CGRect, accent: CGColor, context: CGContext) {
        // The HUD's restored area has 10 pt handles (20.5), the plain overlay 8 pt (17.6).
        let size = state.hud == nil ? Theme.Overlay.handleSize : Theme.HUD.handleSize
        let border = state.hud == nil ? Theme.Overlay.handleBorderWidth : Theme.HUD.handleBorderWidth
        for handle in SelectionHandle.allCases {
            let center = handle.point(in: rect)
            let circle = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            context.setFillColor(Theme.Colors.selectionBorder.cgColor(dark: false))
            context.fillEllipse(in: circle)
            context.setStrokeColor(accent)
            context.setLineWidth(border)
            context.strokeEllipse(in: circle.insetBy(dx: border / 2, dy: border / 2))
        }
    }

    private func drawWindowHighlight(_ rect: CGRect, accent: CGColor, context: CGContext) {
        let radius = Theme.Overlay.windowHighlightRadius
        let border = Theme.Overlay.windowHighlightBorder
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(accent.copy(alpha: 0.14) ?? accent)
        context.fillPath()
        let inset = rect.insetBy(dx: border / 2, dy: border / 2)
        context.addPath(CGPath(
            roundedRect: inset, cornerWidth: radius - border / 2, cornerHeight: radius - border / 2, transform: nil
        ))
        context.setStrokeColor(accent)
        context.setLineWidth(border)
        context.strokePath()
    }

    // MARK: Layout

    /// `x, y` in global points before the drag, `W × H` during it.
    private func magnifierCaption(pointer: CGPoint, selection: CGRect?) -> String {
        if let selection { return OverlayDrawing.sizeText(selection.size) }
        let global = state.pointer ?? pointer
        return "\(Int(global.x.rounded(.down))), \(Int(global.y.rounded(.down)))"
    }

    /// 8 pt under the selection, or above it when there is no room.
    func sizeChipFrame(for selection: CGRect, text: String, bounds: CGRect) -> CGRect {
        let size = OverlayDrawing.chipSize(text)
        let gap = Theme.Overlay.sizeChipGap
        var y = selection.maxY + gap
        if y + size.height > bounds.maxY { y = selection.minY - gap - size.height }
        y = min(max(y, bounds.minY), bounds.maxY - size.height)
        let x = min(max(selection.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 34 pt above the window, or inside its top edge when there is no room.
    func windowLabelFrame(for window: CGRect, text: String, bounds: CGRect) -> CGRect {
        let size = OverlayDrawing.chipSize(text)
        var y = window.minY - Theme.Overlay.windowLabelOffset
        if y < bounds.minY { y = window.minY + Theme.Spacing.s }
        let x = min(max(window.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// `Notes | 842 × 516`, or the size alone when CGWindowList gave no owner name.
    static func windowLabel(_ window: WindowInfo) -> String {
        let size = OverlayDrawing.sizeText(window.frame.size)
        guard let owner = window.ownerName, !owner.isEmpty else { return size }
        return "\(owner)  |  \(size)"
    }

    /// The regions that differ between two states, or nil when everything must be redrawn.
    func changedRegions(from old: SelectionOverlayState, to new: SelectionOverlayState) -> [CGRect]? {
        if old.display != new.display || old.frozenImage !== new.frozenImage || old.mode != new.mode
            || old.phase != new.phase
            || old.showsMagnifier != new.showsMagnifier || old.showsKeyHints != new.showsKeyHints || old.hud != new.hud {
            return nil
        }
        return chromeRegions(old) + chromeRegions(new)
    }

    private func chromeRegions(_ state: SelectionOverlayState) -> [CGRect] {
        let bounds = state.bounds
        var regions: [CGRect] = []
        if state.drawsMagnifier, let pointer = state.localPointer {
            let selection = state.phase == .dragging ? state.localSelection : nil
            let glass = MagnifierLayer.glassFrame(pointer: pointer, selection: selection, bounds: bounds)
            regions.append(CGRect(
                x: glass.minX - 60, y: glass.minY - 4, width: glass.width + 120, height: MagnifierLayer.unitHeight + 8
            ))
        }
        if let selection = state.localSelection {
            regions.append(selection.insetBy(dx: -8, dy: -8))
            if state.phase == .adjusting {
                let text = state.hud?.notice ?? OverlayDrawing.sizeText(selection.size)
                regions.append(sizeChipFrame(for: selection, text: text, bounds: bounds).insetBy(dx: -2, dy: -2))
            }
        }
        if let window = state.localWindow, let info = state.hoveredWindow {
            regions.append(window.insetBy(dx: -3, dy: -3))
            let text = Self.windowLabel(info)
            regions.append(windowLabelFrame(for: window, text: text, bounds: bounds).insetBy(dx: -2, dy: -2))
        }
        return regions
    }

    private func invalidate(from old: SelectionOverlayState, to new: SelectionOverlayState) {
        if frame.size != new.bounds.size { setFrameSize(new.bounds.size) }
        guard let regions = changedRegions(from: old, to: new) else {
            needsDisplay = true
            return
        }
        for region in regions { setNeedsDisplay(region) }
    }

    // MARK: Events

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil
        ))
    }

    /// The view is flipped and covers its display, so a view point plus the display origin is global.
    private func globalPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).offset(by: state.display.frameTopLeft.origin)
    }

    override public func mouseMoved(with event: NSEvent) {
        eventSink?.overlayEvent(.mouseMoved(globalPoint(event)))
    }

    override public func mouseDown(with event: NSEvent) {
        eventSink?.overlayEvent(.mouseDown(
            globalPoint(event), clickCount: event.clickCount, modifiers: OverlayModifiers(event.modifierFlags)
        ))
    }

    override public func mouseDragged(with event: NSEvent) {
        eventSink?.overlayEvent(.mouseDragged(globalPoint(event), modifiers: OverlayModifiers(event.modifierFlags)))
    }

    override public func mouseUp(with event: NSEvent) {
        eventSink?.overlayEvent(.mouseUp(globalPoint(event), modifiers: OverlayModifiers(event.modifierFlags)))
    }

    override public func rightMouseDown(with event: NSEvent) {
        eventSink?.overlayEvent(.rightMouseDown)
    }

    override public func keyDown(with event: NSEvent) {
        eventSink?.overlayEvent(.keyDown(
            OverlayKey(keyCode: event.keyCode), modifiers: OverlayModifiers(event.modifierFlags),
            isRepeat: event.isARepeat
        ))
    }

    override public func keyUp(with event: NSEvent) {
        eventSink?.overlayEvent(.keyUp(OverlayKey(keyCode: event.keyCode)))
    }

    override public func flagsChanged(with event: NSEvent) {
        eventSink?.overlayEvent(.modifiersChanged(OverlayModifiers(event.modifierFlags)))
    }

    override public func cursorUpdate(with event: NSEvent) {
        // The system pointer stays as it is: AppKit would reset it to the arrow here.
    }
}

extension CGPoint {
    func offset(by origin: CGPoint) -> CGPoint { CGPoint(x: x + origin.x, y: y + origin.y) }
}

/// Holds the frozen image as layer contents behind the overlay view, so a new frame costs no
/// redraw (design 6.6).
final class FrozenImageView: NSView {
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Demo states

/// Fixed overlay states on a fake desktop for the shot mode (`overlay-area`, `overlay-before`,
/// `overlay-window`) and the tests. The desktop follows the appearance, as in the mockup.
public enum OverlayDemo {
    /// 1280 x 800 points at 2x, as the shot table in design 16 lists.
    public static let display = DisplayInfo(
        id: 1, frameTopLeft: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2
    )

    /// The Notes-like window of the fake desktop, in global points.
    public static let notesWindow = WindowInfo(
        id: 202, ownerPID: 410, ownerName: "Notes", bundleID: "com.apple.Notes",
        frame: CGRect(x: 184, y: 128, width: 842, height: 516), order: 1
    )

    /// A browser-like window behind it.
    public static let browserWindow = WindowInfo(
        id: 203, ownerPID: 420, ownerName: "Safari", bundleID: "com.apple.Safari",
        frame: CGRect(x: 700, y: 280, width: 340, height: 420), order: 2
    )

    public static var windows: [WindowInfo] { [notesWindow, browserWindow] }

    /// Mockup 1b: dragging, the selection cut out, the magnifier with the size caption.
    public static func areaState(dark: Bool = false) -> SelectionOverlayState {
        let selection = CGRect(x: 360, y: 220, width: 640, height: 400)
        return SelectionOverlayState(
            display: display, frozenImage: desktopImage(dark: dark), mode: .area, phase: .dragging,
            pointer: CGPoint(x: selection.maxX, y: selection.maxY), selection: selection
        )
    }

    /// Mockup 1a: before the drag, magnifier with coordinates, hint bar.
    public static func beforeState(dark: Bool = false) -> SelectionOverlayState {
        SelectionOverlayState(
            display: display, frozenImage: desktopImage(dark: dark), mode: .area, phase: .idle,
            pointer: CGPoint(x: 642, y: 351)
        )
    }

    /// Mockup 1c: window mode with the Notes window highlighted.
    public static func windowState(dark: Bool = false) -> SelectionOverlayState {
        SelectionOverlayState(
            display: display, frozenImage: desktopImage(dark: dark), mode: .window, phase: .idle,
            pointer: CGPoint(x: 600, y: 400), hoveredWindow: notesWindow
        )
    }

    /// Renders an overlay state at `scale` with `cacheDisplay`: no window, no panel.
    public static func render(_ state: SelectionOverlayState, dark: Bool, scale: Double = 2) -> CGImage? {
        let view = SelectionOverlayView(state: state)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return OffscreenRender.cacheDisplay(view, scale: scale)
    }

    /// The fake desktop: wallpaper gradient, a browser window and a Notes window with text lines.
    public static func desktopImage(dark: Bool, scale: Double = 2) -> CGImage? {
        let size = display.frameTopLeft.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let context = SyntheticImages.makeContext(width: width, height: height) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let wallpaper: [CGColor] = dark
            ? [CGColor(srgbRed: 0.10, green: 0.11, blue: 0.24, alpha: 1), CGColor(srgbRed: 0.24, green: 0.15, blue: 0.30, alpha: 1)]
            : [CGColor(srgbRed: 0.78, green: 0.82, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.96, green: 0.84, blue: 0.80, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: SyntheticImages.colorSpace, colors: wallpaper as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        let bar = dark ? CGColor(gray: 0.12, alpha: 0.9) : CGColor(gray: 1, alpha: 0.6)
        context.setFillColor(bar)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 24))
        drawWindow(browserWindow.frame, dark: dark, context: context, lines: 6)
        drawWindow(notesWindow.frame, dark: dark, context: context, lines: 12)
        return context.makeImage()
    }

    /// A captured-window look for card thumbnails: the Notes window alone.
    public static func windowImage(dark: Bool, size: CGSize = CGSize(width: 842, height: 516), scale: Double = 1)
        -> CGImage? {
        guard let context = SyntheticImages.makeContext(width: Int(size.width * scale), height: Int(size.height * scale))
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        drawWindow(CGRect(origin: .zero, size: size), dark: dark, context: context, lines: 12, radius: 0)
        return context.makeImage()
    }

    private static func drawWindow(_ frame: CGRect, dark: Bool, context: CGContext, lines: Int, radius: Double = 12) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.setFillColor(dark ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(frame)
        let sidebar = CGRect(x: frame.minX, y: frame.minY + 28, width: min(144, frame.width * 0.25), height: frame.height - 28)
        context.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1) : CGColor(gray: 0.95, alpha: 1))
        context.fill(sidebar)
        context.setFillColor(dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 28))
        let lights: [CGColor] = [
            CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
            CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
        ]
        for (index, color) in lights.enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: frame.minX + 12 + Double(index) * 18, y: frame.minY + 8, width: 12, height: 12))
        }
        let text = dark ? CGColor(gray: 0.85, alpha: 1) : CGColor(gray: 0.2, alpha: 1)
        let quiet = dark ? CGColor(gray: 0.55, alpha: 1) : CGColor(gray: 0.6, alpha: 1)
        let left = sidebar.maxX + 26
        context.setFillColor(text)
        context.fill(CGRect(x: left, y: frame.minY + 56, width: min(300, frame.width - left + frame.minX - 20), height: 14))
        for index in 0..<lines {
            let y = frame.minY + 92 + Double(index) * 22
            guard y + 6 < frame.maxY - 12 else { break }
            context.setFillColor(index % 4 == 3 ? text : quiet)
            let width = (frame.width - (left - frame.minX) - 30) * (index % 3 == 2 ? 0.6 : 0.92)
            context.fill(CGRect(x: left, y: y, width: max(width, 0), height: 6))
        }
        context.restoreGState()
    }
}

/// `cacheDisplay` into a bitmap of `scale` pixels per point, with no window.
enum OffscreenRender {
    static func cacheDisplay(_ view: NSView, scale: Double) -> CGImage? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int((size.width * scale).rounded()),
                  pixelsHigh: Int((size.height * scale).rounded()),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              // Tagged sRGB so colors pass through unconverted and pixel checks compare like for like.
              let bitmap = bitmap.retagging(with: .sRGB) else { return nil }
        bitmap.size = size
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }
}
