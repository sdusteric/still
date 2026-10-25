import AppKit
import SnapCore

/// One control of the all-in-one HUD toolbar (design 20.5, mockup 10).
public enum AllInOneToolbarItem: Sendable, Hashable {
    case close
    case mode(HUDMode)
    case target(CaptureMode)
    case options
    /// "Capture" in Screenshot mode, "Record" in Record mode.
    case primary

    /// The tooltip, with the key for the targets and the mode switch.
    public var tooltip: String {
        switch self {
        case .close: "Close (Esc)"
        case .mode(let mode): "\(mode.title) (R)"
        case .target(let target):
            switch target {
            case .area: "Area (1)"
            case .window: "Window (2)"
            case .fullscreen: "Fullscreen (3)"
            }
        case .options: "Options"
        case .primary: "Confirm (Return)"
        }
    }
}

/// The toolbar's geometry for one mode, in toolbar-local points (top-left origin). Pure apart from
/// text measurement, and cached per mode so the hotkey path never measures text (design 20.5:
/// the toolbar is pre-built).
public struct AllInOneToolbarLayout: Sendable, Equatable {
    public struct Slot: Sendable, Equatable {
        public var item: AllInOneToolbarItem
        public var frame: CGRect
    }

    public var mode: HUDMode
    public var size: CGSize
    /// Left to right: close, the two modes, the three targets, options, primary.
    public var slots: [Slot]
    public var dividers: [CGRect]
    /// The track behind the Screenshot | Record switch.
    public var segmentTrack: CGRect

    public static let targets: [CaptureMode] = [.area, .window, .fullscreen]

    public func frame(of item: AllInOneToolbarItem) -> CGRect? {
        slots.first { $0.item == item }?.frame
    }

    /// The control under a toolbar-local point.
    public func hit(_ point: CGPoint) -> AllInOneToolbarItem? {
        slots.first { $0.frame.contains(point) }?.item
    }

    public var items: [AllInOneToolbarItem] { slots.map(\.item) }

    @MainActor private static var cache: [HUDMode: AllInOneToolbarLayout] = [:]

    /// The layout for `mode`, measured once.
    @MainActor
    public static func layout(for mode: HUDMode) -> AllInOneToolbarLayout {
        if let cached = cache[mode] { return cached }
        let made = make(mode: mode)
        cache[mode] = made
        return made
    }

    /// Measures every control from the Theme tokens (20.5, 20.11): 44 pt bar, 6 pt padding and
    /// spacing, 30 pt close, a 28 pt two-part switch, 36 x 32 targets, Options, a 30 pt primary.
    @MainActor
    static func make(mode: HUDMode) -> AllInOneToolbarLayout {
        let hud = Theme.HUD.self
        let height = hud.barHeight
        var x = hud.barPadding
        var slots: [Slot] = []
        var dividers: [CGRect] = []

        func centered(width: Double, height itemHeight: Double) -> CGRect {
            CGRect(x: x, y: (height - itemHeight) / 2, width: width, height: itemHeight)
        }
        func addDivider() {
            x += hud.dividerMargin
            dividers.append(CGRect(
                x: x, y: (height - hud.dividerSize.height) / 2, width: hud.dividerSize.width, height: hud.dividerSize.height
            ))
            x += hud.dividerSize.width + hud.dividerMargin + hud.barSpacing
        }

        slots.append(Slot(item: .close, frame: centered(width: hud.closeButtonSize, height: hud.closeButtonSize)))
        x += hud.closeButtonSize + hud.barSpacing
        addDivider()

        let trackHeight = hud.segmentHeight + 2 * hud.segmentPadding
        let trackStart = x
        x += hud.segmentPadding
        for segment in HUDMode.allCases {
            let width = AllInOneToolbar.segmentWidth(segment)
            slots.append(Slot(item: .mode(segment), frame: centered(width: width, height: hud.segmentHeight)))
            x += width
        }
        x += hud.segmentPadding
        let track = CGRect(x: trackStart, y: (height - trackHeight) / 2, width: x - trackStart, height: trackHeight)
        x += hud.barSpacing
        addDivider()

        for (index, target) in targets.enumerated() {
            slots.append(Slot(item: .target(target), frame: centered(
                width: hud.targetButtonSize.width, height: hud.targetButtonSize.height
            )))
            x += hud.targetButtonSize.width
            // The three targets sit together as one group, as tight as the segment's padding.
            if index < targets.count - 1 { x += hud.segmentPadding }
        }
        x += hud.barSpacing
        addDivider()

        let optionsWidth = AllInOneToolbar.optionsWidth
        slots.append(Slot(item: .options, frame: centered(width: optionsWidth, height: hud.optionsHeight)))
        x += optionsWidth + hud.barSpacing

        let primaryWidth = AllInOneToolbar.primaryWidth(mode)
        slots.append(Slot(item: .primary, frame: centered(width: primaryWidth, height: hud.primaryHeight)))
        x += primaryWidth + hud.barPadding

        return AllInOneToolbarLayout(
            mode: mode, size: CGSize(width: x.rounded(.up), height: height), slots: slots, dividers: dividers,
            segmentTrack: track
        )
    }
}

/// Draws the HUD toolbar (design 20.5, 20.11 `hudBar`): the chip surface, flat, no blur, no
/// animation (rule 2 of 17.1, M16). Used by `SelectionOverlayView` in a flipped context.
@MainActor
public enum AllInOneToolbar {
    static let glyphGap = 6.0
    static let segmentGlyphSize = 13.0
    static let closeGlyphSize = 12.0
    static let chevronGap = 4.0
    static let chevronSize = 9.0
    static let recordRingRadius = 6.5
    static let recordDotRadius = 3.0

    static var segmentFont: NSFont { Theme.HUD.segmentLabelStyle.nsFont }
    static var optionsFont: NSFont { Theme.Typography.body.nsFont }
    static var primaryFont: NSFont { Theme.HUD.primaryStyle.nsFont }

    static func segmentWidth(_ mode: HUDMode) -> Double {
        let padding = Theme.HUD.segmentHorizontalPadding
        return (2 * padding + segmentGlyphSize + glyphGap + OverlayDrawing.textWidth(mode.title, font: segmentFont)).rounded(.up)
    }

    static var optionsWidth: Double {
        (2 * Theme.HUD.optionsHorizontalPadding + OverlayDrawing.textWidth("Options", font: optionsFont) + chevronGap
            + chevronSize).rounded(.up)
    }

    static func primaryWidth(_ mode: HUDMode) -> Double {
        let title = AllInOneState(mode: mode).primaryTitle
        return (2 * Theme.HUD.primaryHorizontalPadding + OverlayDrawing.textWidth(title, font: primaryFont)).rounded(.up)
    }

    /// The SF Symbol each target shows.
    static func symbol(for target: CaptureMode) -> String {
        switch target {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .fullscreen: "display"
        }
    }

    /// Draws the toolbar with its top-left corner at `origin`.
    static func draw(
        mode: HUDMode, target: CaptureMode, origin: CGPoint, context: CGContext, accent: CGColor, record: CGColor
    ) {
        let layout = AllInOneToolbarLayout.layout(for: mode)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        OverlayDrawing.drawChip(CGRect(origin: .zero, size: layout.size), radius: Theme.HUD.barRadius, context: context)

        context.setFillColor(Theme.Colors.hudDivider.cgColor(dark: false))
        for divider in layout.dividers { context.fill(divider) }

        let trackRadius = Theme.HUD.segmentTrackRadius
        context.addPath(CGPath(roundedRect: layout.segmentTrack, cornerWidth: trackRadius, cornerHeight: trackRadius, transform: nil))
        context.setFillColor(Theme.Colors.hudSegmentTrack.cgColor(dark: false))
        context.fillPath()

        let selectedText = Theme.Colors.chipText.light.nsColor
        let idleText = Theme.Colors.hudIdle.light.nsColor
        for slot in layout.slots {
            let frame = slot.frame
            switch slot.item {
            case .close:
                drawSymbol("xmark", size: closeGlyphSize, weight: .semibold, color: Theme.Colors.hudClose.light.nsColor,
                           center: CGPoint(x: frame.midX, y: frame.midY))
            case .mode(let segment):
                let selected = segment == mode
                if selected { fillRounded(frame, radius: Theme.HUD.segmentRadius, color: Theme.Colors.hudSelected.cgColor(dark: false), context) }
                let color = selected ? selectedText : idleText
                let glyphCenter = CGPoint(x: frame.minX + Theme.HUD.segmentHorizontalPadding + segmentGlyphSize / 2, y: frame.midY)
                if segment == .record {
                    drawRecordGlyph(center: glyphCenter, ring: color.cgColor, dot: record, context: context)
                } else {
                    drawSymbol("camera", size: segmentGlyphSize - 1, weight: .medium, color: color, center: glyphCenter)
                }
                OverlayDrawing.drawText(
                    segment.title, font: segmentFont,
                    x: frame.minX + Theme.HUD.segmentHorizontalPadding + segmentGlyphSize + glyphGap, centerY: frame.midY,
                    color: color
                )
            case .target(let item):
                let selected = item == target
                if selected {
                    fillRounded(frame, radius: Theme.HUD.targetButtonRadius, color: Theme.Colors.hudSelected.cgColor(dark: false), context)
                }
                // `display` keeps its screen layer empty, so the three targets read as one outline family.
                drawSymbol(symbol(for: item), size: Theme.HUD.targetGlyphSize - 2, weight: .regular,
                           color: selected ? selectedText : idleText, center: CGPoint(x: frame.midX, y: frame.midY),
                           outlineOnly: item == .fullscreen)
            case .options:
                let color = Theme.Colors.hudOptions.light.nsColor
                let textX = frame.minX + Theme.HUD.optionsHorizontalPadding
                OverlayDrawing.drawText("Options", font: optionsFont, x: textX, centerY: frame.midY, color: color)
                let chevronX = textX + OverlayDrawing.textWidth("Options", font: optionsFont) + chevronGap + chevronSize / 2
                drawSymbol("chevron.down", size: chevronSize, weight: .semibold, color: color,
                           center: CGPoint(x: chevronX, y: frame.midY + 0.5))
            case .primary:
                fillRounded(frame, radius: Theme.HUD.primaryRadius, color: mode == .record ? record : accent, context)
                let title = AllInOneState(mode: mode).primaryTitle
                let width = OverlayDrawing.textWidth(title, font: primaryFont)
                OverlayDrawing.drawText(title, font: primaryFont, x: frame.midX - width / 2, centerY: frame.midY, color: selectedText)
            }
        }
    }

    private static func fillRounded(_ rect: CGRect, radius: Double, color: CGColor, _ context: CGContext) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }

    /// The Record glyph: a ring in the label color around a dot in `record` red (20.5).
    private static func drawRecordGlyph(center: CGPoint, ring: CGColor, dot: CGColor, context: CGContext) {
        let radius = recordRingRadius
        context.setStrokeColor(ring)
        context.setLineWidth(1.4)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        context.setFillColor(dot)
        let inner = recordDotRadius
        context.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
    }

    private struct SymbolKey: Hashable {
        var name: String
        var size: Double
        var weight: Double
        var color: ThemeRGBA
        var outlineOnly: Bool
    }

    private static var symbols: [SymbolKey: NSImage] = [:]

    /// Draws an SF Symbol tinted `color`, centered on `center`, in the current flipped context.
    /// `outlineOnly` leaves the symbol's secondary layer clear (a one-color palette fills it).
    static func drawSymbol(
        _ name: String, size: Double, weight: NSFont.Weight, color: NSColor, center: CGPoint, outlineOnly: Bool = false
    ) {
        let rgba = color.usingColorSpace(.sRGB).map {
            ThemeRGBA(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: $0.alphaComponent)
        } ?? ThemeRGBA.white(1)
        let key = SymbolKey(name: name, size: size, weight: weight.rawValue, color: rgba, outlineOnly: outlineOnly)
        let image: NSImage
        if let cached = symbols[key] {
            image = cached
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: outlineOnly ? [rgba.nsColor, .clear] : [rgba.nsColor]))
            guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            symbols[key] = made
            image = made
        }
        let imageSize = image.size
        image.draw(
            in: CGRect(x: center.x - imageSize.width / 2, y: center.y - imageSize.height / 2,
                       width: imageSize.width, height: imageSize.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }
}

// MARK: Options menu

/// One setting the HUD's Options menu changes (design 20.5). These are the same settings as the
/// Settings window, written to `settings.json` by the app.
public enum AllInOneOption: Sendable, Hashable {
    case hideDesktopIcons
    case includeWindowShadow
    case showMagnifier
    /// A microphone device by id; nil is "None", which turns the microphone off.
    case microphone(String?)
    case systemAudio
    case showCursor
    case highlightClicks
    case countdown(Int)
}

/// One row of the Options menu.
public struct AllInOneOptionItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case option(AllInOneOption)
        case header
        case separator
    }

    public var kind: Kind
    public var title: String
    public var checked: Bool

    public init(kind: Kind, title: String, checked: Bool = false) {
        self.kind = kind
        self.title = title
        self.checked = checked
    }

    static func option(_ option: AllInOneOption, _ title: String, checked: Bool) -> AllInOneOptionItem {
        AllInOneOptionItem(kind: .option(option), title: title, checked: checked)
    }
}

/// The Options menu's rows per mode, and how a choice changes the settings (design 20.5). Pure,
/// so tests check it; `makeMenu` turns the rows into an `NSMenu`.
public enum AllInOneOptions {
    public static func items(mode: HUDMode, settings: SnapCore.Settings, microphones: [MicrophoneDevice]) -> [AllInOneOptionItem] {
        switch mode {
        case .screenshot:
            return [
                .option(.hideDesktopIcons, "Hide Desktop Icons", checked: settings.capture.hideDesktopIcons),
                .option(.includeWindowShadow, "Include Window Shadow", checked: settings.capture.includeWindowShadow),
                .option(.showMagnifier, "Show Magnifier", checked: settings.capture.showMagnifier),
            ]
        case .record:
            let recording = settings.recording
            var rows: [AllInOneOptionItem] = [
                AllInOneOptionItem(kind: .header, title: "Microphone"),
                .option(.microphone(nil), "None", checked: !recording.microphone),
            ]
            let chosen = MicrophoneDevice.resolve(recording.microphoneDeviceID, among: microphones)
            for device in microphones {
                rows.append(.option(.microphone(device.id), device.name, checked: recording.microphone && device.id == chosen))
            }
            rows.append(AllInOneOptionItem(kind: .separator, title: ""))
            rows.append(.option(.systemAudio, "Record System Audio", checked: recording.systemAudio))
            rows.append(.option(.showCursor, "Show Cursor", checked: recording.showCursor))
            rows.append(.option(.highlightClicks, "Highlight Clicks", checked: recording.highlightClicks))
            rows.append(AllInOneOptionItem(kind: .separator, title: ""))
            rows.append(AllInOneOptionItem(kind: .header, title: "Countdown"))
            for seconds in RecordingSettings.countdownChoices {
                rows.append(.option(.countdown(seconds), RecordingCountdown.title(seconds), checked: recording.countdownSeconds == seconds))
            }
            return rows
        }
    }

    /// The settings after choosing `option`. The app asks for microphone access (once per install,
    /// D65) when this turns the microphone on.
    public static func apply(_ option: AllInOneOption, to settings: SnapCore.Settings) -> SnapCore.Settings {
        var settings = settings
        switch option {
        case .hideDesktopIcons: settings.capture.hideDesktopIcons.toggle()
        case .includeWindowShadow: settings.capture.includeWindowShadow.toggle()
        case .showMagnifier: settings.capture.showMagnifier.toggle()
        case .microphone(let id):
            settings.recording.microphone = id != nil
            if let id { settings.recording.microphoneDeviceID = id }
        case .systemAudio: settings.recording.systemAudio.toggle()
        case .showCursor: settings.recording.showCursor.toggle()
        case .highlightClicks: settings.recording.highlightClicks.toggle()
        case .countdown(let seconds): settings.recording.countdownSeconds = RecordingSettings.normalizedCountdown(seconds)
        }
        return settings
    }

    /// An `NSMenu` of `items`; choosing a row calls `handler`. Building it shows nothing.
    public static func makeMenu(_ items: [AllInOneOptionItem], handler: @escaping (AllInOneOption) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Options")
        menu.autoenablesItems = false
        let target = OptionsMenuTarget(handler: handler)
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                menu.addItem(.sectionHeader(title: item.title))
            case .option(let option):
                let menuItem = NSMenuItem(title: item.title, action: #selector(OptionsMenuTarget.chosen(_:)), keyEquivalent: "")
                menuItem.target = target
                menuItem.state = item.checked ? .on : .off
                menuItem.representedObject = OptionBox(option)
                menu.addItem(menuItem)
            }
        }
        // NSMenuItem holds its target weakly; the menu keeps it alive through this item.
        let keeper = NSMenuItem()
        keeper.representedObject = target
        keeper.isHidden = true
        menu.addItem(keeper)
        return menu
    }
}

private final class OptionBox: NSObject {
    let option: AllInOneOption
    init(_ option: AllInOneOption) { self.option = option }
}

private final class OptionsMenuTarget: NSObject {
    let handler: (AllInOneOption) -> Void
    init(handler: @escaping (AllInOneOption) -> Void) { self.handler = handler }

    @objc func chosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? OptionBox else { return }
        handler(box.option)
    }
}

/// "Off", "3 seconds", "5 seconds".
public enum RecordingCountdown {
    public static func title(_ seconds: Int) -> String {
        seconds == 0 ? "Off" : "\(seconds) seconds"
    }
}
