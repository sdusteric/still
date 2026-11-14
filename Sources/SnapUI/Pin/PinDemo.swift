import AppKit
import SnapCore
import SwiftUI

/// Sample content of the M2 mockup scenes (`docs/mockup/index.html` sections 8, 9 and 11c), drawn
/// simply in Core Graphics: the wallpaper, the menu bar, app windows, a terminal, a palette, a
/// chat and a settings form. Shared by `PinDemo`, `HistoryDemo` and the video card scene so the
/// shots measure the design, not a different composition.
enum M2DemoArt {
    // MARK: Colors of the mockup's fake desktop (its `--wall`, `--w-*` and `--term` values)

    static func wallpaperStops(dark: Bool) -> [CGColor] {
        dark
            ? [rgb(0x1B2440), rgb(0x2B2142), rgb(0x3A2A36)]
            : [rgb(0xC4D3EE), rgb(0xE2D2EC), rgb(0xF1DCCB)]
    }

    static func rgb(_ hex: UInt32, alpha: Double = 1) -> CGColor { ThemeRGBA(hex: hex, alpha: alpha).cgColor }
    static func ns(_ hex: UInt32, alpha: Double = 1) -> NSColor { ThemeRGBA(hex: hex, alpha: alpha).nsColor }

    static func text(dark: Bool) -> NSColor { Theme.Colors.text.hexColor(dark: dark) }
    static func text2(dark: Bool) -> NSColor { Theme.Colors.text2.hexColor(dark: dark) }

    // MARK: Canvas

    /// A flipped (top-left) bitmap of `size` points at `scale`, with AppKit text drawing set up.
    static func render(size: CGSize, scale: Double, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = SyntheticImages.makeContext(
            width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded())
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func font(_ size: Double, _ weight: NSFont.Weight = .regular, mono: Bool = false) -> NSFont {
        mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    /// One line whose CSS line box starts at `y`: the glyphs are centered in `lineHeight`.
    static func line(_ string: String, x: Double, y: Double, font: NSFont, color: NSColor, lineHeight: Double) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let height = (string as NSString).size(withAttributes: attributes).height
        (string as NSString).draw(at: CGPoint(x: x, y: y + (lineHeight - height) / 2), withAttributes: attributes)
    }

    static func lineWidth(_ string: String, font: NSFont) -> Double {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// Wrapped text in `rect`; returns the height used.
    @discardableResult
    static func paragraph(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, lineHeight: Double) -> Double {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let bounds = (string as NSString).boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attributes
        )
        (string as NSString).draw(with: CGRect(origin: rect.origin, size: CGSize(width: rect.width, height: bounds.height + 1)),
                                  options: [.usesLineFragmentOrigin], attributes: attributes)
        return ceil(bounds.height)
    }

    static func fillRounded(_ rect: CGRect, radius: Double, color: CGColor, in context: CGContext) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }

    /// Draws `image` upright into `rect` of a flipped context.
    static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        OverlayDrawing.drawImage(image, in: rect, context: context)
    }

    /// A CSS `box-shadow` approximated with one Core Graphics shadow. Offsets and blur are in
    /// points; Core Graphics takes them in device pixels with y up.
    static func setShadow(y: Double, blur: Double, alpha: Double, scale: Double, in context: CGContext) {
        context.setShadow(offset: CGSize(width: 0, height: -y * scale), blur: blur * scale, color: CGColor(gray: 0, alpha: alpha))
    }

    // MARK: Desktop

    /// The mockup's `--wall`: a 135 degree gradient with stops at 0, 55% and 100%.
    static func wallpaper(_ rect: CGRect, dark: Bool, in context: CGContext) {
        let reach = (rect.width + rect.height) / 4
        let start = CGPoint(x: rect.midX - reach, y: rect.midY - reach)
        let end = CGPoint(x: rect.midX + reach, y: rect.midY + reach)
        guard let gradient = CGGradient(
            colorsSpace: SyntheticImages.colorSpace, colors: wallpaperStops(dark: dark) as CFArray, locations: [0, 0.55, 1]
        ) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// The 24 pt menu bar: Notes, File, Edit, View, Window, the Snap symbol and the clock. With
    /// `badge`, the symbol carries the permission badge as the status item draws it (design 13).
    static func menuBar(width: Double, dark: Bool, badge: Bool = false, in context: CGContext) {
        context.setFillColor(dark ? rgb(0x141418, alpha: 0.5) : CGColor(gray: 1, alpha: 0.42))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
        let color = text(dark: dark)
        var x = 14.0
        line("Notes", x: x, y: 0, font: font(13, .bold), color: color, lineHeight: 24)
        x += lineWidth("Notes", font: font(13, .bold)) + 16
        for item in ["File", "Edit", "View", "Window"] {
            line(item, x: x, y: 0, font: font(13, .medium), color: color, lineHeight: 24)
            x += lineWidth(item, font: font(13, .medium)) + 16
        }
        let clock = "Sat 14:03"
        let clockWidth = lineWidth(clock, font: font(13, .medium))
        line(clock, x: width - 14 - clockWidth, y: 0, font: font(13, .medium), color: color, lineHeight: 24)
        let icon = CGRect(x: width - 14 - clockWidth - 14 - 15, y: 4.5, width: 15, height: 15)
        guard badge else {
            viewfinder(in: icon, color: color.cgColor, context: context)
            return
        }
        // The symbol in its own layer with a hole where the badge sits, then the badge in it.
        let side = Theme.Menu.badgeSize + 2 * Theme.Menu.badgeGap
        let center = StatusBadgeView.center(inSymbolOf: icon.size)
        let hole = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        if let layer = render(size: icon.size, scale: 4, { layerContext in
            viewfinder(in: CGRect(origin: .zero, size: icon.size), color: color.cgColor, context: layerContext)
            layerContext.setBlendMode(.clear)
            layerContext.fillEllipse(in: hole)
        }) {
            draw(layer, in: icon, context: context)
        }
        StatusBadgeView.draw(
            in: hole.offsetBy(dx: icon.minX, dy: icon.minY), color: Theme.Colors.warningDot.cgColor(dark: dark), context: context
        )
    }

    /// The viewfinder symbol: four corner brackets and a dot ring, stroked in `rect`.
    static func viewfinder(in icon: CGRect, color: CGColor, context: CGContext) {
        context.setStrokeColor(color)
        context.setLineWidth(1.4)
        let box = icon.insetBy(dx: 1.5, dy: 1.5)
        let arm = 3.5
        for (corner, dx, dy) in [
            (CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
            (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0),
        ] {
            context.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            context.addLine(to: corner)
            context.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: icon.midX - 2.5, y: icon.midY - 2.5, width: 5, height: 5))
    }

    static func trafficLights(x: Double, centerY: Double, size: Double = 12, gap: Double = 8, in context: CGContext) {
        for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            context.setFillColor(rgb(hex))
            context.fillEllipse(in: CGRect(x: x + Double(index) * (size + gap), y: centerY - size / 2, width: size, height: size))
        }
    }

    /// A mockup `.win`: radius 16, the window shadow and edge, filled with the window color. `body`
    /// draws the content clipped to the window.
    static func window(_ frame: CGRect, dark: Bool, scale: Double, in context: CGContext, body: (CGRect) -> Void) {
        let path = CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
        context.saveGState()
        setShadow(y: 22, blur: 46, alpha: dark ? 0.62 : 0.30, scale: scale, in: context)
        context.addPath(path)
        context.setFillColor(Theme.Colors.window.cgColor(dark: dark))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        body(frame)
        context.restoreGState()
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.setStrokeColor(Theme.Colors.windowEdge.cgColor(dark: dark))
        context.setLineWidth(0.5)
        context.strokePath()
    }

    /// A mockup `.aw` window: a 40 pt bar with traffic lights and a centered title, then a body.
    static func appWindow(_ frame: CGRect, title: String, dark: Bool, scale: Double, in context: CGContext, body: (CGRect) -> Void) {
        window(frame, dark: dark, scale: scale, in: context) { frame in
            trafficLights(x: frame.minX + 14, centerY: frame.minY + 20, in: context)
            let titleFont = font(13, .semibold)
            line(title, x: frame.midX - lineWidth(title, font: titleFont) / 2, y: frame.minY, font: titleFont,
                 color: text(dark: dark), lineHeight: 40)
            context.setFillColor(Theme.Colors.separator.cgColor(dark: dark))
            context.fill(CGRect(x: frame.minX, y: frame.minY + 39, width: frame.width, height: 1))
            body(CGRect(x: frame.minX, y: frame.minY + 40, width: frame.width, height: frame.height - 40))
        }
    }

    /// The browser window of the pin scene.
    static func browserBody(_ rect: CGRect, dark: Bool) {
        let left = rect.minX + 18
        line("docs.local", x: left, y: rect.minY + 18, font: font(13, .bold), color: text(dark: dark), lineHeight: 18)
        line("Release notes", x: left, y: rect.minY + 44, font: font(13), color: text(dark: dark), lineHeight: 20)
        paragraph(
            "Every capture is written to history before anything else can fail.",
            in: CGRect(x: left, y: rect.minY + 72, width: rect.width - 36, height: 60),
            font: font(13), color: text2(dark: dark), lineHeight: 20
        )
    }

    // MARK: Captured content

    struct TerminalLine {
        enum Tone { case comment, plain, ok }
        var text: String
        var tone: Tone

        static func comment(_ text: String) -> TerminalLine { TerminalLine(text: text, tone: .comment) }
        static func plain(_ text: String) -> TerminalLine { TerminalLine(text: text, tone: .plain) }
        static func ok(_ text: String) -> TerminalLine { TerminalLine(text: "\u{2714} " + text, tone: .ok) }
    }

    static let buildLines: [TerminalLine] = [
        .comment("$ make demo"), .plain("building Still.app"), .ok("compiled 112 files"), .ok("signed"),
        .plain("launching shot mode"), .ok("20 shots written"), .plain("comparing with mockup"),
        .ok("all regions match"), .plain("done in 42 s"),
    ]

    static let testLines: [TerminalLine] = [
        .comment("$ swift test --filter PinBoardTests"), .plain("Suite PinBoardTests started"),
        .ok("placesAtCaptureRectWhenOnScreen"), .ok("clampsToVisibleFrame"), .ok("opacityStepsAndFloor"),
        .ok("ninthPinClosesOldest"), .plain("Test run with 4 tests passed"),
    ]

    /// The mockup's `.term`: 12/18 monospaced lines on #1C1C1E (#141416 dark), with the three-dot
    /// bar when `bar` is on, or an empty `top` band above the text.
    static func terminal(_ lines: [TerminalLine], size: CGSize, dark: Bool, bar: Bool, top: Double = 0, scale: Double = 2) -> CGImage? {
        render(size: size, scale: scale) { context in
            context.setFillColor(rgb(dark ? 0x141416 : 0x1C1C1E))
            context.fill(CGRect(origin: .zero, size: size))
            var y = top
            if bar {
                for index in 0..<3 {
                    context.setFillColor(rgb(0x4A4A4E))
                    context.fillEllipse(in: CGRect(x: 9 + Double(index) * 14, y: 7, width: 8, height: 8))
                }
                y = 22
            }
            y += 6
            let mono = font(12, mono: true)
            for item in lines {
                let color: NSColor = switch item.tone {
                case .comment: ns(0x8E8E93)
                case .plain: ns(0xE5E5EA)
                case .ok: ns(0x5BE37D)
                }
                line(item.text, x: 12, y: y, font: mono, color: color, lineHeight: 18)
                y += 18
            }
        }
    }

    /// The mockup's `.pal`: "Brand colors", six swatches and a contrast note on white.
    static func palette(size: CGSize, scale: Double = 2) -> CGImage? {
        render(size: size, scale: scale) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            line("Brand colors", x: 16, y: 14, font: font(13, .semibold), color: ns(0x1D1D1F), lineHeight: 18)
            let swatches: [UInt32] = [0x5B6CFF, 0xB65BFF, 0xFF5E62, 0xFFB347, 0x2BC0E4, 0x30D158]
            let width = (size.width - 32 - 6 * 5) / 6
            for (index, hex) in swatches.enumerated() {
                fillRounded(CGRect(x: 16 + Double(index) * (width + 6), y: 42, width: width, height: 64), radius: 6,
                            color: rgb(hex), in: context)
            }
            line("Accent #5B6CFF on white, 4.9:1", x: 16, y: 116, font: font(11), color: ns(0x6E6E73), lineHeight: 15)
        }
    }

    /// The mockup's `.minichat`: two grey bubbles and one blue one on white.
    static func chat(size: CGSize, scale: Double = 2) -> CGImage? {
        render(size: size, scale: scale) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let messages: [(String, Bool)] = [
                ("Can you check the spacing on the card?", false),
                ("8 pt between cards, 16 from the edge.", true),
                ("Perfect, shipping it.", false),
            ]
            let bubbleFont = font(11)
            let maxText = (size.width - 24) * 0.78 - 18
            var y = 12.0
            for (message, mine) in messages {
                let measured = (message as NSString).boundingRect(
                    with: CGSize(width: maxText, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: bubbleFont]
                )
                let lines = max((measured.height / 13).rounded(), 1)
                let textWidth = min(ceil(measured.width), maxText)
                let bubble = CGRect(
                    x: mine ? size.width - 12 - textWidth - 18 : 12, y: y,
                    width: textWidth + 18, height: lines * 15 + 10
                )
                fillRounded(bubble, radius: 12, color: mine ? rgb(0x007AFF) : rgb(0xE9E9EB), in: context)
                paragraph(message, in: bubble.insetBy(dx: 9, dy: 5), font: bubbleFont,
                          color: mine ? .white : ns(0x1D1D1F), lineHeight: 15)
                y = bubble.maxY + 6
            }
        }
    }

    /// The mockup's `.miniform`: the Recording settings rows.
    static func form(size: CGSize, scale: Double = 2) -> CGImage? {
        render(size: size, scale: scale) { context in
            context.setFillColor(rgb(0xF3F3F5))
            context.fill(CGRect(origin: .zero, size: size))
            line("Recording", x: 12, y: 12, font: font(11, .semibold), color: ns(0x1D1D1F), lineHeight: 15)
            var y = 33.0
            for (label, value) in [("Format", "H.264"), ("Frame rate", "30 fps"), ("Countdown", "3 s")] {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 12, y: y, width: size.width - 24, height: 27))
                context.setFillColor(CGColor(gray: 0, alpha: 0.06))
                context.fill(CGRect(x: 12, y: y + 27, width: size.width - 24, height: 1))
                line(label, x: 20, y: y + 6, font: font(11), color: ns(0x1D1D1F), lineHeight: 15)
                let valueWidth = lineWidth(value, font: font(11))
                line(value, x: size.width - 20 - valueWidth, y: y + 6, font: font(11), color: ns(0x6E6E73), lineHeight: 15)
                y += 28
            }
        }
    }

    /// The captured Notes window (842 x 516), as the Background editor shows it.
    static func notes(dark: Bool, scale: Double = 2) -> CGImage? {
        DemoCapture.notesWindow(dark: dark, scale: scale)
    }
}

extension ThemeColor {
    /// The mockup value for one appearance, for drawing outside a view.
    func hexColor(dark: Bool) -> NSColor { (dark ? self.dark : light).nsColor }
}

// MARK: Pin scene

/// The `pin` shot (mockup 8, design 20.11): the fake desktop with a hovered pin and its chrome, a
/// pin at 60% opacity and a click-through pin with its lock badge, at the mockup's positions.
public enum PinDemo {
    public static let sceneSize = CGSize(width: 1280, height: 800)
    static let notesFrame = CGRect(x: 200, y: 110, width: 842, height: 516)
    static let browserFrame = CGRect(x: 880, y: 250, width: 340, height: 420)
    static let hoveredFrame = CGRect(x: 700, y: 300, width: 460, height: 268)
    static let fadedFrame = CGRect(x: 72, y: 520, width: 300, height: 188)
    static let lockedFrame = CGRect(x: 446, y: 610, width: 220, height: 150)

    /// The desktop behind the pins: wallpaper, menu bar, the browser and the Notes window.
    public static func desktop(dark: Bool, scale: Double = 2) -> CGImage? {
        let notes = M2DemoArt.notes(dark: dark, scale: scale)
        return M2DemoArt.render(size: sceneSize, scale: scale) { context in
            M2DemoArt.wallpaper(CGRect(origin: .zero, size: sceneSize), dark: dark, in: context)
            M2DemoArt.appWindow(browserFrame, title: "Browser", dark: dark, scale: scale, in: context) { body in
                M2DemoArt.browserBody(body, dark: dark)
            }
            M2DemoArt.window(notesFrame, dark: dark, scale: scale, in: context) { frame in
                if let notes { M2DemoArt.draw(notes, in: frame, context: context) }
            }
            M2DemoArt.menuBar(width: sceneSize.width, dark: dark, in: context)
        }
    }

    /// The three pins of the scene. Their content does not follow the appearance, as captures do not.
    public static func pins(dark: Bool) -> [PinModel] {
        guard let terminal = M2DemoArt.terminal(M2DemoArt.testLines, size: hoveredFrame.size, dark: dark, bar: false, top: 34),
              let palette = M2DemoArt.palette(size: fadedFrame.size),
              let chat = M2DemoArt.chat(size: lockedFrame.size) else { return [] }
        let hovered = PinModel(id: 1, itemID: "demo-terminal", image: terminal, pointSize: hoveredFrame.size,
                               isOpaque: true, frame: hoveredFrame)
        hovered.isHovered = true
        let faded = PinModel(id: 2, itemID: "demo-palette", image: palette, pointSize: fadedFrame.size,
                             isOpaque: true, frame: fadedFrame, opacity: 0.6)
        let locked = PinModel(id: 3, itemID: "demo-chat", image: chat, pointSize: lockedFrame.size,
                              isOpaque: true, frame: lockedFrame)
        locked.clickThrough = true
        return [faded, locked, hovered]
    }

    public static func scene(dark: Bool) -> some View {
        let desktop = desktop(dark: dark)
        return ZStack(alignment: .topLeading) {
            if let desktop {
                Image(decorative: desktop, scale: 2)
                    .frame(width: sceneSize.width, height: sceneSize.height)
            }
            ForEach(pins(dark: dark)) { pin in
                PinView(model: pin, drawsShadow: true, interactive: false)
                    .offset(x: pin.frame.minX, y: pin.frame.minY)
            }
        }
        .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// The scene at `scale` through `ImageRenderer`: no window, no panel.
    public static func renderScene(dark: Bool, scale: Double = 2) -> CGImage? {
        QuickAccessDemo.render(scene(dark: dark), size: sceneSize, dark: dark, scale: scale)
    }
}
