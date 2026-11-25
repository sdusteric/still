import AppKit
import SnapCore
import SwiftUI

/// The one Quick Access panel (design 8): borderless, non-activating, floating, transparent, on
/// every Space. It hosts the SwiftUI card stack and may become key only while the pointer is over
/// a card, so Snap never takes Esc away from other apps. Clicks on its transparent parts pass
/// through to the windows below.
public final class QuickAccessPanel: NSPanel, QuickAccessSurface {
    private var acceptsKeys = false
    private let keyHandler: (QuickAccessKey) -> Bool
    private let optionHandler: (Bool) -> Void

    public init(controller: QuickAccessController) {
        keyHandler = { [weak controller] key in controller?.handleKey(key) ?? false }
        optionHandler = { [weak controller] held in controller?.setOptionHeld(held) }
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 336, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        let hosting = FirstMouseHostingView(rootView: QuickAccessControllerView(controller: controller))
        hosting.sizingOptions = []
        contentView = hosting
    }

    public var windowID: WindowID? { isVisible && windowNumber > 0 ? WindowID(windowNumber) : nil }

    override public var canBecomeKey: Bool { acceptsKeys }
    override public var canBecomeMain: Bool { false }

    public func show(frame: CGRect) {
        if self.frame != frame { setFrame(frame, display: true) }
        orderFrontRegardless()
    }

    public func hide() {
        acceptsKeys = false
        orderOut(nil)
    }

    public func setAcceptsKeys(_ accepts: Bool) {
        guard accepts != acceptsKeys else { return }
        acceptsKeys = accepts
        for step in Self.keySteps(accepts: accepts, isVisible: isVisible, isKey: isKeyWindow) {
            switch step {
            case .makeKey: makeKey()
            case .orderOut: orderOut(nil)
            case .orderFront: orderFrontRegardless()
            }
        }
    }

    /// One window call `setAcceptsKeys` makes.
    enum KeyStep: Equatable {
        case makeKey, orderOut, orderFront
    }

    /// The window calls that take or hand back the keys. Taking them is `makeKey()` on a visible
    /// panel. Handing them back is ordering the panel out and front again: AppKit documents
    /// `resignKeyWindow` (`resignKey()`) as an override point that must not be invoked directly,
    /// since it only informs the window and leaves key focus where it is. Ordering out the key
    /// window is what gives key focus back to the active app; `canBecomeKey` is already false by
    /// then, so ordering front again does not take it back.
    static func keySteps(accepts: Bool, isVisible: Bool, isKey: Bool) -> [KeyStep] {
        if accepts { return isVisible ? [.makeKey] : [] }
        return isKey ? [.orderOut, .orderFront] : []
    }

    override public func keyDown(with event: NSEvent) {
        if let key = QuickAccessKey(
            characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags
        ), keyHandler(key) {
            return
        }
        super.keyDown(with: event)
    }

    override public func flagsChanged(with event: NSEvent) {
        optionHandler(event.modifierFlags.contains(.option))
        super.flagsChanged(with: event)
    }

    override public func cancelOperation(_ sender: Any?) {
        _ = keyHandler(.close)
    }

    /// The factory `QuickAccessController` takes in the app.
    public static func makeSurface(controller: QuickAccessController) -> (any QuickAccessSurface)? {
        QuickAccessPanel(controller: controller)
    }
}

/// A hosting view that takes the first click, so a card button works without a focusing click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
