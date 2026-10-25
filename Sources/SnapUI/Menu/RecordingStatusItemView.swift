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

    public init(text: String) {
        self.text = text
        let size = Self.capsuleSize(for: text)
        super.init(frame: CGRect(origin: .zero, size: size))
        toolTip = "Stop Recording (\u{21E7}\u{2318}5)"
        setAccessibilityLabel("Stop Recording")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public var intrinsicContentSize: NSSize { Self.capsuleSize(for: text) }
    // Clicks go to the status bar button underneath, which owns the click and the menu.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    static var font: NSFont { Theme.Recording.timerStyle.nsFont }

    /// Leading padding, stop square, spacing, text, trailing padding; 18 pt high. The width of
    /// `0:00` is the floor, so the capsule does not shrink between 0:59 and 1:00.
    public static func capsuleSize(for text: String) -> CGSize {
        let recording = Theme.Recording.self
        let textWidth = max(OverlayDrawing.textWidth(text, font: font), OverlayDrawing.textWidth("0:00", font: font))
        let width = recording.timerLeadingPadding + recording.stopSquareSize + recording.timerSpacing + textWidth
            + recording.timerTrailingPadding
        return CGSize(width: width.rounded(.up), height: recording.timerHeight)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = Self.capsuleSize(for: text)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        Self.draw(text: text, in: CGRect(origin: origin, size: size), red: Theme.Colors.record.cgColor(for: effectiveAppearance),
                  context: context)
    }

    /// Draws the capsule into a flipped context.
    static func draw(text: String, in rect: CGRect, red: CGColor, context: CGContext) {
        let recording = Theme.Recording.self
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
        context.setFillColor(Theme.Colors.chipText.cgColor(dark: false))
        context.fillPath()
        OverlayDrawing.drawText(
            text, font: font, x: square.maxX + recording.timerSpacing, centerY: rect.midY,
            color: Theme.Colors.chipText.light.nsColor
        )
    }
}
