import AppKit
import SnapCore

/// The text field placed over the annotate canvas while a text item is typed (design section 11:
/// click to place, 30 pt semibold). Return or a click elsewhere commits; Esc cancels. Option+Return
/// starts a new line.
final class TextEditingOverlay: NSTextField, NSTextFieldDelegate {
    /// The item being edited (a new one is not in the document yet).
    let itemID: UUID
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init(itemID: UUID, text: String, fontSize: Double, color: RGBAColor) {
        self.itemID = itemID
        super.init(frame: .zero)
        stringValue = text
        font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        textColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = false
        cell?.wraps = false
        cell?.isScrollable = false
        lineBreakMode = .byClipping
        placeholderString = "Text"
        delegate = self
        setAccessibilityLabel("Annotation text")
        resize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Places the field with its top-left at `origin` (view points, flipped) and focuses it.
    func begin(in view: NSView, at origin: CGPoint) {
        view.addSubview(self)
        setFrameOrigin(CGPoint(x: origin.x - 2, y: origin.y))
        resize()
        view.window?.makeFirstResponder(self)
    }

    private func resize() {
        let size = cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 4000, height: 4000)) ?? .zero
        setFrameSize(CGSize(width: max(size.width + 12, 40), height: max(size.height, (font?.pointSize ?? 30) * 1.25)))
    }

    func controlTextDidChange(_ notification: Notification) {
        resize()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            resize()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        default:
            return false
        }
    }

    func commit() {
        guard !finished else { return }
        finished = true
        let text = stringValue
        removeFromSuperview()
        onCommit?(text)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        removeFromSuperview()
        onCancel?()
    }
}
