import AppKit
import Observation
import SnapCore
import SwiftUI

/// The settings window (design 12.2): titled, 480 pt wide, the title follows the tab. It
/// activates Snap, since it takes text and shortcut input. Never created in tests or shot mode
/// (use `SettingsDemo`).
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let model: SettingsModel
    /// Called when the window opens, so the app can re-read symbolic hotkeys and the permission.
    public var onOpen: (() -> Void)?

    public init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: SettingsDemo.size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.sizingOptions = []
        window.contentView = host
        super.init(window: window)
        window.delegate = self
        updateTitle()
        observeTab()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func observeTab() {
        withObservationTracking {
            _ = model.tab
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateTitle()
                self?.observeTab()
            }
        }
    }

    private func updateTitle() {
        window?.title = model.tab.title
    }

    /// Shows the window on `tab` (or the last one), centered the first time, and activates Snap.
    public func present(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        onOpen?()
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
