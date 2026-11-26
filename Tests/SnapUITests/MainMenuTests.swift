import AppKit
@testable import SnapUI
import Testing

@MainActor
@Suite struct MainMenuTests {
    /// The key equivalents text fields and windows need; an accessory app has no menu unless it
    /// installs one, and then Cmd-V in the Settings file name field did nothing.
    @Test func theMainMenuCarriesEditingAndWindowKeys() throws {
        let menu = MainMenu.make()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        func item(_ key: String, _ action: Selector, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.action == action && $0.keyEquivalentModifierMask == modifiers }
        }
        #expect(item("x", #selector(NSText.cut(_:))) != nil)
        #expect(item("c", #selector(NSText.copy(_:))) != nil)
        #expect(item("v", #selector(NSText.paste(_:))) != nil)
        #expect(item("a", #selector(NSText.selectAll(_:))) != nil)
        #expect(item("z", Selector(("undo:"))) != nil)
        #expect(item("z", Selector(("redo:")), modifiers: [.command, .shift]) != nil)
        #expect(item("w", #selector(NSWindow.performClose(_:))) != nil)
        #expect(item("q", #selector(NSApplication.terminate(_:))) != nil)
    }
}
