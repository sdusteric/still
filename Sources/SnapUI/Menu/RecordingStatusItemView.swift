import AppKit
import SnapCore

/// What the status item shows while a recording runs (design 20.6).
public enum RecordingIndicator: Sendable, Hashable {
    /// Recording since this clock time; the timer counts from it.
    case recording(since: TimeInterval)
    /// Finishing the file: the timer reads "Saving".
    case saving

    /// `0:42`, `1:02:05` after an hour, or "Saving" (M24: digits change in place).
    public func text(now: TimeInterval) -> String {
        switch self {
        case .recording(let since): RecordingController.elapsedText(now - since)
        case .saving: "Saving"
        }
    }
}

/// The red timer in the menu bar while recording (design 20.6, mockup 11b): an 18 pt capsule in
/// `record` red, a white 8 pt rounded stop square, and the elapsed time in 12 pt semibold tabular
/// white. No pulse, no blink (M24, D78). Drawn in `draw(_:)` so tests and shots render it with
/// `cacheDisplay`.
public final class RecordingStatusItemView: NSView {
    public var text: String {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The heartbeat's warning, nil while every track delivers. A stall turns the capsule amber
    /// and adds a warning glyph; the click still stops.
    public var stall: RecordingStall? {
        didSet {
            guard stall != oldValue else { return }
            toolTip = Self.toolTip(stall: stall)
            setAccessibilityLabel(stall.map { "Stop Recording. \($0.message)" } ?? "Stop Recording")
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public init(text: String, stall: RecordingStall? = nil) {
        self.text = text
        self.stall = stall
        let size = Self.capsuleSize(for: text, stalled: stall != nil)
        super.init(frame: CGRect(origin: .zero, size: size))
        toolTip = Self.toolTip(stall: stall)
        setAccessibilityLabel(stall.map { "Stop Recording. \($0.message)" } ?? "Stop Recording")
        setAccessibilityRole(.button)
    }

    static func toolTip(stall: RecordingStall?) -> String {
        let stop = "Stop Recording (\u{21E7}\u{2318}5)"
        return stall.map { "\($0.message)\n\(stop)" } ?? stop
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public var intrinsicContentSize: NSSize { Self.capsuleSize(for: text, stalled: stall != nil) }
    // Clicks go to the status bar button underneath, which owns the click and the menu.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    static var font: NSFont { Theme.Recording.timerStyle.nsFont }

    /// Leading padding, stop square, spacing, text, trailing padding; 18 pt high. The width of
    /// `0:00` is the floor, so the capsule does not shrink between 0:59 and 1:00. A stall adds the
    /// warning glyph after the text.
    public static func capsuleSize(for text: String, stalled: Bool = false) -> CGSize {
        let recording = Theme.Recording.self
        let textWidth = max(OverlayDrawing.textWidth(text, font: font), OverlayDrawing.textWidth("0:00", font: font))
        var width = recording.timerLeadingPadding + recording.stopSquareSize + recording.timerSpacing + textWidth
            + recording.timerTrailingPadding
        if stalled { width += recording.timerSpacing - 1 + recording.stallGlyphSize }
        return CGSize(width: width.rounded(.up), height: recording.timerHeight)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let stalled = stall != nil
        let size = Self.capsuleSize(for: text, stalled: stalled)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        let fill = stalled ? Theme.Recording.stalledFill : Theme.Colors.record
        Self.draw(text: text, in: CGRect(origin: origin, size: size), red: fill.cgColor(for: effectiveAppearance),
                  stalled: stalled, context: context)
    }

    /// Draws the capsule into a flipped context: red with white, or amber with dark ink and the
    /// warning glyph when `stalled`.
    static func draw(text: String, in rect: CGRect, red: CGColor, stalled: Bool = false, context: CGContext) {
        let recording = Theme.Recording.self
        let ink = stalled ? recording.stalledInk.light.nsColor : Theme.Colors.chipText.light.nsColor
        context.addPath(CGPath(roundedRect: rect, cornerWidth: recording.timerRadius, cornerHeight: recording.timerRadius, transform: nil))
        context.setFillColor(red)
        context.fillPath()
        let square = CGRect(
            x: rect.minX + recording.timerLeadingPadding, y: rect.midY - recording.stopSquareSize / 2,
            width: recording.stopSquareSize, height: recording.stopSquareSize
        )
        context.addPath(CGPath(
            roundedRect: square, cornerWidth: recording.stopSquareRadius, cornerHeight: recording.stopSquareRadius, transform: nil
        ))
        context.setFillColor(ink.cgColor)
        context.fillPath()
        OverlayDrawing.drawText(text, font: font, x: square.maxX + recording.timerSpacing, centerY: rect.midY, color: ink)
        guard stalled else { return }
        let glyphSide = recording.stallGlyphSize
        let glyphRect = CGRect(
            x: rect.maxX - recording.timerTrailingPadding - glyphSide, y: rect.midY - glyphSide / 2,
            width: glyphSide, height: glyphSide
        )
        drawWarningTriangle(in: glyphRect, color: ink.cgColor, cutout: red, context: context)
    }

    /// A filled warning triangle with the exclamation mark cut in the capsule color. Drawn as a
    /// path, so it renders the same in the status bar, in tests and in shots.
    static func drawWarningTriangle(in rect: CGRect, color: CGColor, cutout: CGColor, context: CGContext) {
        let top = CGPoint(x: rect.midX, y: rect.minY + 0.5)
        let triangle = CGMutablePath()
        triangle.move(to: top)
        triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        triangle.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
        triangle.closeSubpath()
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineWidth(1.4)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.addPath(triangle)
        context.drawPath(using: .fillStroke)
        context.setFillColor(cutout)
        let bar = CGRect(x: rect.midX - 0.65, y: rect.minY + rect.height * 0.36, width: 1.3, height: rect.height * 0.30)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 0.65, cornerHeight: 0.65, transform: nil))
        context.fillPath()
        context.fillEllipse(in: CGRect(x: rect.midX - 0.75, y: rect.minY + rect.height * 0.74, width: 1.5, height: 1.5))
        context.restoreGState()
    }
}
