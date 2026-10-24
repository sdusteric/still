import AppKit
import QuartzCore
import SnapCore

/// What `OverlayController` needs from one display's overlay window. The live one is
/// `OverlayPanel`; tests and the shot mode use none or a fake, so they never create a panel.
@MainActor
public protocol OverlaySurface: AnyObject {
    /// The window number, so the capture can exclude the overlay. Nil before the window exists.
    var windowID: WindowID? { get }
    /// Draws `state` and orders the panel front at once. `makeKey` routes keys to it.
    func show(_ state: SelectionOverlayState, makeKey: Bool)
    func update(_ state: SelectionOverlayState)
    /// Orders out with no fade.
    func hide()
}

/// One borderless, non-activating panel per screen at the screen saver level (design 7). It is
/// built at launch and kept ordered out, so the hotkey only orders it front.
public final class OverlayPanel: NSPanel, OverlaySurface {
    let overlayView: SelectionOverlayView
    private let frozenView: FrozenImageView

    /// `screenFrame` is the screen's `NSScreen.frame` (bottom-left origin).
    public init(state: SelectionOverlayState, screenFrame: CGRect, eventSink: any OverlayEventSink) {
        let size = screenFrame.size
        frozenView = FrozenImageView(frame: CGRect(origin: .zero, size: size))
        overlayView = SelectionOverlayView(state: state, drawsFrozenImage: false)
        overlayView.eventSink = eventSink
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isMovable = false

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        frozenView.autoresizingMask = [.width, .height]
        overlayView.frame = container.bounds
        overlayView.autoresizingMask = [.width, .height]
        container.addSubview(frozenView)
        container.addSubview(overlayView)
        contentView = container
        setFrame(screenFrame, display: false)
        apply(state)
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    public var windowID: WindowID? { windowNumber > 0 ? WindowID(windowNumber) : nil }

    public func show(_ state: SelectionOverlayState, makeKey: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(state)
        orderFrontRegardless()
        if makeKey {
            self.makeKey()
            makeFirstResponder(overlayView)
        }
        CATransaction.commit()
    }

    public func update(_ state: SelectionOverlayState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(state)
        CATransaction.commit()
    }

    public func hide() {
        orderOut(nil)
    }

    private func apply(_ state: SelectionOverlayState) {
        frozenView.image = state.frozenImage
        overlayView.state = state
    }

    /// The factory `OverlayController` takes in the app: one panel per display.
    public static func makeSurface(
        display: DisplayInfo,
        allDisplays: [DisplayInfo],
        eventSink: any OverlayEventSink
    ) -> (any OverlaySurface)? {
        let space = CoordinateSpace(displays: allDisplays)
        return OverlayPanel(
            state: SelectionOverlayState(display: display),
            screenFrame: space.screenFrame(of: display),
            eventSink: eventSink
        )
    }
}
