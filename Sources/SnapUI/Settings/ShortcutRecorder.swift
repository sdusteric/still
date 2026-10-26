import AppKit
import SnapCore
import SwiftUI

/// What a key press means while a recorder is listening.
public enum ShortcutRecordingOutcome: Equatable, Sendable {
    case record(KeyShortcut)
    /// Esc: stop listening, keep the old shortcut.
    case cancel
    /// Delete or Backspace without modifiers: remove the shortcut.
    case clear
    /// Not usable as a global shortcut (no Command, Control or Option); keep listening.
    case ignore

    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    /// F1 to F12 work without modifiers.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// Pure, so the rules are unit tested: `flags` are `NSEvent.ModifierFlags` raw bits.
    public static func interpret(keyCode: UInt16, modifierFlags flags: UInt) -> ShortcutRecordingOutcome {
        let modifiers = HotkeyCombo.carbonModifiers(fromEventFlags: flags)
        let strong = KeyShortcut.Modifier.command | KeyShortcut.Modifier.control | KeyShortcut.Modifier.option
        if modifiers == 0 {
            if keyCode == escape { return .cancel }
            if keyCode == delete || keyCode == forwardDelete { return .clear }
        }
        guard modifiers & strong != 0 || functionKeys.contains(keyCode) else { return .ignore }
        return .record(KeyShortcut(keyCode: UInt32(keyCode), modifiers: modifiers))
    }
}

extension HotkeyCombo {
    /// The recorder chip text: modifier symbols and key separated by thin spaces, as in the mockup.
    var chipText: String {
        (modifierSymbols.map { String($0) } + [keyName]).joined(separator: " ")
    }
}

/// A shortcut field for the Shortcuts tab (design 12.2, 17.6): a chip with the combo, or
/// "Record shortcut". Click to listen, press the new combo; Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Binding var shortcut: KeyShortcut?
    var onRecordingChange: (Bool) -> Void = { _ in }
    @State private var isRecording = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                setRecording(!isRecording)
            } label: {
                Text(label)
                    .font(shortcut == nil || isRecording ? Theme.Typography.caption.font : Theme.Typography.bodyEmphasis.font.monospacedDigit())
                    .foregroundStyle(shortcut == nil || isRecording ? Theme.Colors.deskText2.color : Theme.Colors.deskText.color)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: Theme.Controls.buttonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.Colors.fill.color)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.Colors.accent.color, lineWidth: isRecording ? 1.5 : 0)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if isRecording {
                    KeyCaptureView { outcome in handle(outcome) }
                        .frame(width: 1, height: 1)
                }
            }
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(shortcut.map { HotkeyCombo($0).plainString } ?? "none")
            .help(isRecording ? "Press the new shortcut. Esc cancels, Delete clears." : "Click to record a shortcut")

            if shortcut != nil, isHovering, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.text3.color)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(action.title) shortcut")
            }
        }
        .onHover { isHovering = $0 }
    }

    private var label: String {
        if isRecording { return "Type shortcut" }
        guard let shortcut else { return "Record shortcut" }
        return HotkeyCombo(shortcut).chipText
    }

    private func setRecording(_ value: Bool) {
        isRecording = value
        onRecordingChange(value)
    }

    private func handle(_ outcome: ShortcutRecordingOutcome) {
        switch outcome {
        case .record(let new):
            shortcut = new
            setRecording(false)
        case .clear:
            shortcut = nil
            setRecording(false)
        case .cancel:
            setRecording(false)
        case .ignore:
            break
        }
    }
}

/// Takes key focus while a recorder listens and reports every key down.
private struct KeyCaptureView: NSViewRepresentable {
    let onKey: (ShortcutRecordingOutcome) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        view.onKey = onKey
    }
}

private final class KeyCaptureNSView: NSView {
    var onKey: ((ShortcutRecordingOutcome) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        onKey?(ShortcutRecordingOutcome.interpret(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        onKey?(ShortcutRecordingOutcome.interpret(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue))
        return true
    }

    override func resignFirstResponder() -> Bool {
        onKey?(.cancel)
        return true
    }
}
