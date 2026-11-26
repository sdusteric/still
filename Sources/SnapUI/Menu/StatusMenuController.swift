import AppKit
import SnapCore

/// The menu bar item (design 12.1, 17.6, 20.6 and 20.10): an `NSStatusItem` with the template
/// symbol `viewfinder` and a standard `NSMenu` rebuilt from `MenuModel` each time it opens. While
/// recording it becomes the red timer: a plain click stops, Option-click or right-click opens the
/// recording menu. Building menus is separate from `install()`, so tests build them without a
/// status item.
public final class StatusMenuController: NSObject, NSMenuDelegate {
    public let menu: NSMenu
    /// The current model; called every time the menu opens.
    public var modelProvider: () -> MenuModel
    /// The recording menu's model, read when it opens.
    public var recordingMenuProvider: () -> RecordingMenuModel?
    /// The thumbnail of a recent capture or a pin's capture, by capture id.
    public var thumbnail: (String) -> CGImage?
    /// A menu item was chosen, or the timer was clicked (`.stopRecording`).
    public var onSelect: (MenuItemID) -> Void
    /// The menu is about to open: the app re-checks the permission preflight here (design 13).
    public var onWillOpen: () -> Void
    /// The clock the timer reads, the same one `RecordingController` reports its start on.
    public var now: () -> TimeInterval
    /// True when the menu opens, false when it closes. macOS holds the app's hotkey events while
    /// its menu is open, so the app takes the keys another way meanwhile.
    public var onTrackingChanged: (Bool) -> Void = { _ in }

    /// What the status item shows: nil is the viewfinder, else the red timer.
    public private(set) var recording: RecordingIndicator?
    /// The heartbeat's warning while recording: the timer turns amber (design 20.6).
    public private(set) var stall: RecordingStall?
    /// The permission badge on the viewfinder (design 13): a capture failed for permission.
    public private(set) var showsBadge = false
    /// The recording menu last built, for tests.
    public private(set) var lastRecordingMenu: NSMenu?

    private var statusItem: NSStatusItem?
    private var timerView: RecordingStatusItemView?
    private var badgeView: StatusBadgeView?
    private var ticker: Timer?

    public init(
        modelProvider: @escaping () -> MenuModel,
        recordingMenuProvider: @escaping () -> RecordingMenuModel? = { nil },
        thumbnail: @escaping (String) -> CGImage? = { _ in nil },
        onSelect: @escaping (MenuItemID) -> Void = { _ in },
        onWillOpen: @escaping () -> Void = {},
        now: @escaping () -> TimeInterval = { SystemClock().now() }
    ) {
        self.modelProvider = modelProvider
        self.recordingMenuProvider = recordingMenuProvider
        self.thumbnail = thumbnail
        self.onSelect = onSelect
        self.onWillOpen = onWillOpen
        self.now = now
        menu = NSMenu(title: "Still")
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild()
    }

    /// Creates the status item. Only the app calls this; never tests or shot mode.
    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        applyIndicator()
    }

    public func uninstall() {
        ticker?.invalidate()
        ticker = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        timerView = nil
    }

    /// Rebuilds the menu from the current model.
    public func rebuild() {
        let model = modelProvider()
        menu.removeAllItems()
        for item in model.items { menu.addItem(makeItem(item)) }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onWillOpen()
        rebuild()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onTrackingChanged(true)
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onTrackingChanged(false)
    }

    /// Closes the menu while it is open, for a shortcut pressed meanwhile.
    public func closeMenu() {
        menu.cancelTracking()
    }

    // MARK: Recording timer (design 20.6, M24)

    /// Shows the red timer (`.recording`), "Saving", or the viewfinder again (nil). The digits
    /// change in place once a second; nothing pulses.
    public func setRecording(_ indicator: RecordingIndicator?) {
        guard indicator != recording else { return }
        recording = indicator
        applyIndicator()
    }

    /// The heartbeat's stall, or nil when samples arrive again. Only a plain state change: the
    /// capsule's color and glyph, no animation (M24).
    public func setStall(_ stall: RecordingStall?) {
        guard stall != self.stall else { return }
        self.stall = stall
        guard let timerView, let statusItem else { return }
        timerView.stall = stall
        // The timer view passes clicks and hover to the button, so the button carries the text.
        statusItem.button?.toolTip = RecordingStatusItemView.toolTip(stall: stall)
        statusItem.button?.setAccessibilityLabel(stall.map { "Stop Recording. \($0.message)" } ?? "Stop Recording")
        let size = RecordingStatusItemView.capsuleSize(for: timerView.text, stalled: stall != nil)
        statusItem.length = size.width + 8
        timerView.frame.size = size
    }

    /// Shows or hides the permission badge on the viewfinder.
    public func setBadge(_ shows: Bool) {
        guard shows != showsBadge else { return }
        showsBadge = shows
        applyIndicator()
    }

    /// The text the timer shows now.
    public var timerText: String? { recording?.text(now: now()) }

    /// What a click on the status item does while recording: a plain click stops; Option-click
    /// or right-click opens the recording menu, which is returned. Without a recording the
    /// normal menu opens (the status item has it attached, so this is not reached).
    @discardableResult
    public func timerClicked(showsMenu: Bool) -> NSMenu? {
        guard recording != nil else { return nil }
        guard showsMenu else {
            onSelect(.stopRecording)
            return nil
        }
        return makeRecordingMenu()
    }

    /// The recording menu: Stop Recording, Cancel Recording and the information rows.
    public func makeRecordingMenu() -> NSMenu? {
        guard let model = recordingMenuProvider() else { return nil }
        let menu = NSMenu(title: "Recording")
        menu.autoenablesItems = false
        for item in model.items { menu.addItem(makeItem(item)) }
        lastRecordingMenu = menu
        return menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard recording != nil else {
            // The viewfinder: show the main menu under the button.
            showMenu(menu, from: sender)
            return
        }
        let event = NSApp.currentEvent
        let showsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if let recordingMenu = timerClicked(showsMenu: showsMenu) {
            showMenu(recordingMenu, from: sender)
        }
    }

    private func showMenu(_ menu: NSMenu, from button: NSStatusBarButton) {
        if menu === self.menu {
            onWillOpen()
            rebuild()
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func applyIndicator() {
        guard let statusItem, let button = statusItem.button else { return }
        ticker?.invalidate()
        ticker = nil
        guard let recording else {
            timerView?.removeFromSuperview()
            timerView = nil
            stall = nil
            // The system opens the attached menu on any click; the button action is not sent.
            statusItem.menu = menu
            statusItem.length = NSStatusItem.squareLength
            var image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Still")
            if showsBadge, let symbol = image { image = StatusBadgeView.symbolWithHole(symbol) }
            image?.isTemplate = true
            button.image = image
            button.toolTip = showsBadge ? "Still: Screen Recording needs your OK" : "Still"
            button.setAccessibilityLabel(showsBadge ? "Still, Screen Recording needs your OK" : "Still")
            if showsBadge {
                let badge = badgeView ?? StatusBadgeView()
                if badge.superview !== button { button.addSubview(badge) }
                badge.frame = StatusBadgeView.frame(in: button.bounds, symbolSize: image?.size ?? CGSize(width: 16, height: 16))
                badgeView = badge
            } else {
                badgeView?.removeFromSuperview()
                badgeView = nil
            }
            return
        }
        badgeView?.removeFromSuperview()
        badgeView = nil
        // Detached, so a click reaches `statusItemClicked`: a plain click stops at once.
        statusItem.menu = nil
        button.image = nil
        button.toolTip = RecordingStatusItemView.toolTip(stall: stall)
        button.setAccessibilityLabel(stall.map { "Stop Recording. \($0.message)" } ?? "Stop Recording")
        let text = recording.text(now: now())
        let view = timerView ?? RecordingStatusItemView(text: text)
        view.text = text
        view.stall = stall
        let size = RecordingStatusItemView.capsuleSize(for: text, stalled: stall != nil)
        statusItem.length = size.width + 8
        if view.superview !== button {
            button.addSubview(view)
            timerView = view
        }
        view.frame = CGRect(x: 4, y: (button.bounds.height - size.height) / 2, width: size.width, height: size.height)
        guard case .recording = recording else { return }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        guard let recording, let statusItem, let view = timerView else { return }
        let text = recording.text(now: now())
        view.text = text
        let size = RecordingStatusItemView.capsuleSize(for: text, stalled: stall != nil)
        statusItem.length = size.width + 8
        view.frame.size = size
    }

    @objc private func itemChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuIDBox else { return }
        onSelect(box.id)
    }

    // MARK: Items

    func makeItem(_ item: MenuItem) -> NSMenuItem {
        switch item.kind {
        case .separator:
            return .separator()
        case .header:
            return .sectionHeader(title: item.title)
        case .info:
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: Theme.Recording.infoStyle.nsFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            if let symbol = item.symbolName {
                menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menuItem.isEnabled = false
            return menuItem
        case .status:
            let menuItem = actionItem(item)
            menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: Theme.Typography.caption.nsFont,
                .foregroundColor: Theme.Colors.warning.hexColor,
            ])
            menuItem.image = Self.dotImage(color: Theme.Colors.warningDot.hexColor)
            return menuItem
        case .action:
            let menuItem = actionItem(item)
            if let key = item.keyEquivalent {
                menuItem.keyEquivalent = key.key
                menuItem.keyEquivalentModifierMask = Self.modifierMask(key)
            }
            if let symbol = item.symbolName {
                menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            if item.isAlternate {
                // Shown in place of the row above while Option is held.
                menuItem.keyEquivalentModifierMask = .option
                menuItem.isAlternate = true
            }
            if item.indented { menuItem.indentationLevel = 1 }
            if !item.children.isEmpty {
                let submenu = NSMenu(title: item.title)
                submenu.autoenablesItems = false
                for child in item.children { submenu.addItem(makeItem(child)) }
                menuItem.submenu = submenu
                menuItem.action = nil
            }
            if let captureID = item.captureID {
                menuItem.image = Self.thumbnailImage(thumbnail(captureID))
                let title = NSMutableAttributedString(string: item.title, attributes: [.font: Theme.Typography.body.nsFont])
                if let subtitle = item.subtitle {
                    title.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                        .font: Theme.Typography.captionSmall.nsFont,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                menuItem.attributedTitle = title
                if case .recentCapture = item.id { menuItem.toolTip = "Show this capture again" }
            }
            return menuItem
        }
    }

    private func actionItem(_ item: MenuItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: #selector(itemChosen(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = MenuIDBox(item.id)
        menuItem.isEnabled = item.isEnabled
        return menuItem
    }

    static func modifierMask(_ key: MenuKeyEquivalent) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if key.command { mask.insert(.command) }
        if key.shift { mask.insert(.shift) }
        if key.option { mask.insert(.option) }
        if key.control { mask.insert(.control) }
        return mask
    }

    /// A 32 x 32 pt thumbnail with radius 6, aspect-fill; a neutral tile when there is no image.
    /// AppKit may run an NSImage drawing handler on any thread, so this and `dotImage` build theirs
    /// nonisolated (a main-actor handler traps in dispatch_assert_queue there).
    nonisolated static func thumbnailImage(_ image: CGImage?) -> NSImage {
        let side = Theme.Menu.thumbnailSize
        let radius = Theme.Menu.thumbnailRadius
        return bitmapImage(points: CGSize(width: side, height: side)) { context, rect in
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.clip()
            context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
            context.fill(rect)
            if let image {
                let factor = max(rect.width / Double(image.width), rect.height / Double(image.height))
                let size = CGSize(width: Double(image.width) * factor, height: Double(image.height) * factor)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height
                ))
            }
            context.addPath(path)
            context.setStrokeColor(NSColor(white: 0, alpha: 0.18).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    nonisolated static func dotImage(color: NSColor) -> NSImage {
        let side = Theme.Menu.statusDotSize
        return bitmapImage(points: CGSize(width: side, height: side)) { context, rect in
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: rect)
        }
    }

    /// A ready bitmap at 2x, drawn once now. An image drawn on demand by a handler did not show
    /// in the live menu on macOS 27 (the recent captures had no thumbnail).
    nonisolated static func bitmapImage(points: CGSize, draw: (CGContext, CGRect) -> Void) -> NSImage {
        let scale = 2.0
        let width = Int(points.width * scale)
        let height = Int(points.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: points) }
        context.scaleBy(x: scale, y: scale)
        draw(context, CGRect(origin: .zero, size: points))
        guard let image = context.makeImage() else { return NSImage(size: points) }
        return NSImage(cgImage: image, size: points)
    }
}

/// A menu item's id, carried in `representedObject` so submenu rows resolve too.
private final class MenuIDBox: NSObject {
    let id: MenuItemID
    init(_ id: MenuItemID) { self.id = id }
}

/// The permission badge on the viewfinder (design 13): a `warningDot` disc at the symbol's
/// top-right corner, sitting in a hole cut out of the template symbol so the two never touch. It
/// is drawn, not a symbol, so it keeps its color on a template status item; clicks pass through.
public final class StatusBadgeView: NSView {
    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    public init() {
        let side = Theme.Menu.badgeSize + 2 * Theme.Menu.badgeGap
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The badge's center in a symbol of `size` (top-left origin): on its top-right corner.
    nonisolated static func center(inSymbolOf size: CGSize) -> CGPoint {
        // Centered 1 pt inside the corner, so most of the corner bracket stays visible.
        let inset = Theme.Menu.badgeSize / 2 - 2
        return CGPoint(x: size.width - inset, y: inset)
    }

    /// The badge over a symbol of `symbolSize` centered in `bounds` (a flipped button).
    static func frame(in bounds: CGRect, symbolSize: CGSize) -> CGRect {
        let side = Theme.Menu.badgeSize + 2 * Theme.Menu.badgeGap
        let origin = CGPoint(x: bounds.midX - symbolSize.width / 2, y: bounds.midY - symbolSize.height / 2)
        let center = center(inSymbolOf: symbolSize)
        return CGRect(x: origin.x + center.x - side / 2, y: origin.y + center.y - side / 2, width: side, height: side)
    }

    /// `symbol` with a round hole where the badge goes, still usable as a template image.
    /// Nonisolated, since AppKit may run the drawing handler on any thread.
    nonisolated static func symbolWithHole(_ symbol: NSImage) -> NSImage {
        let size = symbol.size
        let side = Theme.Menu.badgeSize + 2 * Theme.Menu.badgeGap
        let center = center(inSymbolOf: size)
        return NSImage(size: size, flipped: true) { @Sendable rect in
            symbol.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)).fill()
            return true
        }
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Self.draw(in: bounds, color: Theme.Colors.warningDot.cgColor(for: effectiveAppearance), context: context)
    }

    /// The disc inside `rect` (the gap ring stays clear, so the symbol's stroke does not touch it).
    static func draw(in rect: CGRect, color: CGColor, context: CGContext) {
        context.setFillColor(color)
        context.fillEllipse(in: rect.insetBy(dx: Theme.Menu.badgeGap, dy: Theme.Menu.badgeGap))
    }
}
