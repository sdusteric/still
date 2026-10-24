import AppKit
import SnapCore

/// The menu bar item (design 12.1, 17.6): an `NSStatusItem` with the template symbol
/// `viewfinder` and a standard `NSMenu` rebuilt from `MenuModel` each time it opens. Building
/// the menu is separate from `install()`, so tests build menus without a status item.
public final class StatusMenuController: NSObject, NSMenuDelegate {
    public let menu: NSMenu
    /// The current model; called every time the menu opens.
    public var modelProvider: () -> MenuModel
    /// The thumbnail of a recent capture, by capture id.
    public var thumbnail: (String) -> CGImage?
    /// A menu item was chosen.
    public var onSelect: (MenuItemID) -> Void
    /// The menu is about to open: the app re-checks the permission preflight here (design 13).
    public var onWillOpen: () -> Void

    private var statusItem: NSStatusItem?
    private var items: [MenuItem] = []

    public init(
        modelProvider: @escaping () -> MenuModel,
        thumbnail: @escaping (String) -> CGImage? = { _ in nil },
        onSelect: @escaping (MenuItemID) -> Void = { _ in },
        onWillOpen: @escaping () -> Void = {}
    ) {
        self.modelProvider = modelProvider
        self.thumbnail = thumbnail
        self.onSelect = onSelect
        self.onWillOpen = onWillOpen
        menu = NSMenu(title: "Snap")
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
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Snap")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snap"
        }
        item.menu = menu
        statusItem = item
    }

    public func uninstall() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Rebuilds the menu from the current model.
    public func rebuild() {
        let model = modelProvider()
        items = model.items
        menu.removeAllItems()
        for (index, item) in items.enumerated() {
            menu.addItem(makeItem(item, tag: index))
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        onWillOpen()
        rebuild()
    }

    @objc private func itemChosen(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag].id)
    }

    // MARK: Items

    func makeItem(_ item: MenuItem, tag: Int) -> NSMenuItem {
        switch item.kind {
        case .separator:
            return .separator()
        case .header:
            return .sectionHeader(title: item.title)
        case .status:
            let menuItem = NSMenuItem(title: item.title, action: #selector(itemChosen(_:)), keyEquivalent: "")
            menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: Theme.Typography.caption.nsFont,
                .foregroundColor: Theme.Colors.warning.hexColor,
            ])
            menuItem.image = Self.dotImage(color: Theme.Colors.warningDot.hexColor)
            menuItem.target = self
            menuItem.tag = tag
            menuItem.isEnabled = item.isEnabled
            return menuItem
        case .action:
            let menuItem = NSMenuItem(title: item.title, action: #selector(itemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = tag
            menuItem.isEnabled = item.isEnabled
            if let key = item.keyEquivalent {
                menuItem.keyEquivalent = key.key
                menuItem.keyEquivalentModifierMask = Self.modifierMask(key)
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
                menuItem.toolTip = "Show this capture again"
            }
            return menuItem
        }
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
    static func thumbnailImage(_ image: CGImage?) -> NSImage {
        let side = Theme.Menu.thumbnailSize
        return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Menu.thumbnailRadius, yRadius: Theme.Menu.thumbnailRadius)
            path.addClip()
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
            if let image {
                let factor = max(rect.width / Double(image.width), rect.height / Double(image.height))
                let size = CGSize(width: Double(image.width) * factor, height: Double(image.height) * factor)
                NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height
                ))
            }
            NSColor(white: 0, alpha: 0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    static func dotImage(color: NSColor) -> NSImage {
        let side = Theme.Menu.statusDotSize
        return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
