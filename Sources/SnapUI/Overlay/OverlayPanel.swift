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
    /// Pops up the HUD's Options menu with its top-left corner at `point` (display-local,
    /// top-left points). Tracks the menu until it closes.
    func popUpMenu(_ menu: NSMenu, at point: CGPoint)
}

/// One borderless, non-activating panel per screen at the screen saver level (design 7). It is
/// built at launch and kept ordered out, so the hotkey only orders it front.
public final class OverlayPanel: NSPanel, OverlaySurface {
    let overlayView: SelectionOverlayView
    private let frozenView: FrozenImageView
    private let countdownView: CountdownView

    /// `screenFrame` is the screen's `NSScreen.frame` (bottom-left origin).
    public init(state: SelectionOverlayState, screenFrame: CGRect, eventSink: any OverlayEventSink) {
        let size = screenFrame.size
        frozenView = FrozenImageView(frame: CGRect(origin: .zero, size: size))
        overlayView = SelectionOverlayView(state: state, drawsFrozenImage: false, drawsCountdownDigit: false)
        overlayView.eventSink = eventSink
        countdownView = CountdownView(frame: CGRect(origin: .zero, size: size))
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
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
        countdownView.autoresizingMask = [.width, .height]
        container.addSubview(frozenView)
        container.addSubview(overlayView)
        container.addSubview(countdownView)
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

    public func popUpMenu(_ menu: NSMenu, at point: CGPoint) {
        menu.popUp(positioning: nil, at: point, in: overlayView)
    }

    private func apply(_ state: SelectionOverlayState) {
        // HUD Record mode shows the live screen: the frozen layer is hidden, not dropped (D59).
        frozenView.image = state.showsFrozenImage ? state.frozenImage : nil
        overlayView.state = state
        if let seconds = state.hud?.countdown, let target = state.localRecordTarget {
            countdownView.show(seconds, disc: CountdownLayout.discFrame(target: target, bounds: state.bounds))
        } else {
            countdownView.show(nil, disc: .zero)
        }
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
