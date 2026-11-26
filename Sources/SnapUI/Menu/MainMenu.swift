import AppKit

/// The app's main menu. Still is an accessory app, so the menu never shows in the menu bar, but
/// AppKit still matches key equivalents against it while one of Still's windows is key: without
/// it, Cmd-C, Cmd-V, Cmd-A and Cmd-Z did nothing in text fields and Cmd-W did not close windows.
public enum MainMenu {
    public static func make() -> NSMenu {
        let main = NSMenu(title: "Main")
        main.addItem(submenu("Still", [
            item("Hide Still", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Still", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ]))
        return main
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        parent.submenu = menu
        return parent
    }
}
