import AppKit
import QuartzCore
import SnapCore

/// The recording countdown (design 20.6, mockup 11a): an 88 pt disc in the chip color with a
/// 0.5 pt ring and one soft shadow, the seconds left in 44 pt semibold tabular white, and a hint
/// chip 12 pt below it ("Recording in 3 s", Return Start now, Esc Cancel). The keys reach the
/// overlay panel, which stays key during the countdown, so no global monitor is needed.
public enum CountdownLayout {
    public static var discSize: Double { Theme.Countdown.discSize }

    /// The disc centered on `target` (the area, window or display being recorded), kept inside
    /// `bounds` with room for the hint chip. All rects share one space.
    public static func discFrame(target: CGRect, bounds: CGRect, hintHeight: Double = Theme.Overlay.hintBarHeight) -> CGRect {
        let size = discSize
        let unit = size + Theme.Countdown.hintGap + hintHeight
        let x = min(max(target.midX - size / 2, bounds.minX), bounds.maxX - size)
        let y = min(max(target.midY - size / 2, bounds.minY), bounds.maxY - unit)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size, height: size)
    }

    /// The hint chip's rows for `seconds` left.
    static func hintItems(seconds: Int) -> [OverlayHintBar.Item] {
        [.text("Recording in \(seconds) s"), .key("\u{21A9}", "Start now"), .key("Esc", "Cancel")]
    }

    /// The hint chip 12 pt under the disc, centered on it.
    static func hintFrame(disc: CGRect, seconds: Int) -> CGRect {
        let size = OverlayHintBar.size(for: hintItems(seconds: seconds))
        return CGRect(
            x: (disc.midX - size.width / 2).rounded(), y: disc.maxY + Theme.Countdown.hintGap,
            width: size.width, height: size.height
        )
    }

    /// The digit as drawn: the seconds left, never below 1.
    static func digit(_ seconds: Int) -> String { String(max(seconds, 1)) }

    static var digitFont: NSFont {
        let style = Theme.Countdown.digitStyle
        return .monospacedDigitSystemFont(ofSize: style.size, weight: style.weight)
    }

    /// Draws the disc, its shadow and ring into a flipped context; `withDigit` adds the number.
    static func drawDisc(_ disc: CGRect, seconds: Int, withDigit: Bool, context: CGContext) {
        context.saveGState()
        // CSS shadow 0 10 30 black 35% (20.6). The context is flipped, so y down is negative.
        context.setShadow(
            offset: CGSize(width: 0, height: -Theme.Countdown.shadowOffsetY), blur: Theme.Countdown.shadowBlur,
            color: Theme.Colors.countdownShadow.cgColor(dark: false)
        )
        context.setFillColor(Theme.Colors.chip.cgColor(dark: false))
        context.fillEllipse(in: disc)
        context.restoreGState()
        let ring = Theme.Countdown.ringWidth
        context.setStrokeColor(Theme.Colors.chipRing.cgColor(dark: false))
        context.setLineWidth(ring)
        context.strokeEllipse(in: disc.insetBy(dx: ring / 2, dy: ring / 2))
        if withDigit { drawDigit(seconds, in: disc) }
    }

    static func drawDigit(_ seconds: Int, in disc: CGRect) {
        let text = digit(seconds)
        let attributes: [NSAttributedString.Key: Any] = [.font: digitFont, .foregroundColor: Theme.Colors.chipText.light.nsColor]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2), withAttributes: attributes
        )
    }

    /// The whole countdown: disc, digit and hint chip.
    static func draw(seconds: Int, target: CGRect, bounds: CGRect, withDigit: Bool, context: CGContext) {
        let disc = discFrame(target: target, bounds: bounds)
        drawDisc(disc, seconds: seconds, withDigit: withDigit, context: context)
        let hint = hintFrame(disc: disc, seconds: seconds)
        OverlayHintBar.draw(items: hintItems(seconds: seconds), in: hint, context: context)
    }
}

/// The live countdown digit over the overlay (M22): each new digit cross-fades in 120 ms with the
/// enter curve, in place and without a scale, because the user reads it while getting ready; the
/// same cross-fade serves Reduce Motion. The disc and hint are drawn by `SelectionOverlayView`;
/// this view holds only the digits, so a tick redraws nothing else.
public final class CountdownView: NSView {
    private var digitViews: [CountdownDigitView] = []
    private var current: Int?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<2 {
            let digit = CountdownDigitView(frame: CGRect(x: 0, y: 0, width: Theme.Countdown.discSize, height: Theme.Countdown.discSize))
            digit.alphaValue = 0
            addSubview(digit)
            digitViews.append(digit)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The digit currently shown, nil when hidden.
    public var shownSeconds: Int? { current }

    /// Shows `seconds` in `disc` (view coordinates); nil hides the digit.
    public func show(_ seconds: Int?, disc: CGRect) {
        guard let seconds else {
            current = nil
            for view in digitViews { view.alphaValue = 0 }
            return
        }
        guard seconds != current else {
            for view in digitViews { view.frame = disc }
            return
        }
        let animated = current != nil
        current = seconds
        let incoming = digitViews[1]
        let outgoing = digitViews[0]
        digitViews = [incoming, outgoing]
        incoming.frame = disc
        outgoing.frame = disc
        incoming.seconds = seconds
        guard animated else {
            incoming.alphaValue = 1
            outgoing.alphaValue = 0
            return
        }
        incoming.alphaValue = 0
        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.countdownDigit
            context.timingFunction = timing
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        }
    }
}

/// One digit, drawn centered in its frame.
final class CountdownDigitView: NSView {
    var seconds = 3 {
        didSet { if seconds != oldValue { needsDisplay = true } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        CountdownLayout.drawDigit(seconds, in: bounds)
    }
}
