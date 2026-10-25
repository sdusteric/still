import AppKit
import QuartzCore
import SnapCore

/// Where the outline of an area recording sits (design 20.6, D63): the selection border, 1 pt
/// white with a 1 pt black 30% hairline on both sides, drawn 2 pt outside the area so it is never
/// in the frames. Pure geometry in global top-left points.
public enum RecordingOutline {
    /// Hairline, white line, hairline.
    public static var strokeWidth: Double {
        Theme.Recording.outlineWidth + 2 * Theme.Recording.outlineHairlineWidth
    }

    /// The rect the white line's inner edge follows: the area grown by the outset.
    public static func borderRect(around area: CGRect) -> CGRect {
        area.insetBy(dx: -Theme.Recording.outlineOutset, dy: -Theme.Recording.outlineOutset)
    }

    /// The panel's frame: the border rect grown by the stroke, so nothing it draws overlaps the area.
    public static func panelFrame(around area: CGRect) -> CGRect {
        borderRect(around: area).insetBy(dx: -strokeWidth, dy: -strokeWidth)
    }

    /// Draws the outline of `area` into a flipped context whose space matches `area`'s.
    static func draw(around area: CGRect, context: CGContext) {
        let hairline = Theme.Recording.outlineHairlineWidth
        let white = Theme.Recording.outlineWidth
        let inner = borderRect(around: area)
        context.saveGState()
        defer { context.restoreGState() }
        // From the inside out: hairline, white, hairline. Strokes are centered, so step by halves.
        context.setLineWidth(hairline)
        context.setStrokeColor(Theme.Colors.selectionHairline.cgColor(dark: false))
        context.stroke(inner.insetBy(dx: -hairline / 2, dy: -hairline / 2))
        context.setLineWidth(white)
        context.setStrokeColor(Theme.Colors.selectionBorder.cgColor(dark: false))
        context.stroke(inner.insetBy(dx: -(hairline + white / 2), dy: -(hairline + white / 2)))
        context.setLineWidth(hairline)
        context.setStrokeColor(Theme.Colors.selectionHairline.cgColor(dark: false))
        context.stroke(inner.insetBy(dx: -(hairline + white + hairline / 2), dy: -(hairline + white + hairline / 2)))
    }
}

/// Draws the outline in a view that exactly covers `RecordingOutline.panelFrame`.
final class RecordingOutlineView: NSView {
    var area: CGRect = .zero {
        didSet { if area != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The view's origin is the panel frame's top-left corner.
        let origin = RecordingOutline.panelFrame(around: area).origin
        let local = area.offsetBy(dx: -origin.x, dy: -origin.y)
        RecordingOutline.draw(around: local, context: context)
    }
}

/// The click-through outline shown around an area while it records (design 20.6, M23): a
/// borderless panel over the area's border only, ignoring the mouse, excluded from the recording
/// filter by its window number. Window and fullscreen recordings have no outline. Made on the
/// first `show`, so tests and shot mode never create it.
public final class RecordingOutlinePanel {
    private var panel: NSPanel?
    private var view: RecordingOutlineView?
    /// Global top-left area being recorded; nil while hidden.
    public private(set) var area: CGRect?

    public init() {}

    /// The window number, so the recording filter can exclude it (D62). Nil before the first show.
    public var windowID: WindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return WindowID(panel.windowNumber)
    }

    /// Shows the outline around `area` at once, no fade.
    /// - Parameter primaryHeight: the main screen's height, to turn top-left points into AppKit's
    ///   bottom-left screen coordinates.
    public func show(around area: CGRect, primaryHeight: Double) {
        self.area = area
        let topLeft = RecordingOutline.panelFrame(around: area)
        let screenFrame = CGRect(
            x: topLeft.minX, y: primaryHeight - topLeft.maxY, width: topLeft.width, height: topLeft.height
        )
        let panel = self.panel ?? makePanel(frame: screenFrame)
        self.panel = panel
        view?.area = area
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        CATransaction.commit()
    }

    public func hide() {
        area = nil
        panel?.orderOut(nil)
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = RecordingOutlineView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.view = view
        return panel
    }
}
