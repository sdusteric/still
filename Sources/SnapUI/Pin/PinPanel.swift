import AppKit
import SnapCore
import SwiftUI

/// Global top-left points (the space of `PinBoard`, `item.json` and `CGWindowList`) to and from
/// `NSScreen` coordinates, whose origin is the bottom-left of the primary display.
public enum ScreenSpace {
    /// Height of the primary display, the flip line between the two spaces.
    public static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    public static func topLeft(fromScreen rect: CGRect, primaryHeight: Double = primaryHeight) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func screen(fromTopLeft rect: CGRect, primaryHeight: Double = primaryHeight) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func topLeft(fromScreen point: CGPoint, primaryHeight: Double = primaryHeight) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Every display as pins see it, the main display first.
    public static func visibleDisplays() -> [VisibleDisplay] {
        let height = primaryHeight
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return VisibleDisplay(
                id: DisplayID(number.uint32Value),
                frame: topLeft(fromScreen: screen.frame, primaryHeight: height),
                visibleFrame: topLeft(fromScreen: screen.visibleFrame, primaryHeight: height)
            )
        }
    }
}

/// One pin's window (design 20.2, D48): borderless, non-activating, resizable, floating, on every
/// Space, `contentAspectRatio` set to the image. It becomes key on a click without activating Snap.
/// Opaque captures get the window server's shadow around the radius 8 clip; window captures keep
/// their own captured shadow, so the panel draws none.
public final class PinPanel: NSPanel, PinSurface, NSWindowDelegate {
    private let pinID: Int
    private weak var controller: PinController?
    private var isClickThrough = false
    private var isClosing = false

    public init(controller: PinController, model: PinModel) {
        pinID = model.id
        self.controller = controller
        super.init(
            contentRect: ScreenSpace.screen(fromTopLeft: model.frame),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = model.isOpaque
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentAspectRatio = model.pointSize
        contentMinSize = CGSize(
            width: model.pointSize.width * PinBoard.minimumZoom(for: model.pointSize),
            height: model.pointSize.height * PinBoard.minimumZoom(for: model.pointSize)
        )
        delegate = self

        let id = model.id
        let handler = PinViewHandler(
            perform: { [weak controller] command in controller?.perform(command, on: id) },
            hover: { [weak controller] hovered in controller?.setHovered(id, hovered) },
            stepOpacity: { [weak controller] steps in controller?.stepOpacity(id, by: steps) },
            showMore: { [weak self] in self?.showMoreMenu() },
            moveBegan: { [weak controller] in controller?.moveBegan(id) },
            moveChanged: { [weak controller] translation in controller?.moveChanged(id, translation: translation) },
            moveEnded: { [weak controller] in controller?.moveEnded(id) },
            zoom: { [weak controller] steps in
                controller?.zoom(id, by: steps, around: ScreenSpace.topLeft(fromScreen: NSEvent.mouseLocation))
            }
        )
        let hosting = FirstMouseHostingView(rootView: PinView(model: model, handler: handler))
        hosting.sizingOptions = []
        contentView = hosting
    }

    override public var canBecomeKey: Bool { !isClickThrough }
    override public var canBecomeMain: Bool { false }

    // MARK: PinSurface

    public func present(frame: CGRect, transition: PinTransition) {
        let target = ScreenSpace.screen(fromTopLeft: frame)
        switch transition {
        case .grow(let from):
            setFrame(ScreenSpace.screen(fromTopLeft: from), display: true)
            alphaValue = 1
            orderFrontRegardless()
            animate(duration: Theme.Motion.springResponse, timing: Theme.Motion.enterTiming) {
                self.animator().setFrame(target, display: true)
            }
        case .fadeScale:
            setFrame(Self.scaled(target, by: Theme.Pin.appearScale), display: true)
            alphaValue = 0
            orderFrontRegardless()
            animate(duration: Theme.Motion.pinEnter, timing: Theme.Motion.enterTiming) {
                self.animator().setFrame(target, display: true)
                self.animator().alphaValue = 1
            }
        case .fade:
            setFrame(target, display: true)
            alphaValue = 0
            orderFrontRegardless()
            animate(duration: Theme.Motion.reducedMotionFade, timing: Theme.Motion.enterTiming) {
                self.animator().alphaValue = 1
            }
        }
    }

    public func setFrame(_ frame: CGRect) {
        guard !isClosing else { return }
        let target = ScreenSpace.screen(fromTopLeft: frame)
        if self.frame != target {
            setFrame(target, display: true)
            invalidateShadow()
        }
    }

    public func setClickThrough(_ on: Bool) {
        isClickThrough = on
        ignoresMouseEvents = on
        if on, isKeyWindow {
            // Hands key focus back to the app below (see QuickAccessPanel.keySteps).
            orderOut(nil)
            orderFrontRegardless()
        }
    }

    public func dismiss(transition: PinTransition) {
        guard !isClosing else { return }
        isClosing = true
        let finish: @MainActor () -> Void = { [weak self] in
            self?.orderOut(nil)
            self?.close()
        }
        switch transition {
        case .fadeScale, .grow:
            let target = Self.scaled(frame, by: Theme.Pin.appearScale)
            animate(duration: Theme.Motion.pinExit, timing: Theme.Motion.exitTiming, completion: finish) {
                self.animator().setFrame(target, display: true)
                self.animator().alphaValue = 0
            }
        case .fade:
            animate(duration: Theme.Motion.reducedMotionFade, timing: Theme.Motion.exitTiming, completion: finish) {
                self.animator().alphaValue = 0
            }
        }
    }

    // MARK: Keys

    override public func keyDown(with event: NSEvent) {
        if let controller, controller.handleKey(
            pinID, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags
        ) {
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let controller else { return super.performKeyEquivalent(with: event) }
        return controller.handleKey(
            pinID, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags
        ) || super.performKeyEquivalent(with: event)
    }

    override public func cancelOperation(_ sender: Any?) {
        controller?.perform(.close, on: pinID)
    }

    // MARK: Live resize (aspect locked by `contentAspectRatio`, decided by the board)

    public func windowWillStartLiveResize(_ notification: Notification) {
        controller?.resizeBegan(pinID)
    }

    public func windowDidResize(_ notification: Notification) {
        guard inLiveResize else { return }
        controller?.panelResized(pinID, to: ScreenSpace.topLeft(fromScreen: frame))
        invalidateShadow()
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        controller?.resizeEnded(pinID)
        invalidateShadow()
    }

    // MARK: More menu

    private func showMoreMenu() {
        guard let controller, let content = contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, row) in controller.moreMenu(for: pinID).enumerated() {
            if row.separatorBefore && index > 0 { menu.addItem(.separator()) }
            let item = PinMenuAction.item(row) { [weak controller, pinID] command in controller?.perform(command, on: pinID) }
            menu.addItem(item)
        }
        let anchor = CGPoint(
            x: content.bounds.maxX - Theme.Pin.controlBarInset - Theme.Pin.controlButtonSize.width,
            y: content.isFlipped
                ? Theme.Pin.controlBarInset + Theme.Pin.controlBarHeight
                : content.bounds.maxY - Theme.Pin.controlBarInset - Theme.Pin.controlBarHeight
        )
        menu.popUp(positioning: nil, at: anchor, in: content)
    }

    // MARK: Helpers

    private func animate(
        duration: Double,
        timing: CAMediaTimingFunction,
        completion: (@MainActor () -> Void)? = nil,
        changes: @escaping @MainActor () -> Void
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            changes()
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        let width = rect.width * factor
        let height = rect.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The factory `PinController` takes in the app.
    public static func makeSurface(controller: PinController, model: PinModel) -> (any PinSurface)? {
        PinPanel(controller: controller, model: model)
    }
}

/// A More menu row as an `NSMenuItem` whose target runs one `PinCommand`.
final class PinMenuAction: NSObject {
    private let command: PinCommand
    private let run: @MainActor (PinCommand) -> Void

    private init(command: PinCommand, run: @escaping @MainActor (PinCommand) -> Void) {
        self.command = command
        self.run = run
    }

    @objc func fire(_ sender: Any?) { run(command) }

    static func item(_ row: PinMenuItem, run: @escaping @MainActor (PinCommand) -> Void) -> NSMenuItem {
        let action = PinMenuAction(command: row.command, run: run)
        let item = NSMenuItem(title: row.title, action: #selector(PinMenuAction.fire(_:)), keyEquivalent: "")
        switch row.command {
        case .copy: item.keyEquivalent = "c"
        case .save: item.keyEquivalent = "s"
        case .resetSize: item.keyEquivalent = "0"
        case .annotate:
            item.keyEquivalent = "a"
            item.keyEquivalentModifierMask = []
        case .close:
            item.keyEquivalent = "\u{1B}"
            item.keyEquivalentModifierMask = []
        default: break
        }
        item.target = action
        // The menu item holds its target weakly; keep the action alive as long as the item.
        item.representedObject = action
        item.isEnabled = row.isEnabled
        return item
    }
}
