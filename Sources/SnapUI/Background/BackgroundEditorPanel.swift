import AppKit
import SnapCore
import SwiftUI

/// The Background editor window (design 10.4, 17.6): a floating titled panel, 920 x 640, titled
/// "Background". It activates Snap because it takes slider and text input, and it is only ever
/// opened by the user. Never created in tests or shot mode (use `BackgroundEditorDemo`).
public final class BackgroundEditorPanel: NSPanel {
    public let model: BackgroundEditorModel
    /// Called once the panel has closed, so the owner can drop its reference.
    public var onClose: (() -> Void)?

    public init(model: BackgroundEditorModel) {
        self.model = model
        super.init(
            contentRect: CGRect(origin: .zero, size: Theme.BackgroundEditor.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        title = "Background"
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        contentMinSize = Theme.BackgroundEditor.windowSize
        contentView = NSHostingView(rootView: BackgroundEditorView(model: model))
        setContentSize(Theme.BackgroundEditor.windowSize)

        let close = model.actions.close
        model.actions.close = { [weak self] in
            close()
            self?.close()
        }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    /// Centers the panel on the screen under the pointer and brings Snap forward.
    public func present() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override public func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    /// Esc closes, as the design asks, even when a text field has focus.
    override public func cancelOperation(_ sender: Any?) {
        close()
    }
}
