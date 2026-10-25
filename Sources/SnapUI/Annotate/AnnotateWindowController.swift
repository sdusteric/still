import AppKit
import SnapCore
import SwiftUI

/// The annotate editor content: the 52 pt toolbar above the canvas. In the real window the
/// toolbar lives in the title bar (`AnnotateWindowController`); for shots and tests it is drawn
/// inline so the whole editor renders without a window.
public final class AnnotateEditorView: NSView {
    public let canvas: AnnotateCanvasView
    public var model: AnnotateEditorModel { canvas.model }
    private let toolbarHost: NSView?
    /// The Redact style menu drawn over the canvas, for the shot only (a real menu cannot open there).
    private let styleMenuHost: NSView?

    /// Where the style menu hangs in the shot: under the style popup (mockup 12).
    static let styleMenuOrigin = CGPoint(x: 428, y: 48)

    public init(document: AnnotationDocument, model: AnnotateEditorModel, inlineToolbar: Bool, showsStyleMenu: Bool = false) {
        canvas = AnnotateCanvasView(document: document, model: model)
        toolbarHost = inlineToolbar ? NSHostingView(rootView: InlineToolbar(model: model)) : nil
        styleMenuHost = showsStyleMenu ? NSHostingView(rootView: RedactStyleMenu(model: model, framed: true)) : nil
        super.init(frame: CGRect(origin: .zero, size: Theme.Annotate.windowSize))
        addSubview(canvas)
        if let toolbarHost { addSubview(toolbarHost) }
        if let styleMenuHost { addSubview(styleMenuHost) }
        layoutParts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool { true }

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutParts()
    }

    private func layoutParts() {
        let toolbarHeight = toolbarHost == nil ? 0 : Theme.Annotate.toolbarHeight
        toolbarHost?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)
        canvas.frame = CGRect(x: 0, y: toolbarHeight, width: bounds.width, height: max(bounds.height - toolbarHeight, 0))
        if let styleMenuHost {
            let size = styleMenuHost.fittingSize
            let inset = RedactStyleMenu.shadowInset
            styleMenuHost.frame = CGRect(
                x: Self.styleMenuOrigin.x - inset, y: Self.styleMenuOrigin.y - inset, width: size.width, height: size.height
            )
        }
    }
}

/// The toolbar as the window draws it: `window` background, traffic lights, hairline below.
private struct InlineToolbar: View {
    let model: AnnotateEditorModel

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.Colors.window.color
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                    Circle().fill(ThemeRGBA(hex: UInt32(hex)).color).frame(width: 12, height: 12)
                }
            }
            .padding(.leading, 20)
            .accessibilityHidden(true)
            AnnotateToolbar(model: model)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.separator.color).frame(height: 1)
        }
    }
}

extension ThemeRGBA {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// The annotate window (design 11, 17.6): titled, 1100 x 720 by default, sized to fit the image
/// at up to 80% of the visible frame, minimum 560 x 400, toolbar in a unified 52 pt title bar.
/// It activates Snap, since an editor needs keyboard focus. Never created in tests or shot mode.
public final class AnnotateWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static let toolbarItem = NSToolbarItem.Identifier("dev.sdusteric.snap.annotate.tools")

    public let editor: AnnotateEditorView
    /// Called after the window closes. Closing never prompts: the original is in history.
    public var onClose: (() -> Void)?

    public init(document: AnnotationDocument, actions: AnnotateActions) {
        let model = AnnotateEditorModel(actions: actions)
        editor = AnnotateEditorView(document: document, model: model, inlineToolbar: false)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Theme.Annotate.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Annotate"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = Theme.Annotate.minimumSize
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.contentView = editor
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "dev.sdusteric.snap.annotate")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The window size for an image of `imageSize` points: the image plus room for the toolbar and
    /// padding, at most 80% of `visibleFrame`, at least the minimum size.
    public static func windowSize(forImage imageSize: CGSize, visibleFrame: CGRect) -> CGSize {
        let padding = 2 * AnnotateCanvasView.padding
        let wanted = CGSize(
            width: imageSize.width + padding, height: imageSize.height + padding + Theme.Annotate.toolbarHeight
        )
        let limit = CGSize(width: visibleFrame.width * 0.8, height: visibleFrame.height * 0.8)
        return CGSize(
            width: max(min(wanted.width, limit.width), Theme.Annotate.minimumSize.width),
            height: max(min(wanted.height, limit.height), Theme.Annotate.minimumSize.height)
        )
    }

    /// Sizes and centers the window on the screen under the pointer, activates Snap and shows it.
    public func present() {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = Self.windowSize(forImage: editor.canvas.document.outputRect.size, visibleFrame: visible)
            window.setFrame(
                CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
                display: false
            )
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.canvas)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolbarItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolbarItem]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let host = NSHostingView(rootView: AnnotateToolbar(model: editor.model, leadingInset: 0, barHeight: nil))
        host.translatesAutoresizingMaskIntoConstraints = false
        let wide = host.widthAnchor.constraint(equalToConstant: 4000)
        wide.priority = .defaultLow
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            wide,
        ])
        item.view = host
        item.label = "Tools"
        return item
    }
}

/// The annotate editor with a sample capture, for tests and shots: one item of each M1 kind with
/// the Rectangle tool active (mockup section 4), and the M2 tools state of mockup 12.
public enum AnnotateDemo {
    public static let size = Theme.Annotate.windowSize

    public static func makeDocument(dark: Bool = false) -> AnnotationDocument? {
        guard let capture = DemoCapture.notesWindow(dark: dark) else { return nil }
        var document = AnnotationDocument(image: capture, scale: 2)
        document.add(.rectangle(CGRect(x: 226, y: 170, width: 296, height: 18)))
        document.add(.arrow(from: CGPoint(x: 600, y: 290), to: CGPoint(x: 522, y: 192)))
        document.add(.text("this one", at: CGPoint(x: 556, y: 292)))
        document.add(.pixelate(CGRect(x: 344, y: 203, width: 110, height: 18)))
        return document
    }

    /// The editor content (inline toolbar and canvas) at 1100 x 720 with the appearance set.
    public static func makeView(dark: Bool = false) -> NSView {
        guard let document = makeDocument(dark: dark) else { return NSView(frame: CGRect(origin: .zero, size: size)) }
        let model = AnnotateEditorModel()
        model.tool = .rectangle
        // The four items were drawn in this session, so Undo is available (mockup 4).
        model.canUndo = true
        let view = AnnotateEditorView(document: document, model: model, inlineToolbar: true)
        view.canvas.setSelection(document.items.first?.id)
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }

    // MARK: Reopened from history (design 20.4, `annotations.json`)

    /// The M1 sample's annotations as History keeps them: written to `annotations.json` and read
    /// back, with the Background on, so the shot shows the same path the app takes.
    public static func makeReopenedDocument(dark: Bool = false) -> (AnnotationDocument, AnnotationFile)? {
        guard let capture = DemoCapture.notesWindow(dark: dark), let sample = makeDocument(dark: dark) else { return nil }
        var preset = BackgroundPreset.factoryDefault
        preset.name = "Default"
        let stored = AnnotationFile(document: sample, background: preset)
        do {
            let file = try JSONDecoder().decode(AnnotationFile.self, from: JSONEncoder().encode(stored))
            return (file.document(image: capture, scale: 2), file)
        } catch {
            return nil
        }
    }

    /// The editor reopened from History: Select active, the arrow selected with its handles, and
    /// the toolbar saying the Background is on.
    public static func makeReopenedView(dark: Bool = false) -> NSView {
        guard let (document, file) = makeReopenedDocument(dark: dark) else {
            return NSView(frame: CGRect(origin: .zero, size: size))
        }
        let model = AnnotateEditorModel(actions: AnnotateActions(backgroundApplied: file.background != nil))
        model.tool = .select
        let view = AnnotateEditorView(document: document, model: model, inlineToolbar: true)
        view.canvas.setSelection(document.items.first { $0.kind == .arrow }?.id)
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }

    // MARK: Tools (mockup 12)

    /// The sample capture with a blurred sidebar row, a black-out over the token, a highlight, a
    /// freehand loop and three steps, laid out on `DemoCapture.notesWindow`.
    public static func makeToolsDocument(dark: Bool = false) -> AnnotationDocument? {
        guard let capture = DemoCapture.notesWindow(dark: dark) else { return nil }
        var document = AnnotationDocument(image: capture, scale: 2)
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let cell = ("0" as NSString).size(withAttributes: [.font: mono]).width
        let line = ("The only edit I ever make is a gradient behind the window. That is one click now, and the" as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        document.add(.redact(CGRect(x: 8, y: 90, width: 182, height: 44), style: .blur))
        // "export SNAP_TOKEN=" is 18 cells; the black-out covers the token but for its last character.
        document.add(.redact(CGRect(x: 232 + 18 * cell, y: 202, width: 16 * cell, height: 17), style: .blackout))
        document.add(.highlight(CGRect(x: 218, y: 245, width: line + 4, height: 21)))
        let loop = (0...64).map { index -> CGPoint in
            let angle = (-160 + Double(index) * 5.4) * .pi / 180
            return CGPoint(x: 262 + cos(angle) * 58, y: 308 + sin(angle) * 22)
        }
        document.add(.freehand(FreehandPath.decimated(loop)))
        document.add(.step(at: CGPoint(x: 206, y: 70)))
        document.add(.step(at: CGPoint(x: 650, y: 186)))
        document.add(.step(at: CGPoint(x: 210, y: 258)))
        return document
    }

    /// The editor with the Redact tool active, its style menu open on Black-out and step 2
    /// selected, at 1100 x 720 with the appearance set.
    public static func makeToolsView(dark: Bool = false) -> NSView {
        guard let document = makeToolsDocument(dark: dark) else { return NSView(frame: CGRect(origin: .zero, size: size)) }
        let model = AnnotateEditorModel()
        model.tool = .redact
        model.redactStyle = .blackout
        model.canUndo = true
        let view = AnnotateEditorView(document: document, model: model, inlineToolbar: true, showsStyleMenu: true)
        view.canvas.setSelection(document.items.filter { $0.kind == .step }.dropFirst().first?.id)
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }
}
