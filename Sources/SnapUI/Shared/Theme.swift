import AppKit
import QuartzCore
import SwiftUI

/// An sRGB color with straight alpha, components 0 to 1.
nonisolated public struct ThemeRGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB` plus alpha.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static func black(_ alpha: Double) -> ThemeRGBA { ThemeRGBA(red: 0, green: 0, blue: 0, alpha: alpha) }
    public static func white(_ alpha: Double) -> ThemeRGBA { ThemeRGBA(red: 1, green: 1, blue: 1, alpha: alpha) }

    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// A color token with its light and dark values (design 17.2). `system` names the AppKit
/// semantic color to use where one exists; the hex values are the target look.
nonisolated public struct ThemeColor: Sendable, Hashable {
    public enum System: Sendable, Hashable {
        case label, secondaryLabel, tertiaryLabel, accent
    }

    public let light: ThemeRGBA
    public let dark: ThemeRGBA
    public let system: System?

    public init(light: ThemeRGBA, dark: ThemeRGBA, system: System? = nil) {
        self.light = light
        self.dark = dark
        self.system = system
    }

    /// The same value in both appearances (overlay dim, chips, crosshair).
    public init(both value: ThemeRGBA) {
        self.init(light: value, dark: value)
    }

    /// A dynamic `NSColor`: the system semantic color when the token has one, else light or dark.
    public var nsColor: NSColor {
        if let system {
            switch system {
            case .label: return .labelColor
            case .secondaryLabel: return .secondaryLabelColor
            case .tertiaryLabel: return .tertiaryLabelColor
            case .accent: return .controlAccentColor
            }
        }
        return hexColor
    }

    /// Always the mockup's hex values, resolved per appearance. For shots and layers that must
    /// match the mockup exactly.
    public var hexColor: NSColor {
        let light = light
        let dark = dark
        return NSColor(name: nil) { appearance in
            ThemeColor.isDark(appearance) ? dark.nsColor : light.nsColor
        }
    }

    public var color: Color { Color(nsColor: nsColor) }

    /// The resolved value for a layer or Core Graphics drawing, which has no appearance of its own.
    public func cgColor(dark isDark: Bool) -> CGColor {
        (isDark ? dark : light).cgColor
    }

    public func cgColor(for appearance: NSAppearance) -> CGColor {
        cgColor(dark: ThemeColor.isDark(appearance))
    }

    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark, .accessibilityHighContrastAqua,
                                    .accessibilityHighContrastDarkAqua]).map {
            $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }
}

/// Every visual token of design section 17: colors, type, spacing, sizes, radii, materials and
/// motion. Controls AppKit draws (menus, switches, popups, tabs) stay system-drawn (design D44).
nonisolated public enum Theme {
    // MARK: Colors (17.2)

    public enum Colors {
        public static let text = ThemeColor(light: .init(hex: 0x1D1D1F), dark: .init(hex: 0xF2F2F7), system: .label)
        public static let text2 = ThemeColor(
            light: .init(hex: 0x6E6E73), dark: .init(hex: 0xA1A1A6), system: .secondaryLabel
        )
        /// Icons and the countdown line only, never text that must be read.
        public static let text3 = ThemeColor(
            light: .init(hex: 0x8A8A8F), dark: .init(hex: 0x8E8E93), system: .tertiaryLabel
        )
        public static let separator = ThemeColor(light: .black(0.08), dark: .white(0.08))
        public static let separatorStrong = ThemeColor(light: .black(0.16), dark: .white(0.18))
        public static let fill = ThemeColor(light: .black(0.05), dark: .white(0.075))
        public static let window = ThemeColor(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0x1E1E20))
        public static let sidebar = ThemeColor(light: .init(hex: 0xF6F6F8), dark: .init(hex: 0x242427))
        public static let canvas = ThemeColor(light: .init(hex: 0xE6E6EA), dark: .init(hex: 0x141416))
        public static let settingsBackground = ThemeColor(light: .init(hex: 0xF3F3F5), dark: .init(hex: 0x1E1E20))
        public static let group = ThemeColor(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0x28282B))
        public static let accent = ThemeColor(light: .init(hex: 0x007AFF), dark: .init(hex: 0x0A84FF), system: .accent)
        public static let accentText = ThemeColor(light: .init(hex: 0x0068DA), dark: .init(hex: 0x409CFF))
        public static let button = ThemeColor(light: .init(hex: 0xFFFFFF), dark: .white(0.13))
        /// The 0.5 pt ring on light secondary buttons and popups.
        public static let buttonEdge = ThemeColor(light: .black(0.2), dark: .white(0.06))
        /// `.regularMaterial` target for the Quick Access card, zoom pill and hint panel.
        public static let card = ThemeColor(
            light: .init(red: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 0.78),
            dark: .init(red: 44 / 255, green: 44 / 255, blue: 47 / 255, alpha: 0.74)
        )
        public static let cardEdge = ThemeColor(light: .black(0.12), dark: .white(0.14))
        /// Menu preview only; the real menu is the system's.
        public static let menu = ThemeColor(
            light: .init(red: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 0.86),
            dark: .init(red: 44 / 255, green: 44 / 255, blue: 47 / 255, alpha: 0.84)
        )
        public static let warning = ThemeColor(light: .init(hex: 0xB25000), dark: .init(hex: 0xFF9F0A))
        public static let warningDot = ThemeColor(light: .init(hex: 0xF08A00), dark: .init(hex: 0xFF9F0A))
        public static let warningBackground = ThemeColor(
            light: .init(hex: 0xF08A00, alpha: 0.12), dark: .init(hex: 0xFF9F0A, alpha: 0.14)
        )
        public static let success = ThemeColor(light: .init(hex: 0x30B350), dark: .init(hex: 0x30D158))
        public static let annotateRed = ThemeColor(both: .init(hex: 0xFF3B30))
        /// Switch track when off, slider track.
        public static let track = ThemeColor(light: .black(0.12), dark: .white(0.16))
        public static let windowEdge = ThemeColor(light: .black(0.14), dark: .white(0.14))

        // Overlay and card controls: the same in both appearances.
        public static let dim = ThemeColor(both: .black(0.38))
        public static let chip = ThemeColor(both: .init(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.84))
        public static let chipText = ThemeColor(both: .white(1))
        public static let chipRing = ThemeColor(both: .white(0.18))
        public static let dimensionPill = ThemeColor(both: .black(0.58))
        public static let crosshair = ThemeColor(both: .white(0.62))
        public static let crosshairHairline = ThemeColor(both: .black(0.30))
        /// Pixel grid lines inside the magnifier.
        public static let magnifierGrid = ThemeColor(both: .black(0.14))
        public static let selectionBorder = ThemeColor(both: .white(1))
        public static let selectionHairline = ThemeColor(both: .black(0.30))
        /// Window highlight fill: accent at 14%.
        public static let windowHighlight = ThemeColor(
            light: .init(hex: 0x007AFF, alpha: 0.14), dark: .init(hex: 0x0A84FF, alpha: 0.14)
        )
        /// The check in the "Copied" chip.
        public static let copiedCheck = ThemeColor(both: .init(hex: 0x5BE37D))
        /// Hover scrim over the card thumbnail.
        public static let scrim = ThemeColor(both: .black(0.20))
        /// Behind a thumbnail that does not fill its box (transparent window corners, a tall capture's
        /// letterbox): the mockup's `fill2`, solid so it reads as part of the card, not a gap.
        public static let thumbnailBacking = ThemeColor(light: .init(hex: 0xF0F0F2), dark: .init(hex: 0x2E2E31))
        /// Inner stroke on thumbnails so a white screenshot keeps its edge.
        public static let thumbnailStroke = ThemeColor(both: .black(0.18))
        /// Star on the default preset.
        public static let star = ThemeColor(both: .init(hex: 0xF5A623))

        // M2 (design 20.11).
        /// Recording timer, Record button, record dot.
        public static let record = ThemeColor(light: .init(hex: 0xFF3B30), dark: .init(hex: 0xFF453A))
        /// Highlight tool default: #FFD60A at 38%.
        public static let highlightDefault = ThemeColor(both: .init(hex: 0xFFD60A, alpha: 0.38))
        /// Highlight color without its alpha, for the color well.
        public static let highlightSolid = ThemeColor(both: .init(hex: 0xFFD60A))
        /// Click-through pin badge: chip color at 0.72.
        public static let lockBadge = ThemeColor(both: .init(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.72))
        /// Pin opacity slider: track and fill.
        public static let pinSliderTrack = ThemeColor(both: .white(0.28))
        public static let pinSliderFill = ThemeColor(both: .white(1))
        /// Dividers inside chip bars (pin control bar, HUD toolbar).
        public static let chipDivider = ThemeColor(both: .white(0.24))
        public static let hudDivider = ThemeColor(both: .white(0.18))
        /// HUD mode switch track, and the selected segment or target.
        public static let hudSegmentTrack = ThemeColor(both: .white(0.10))
        public static let hudSelected = ThemeColor(both: .white(0.20))
        /// Unselected HUD glyphs and labels.
        public static let hudIdle = ThemeColor(both: .white(0.78))
        public static let hudOptions = ThemeColor(both: .white(0.86))
        public static let hudClose = ThemeColor(both: .white(0.80))
        /// Countdown disc shadow color.
        public static let countdownShadow = ThemeColor(both: .black(0.35))
        /// History "Interrupted" pill: warning fill at 0.92.
        public static let interruptedPill = ThemeColor(both: .init(hex: 0xB25000, alpha: 0.92))
        /// The 3 pt dot between footer facts in the history window.
        public static let historyFooterDot = ThemeColor(
            light: .init(hex: 0x8A8A8F), dark: .init(hex: 0x8E8E93), system: .tertiaryLabel
        )
        /// Redact black-out fill.
        public static let blackout = ThemeColor(both: .init(hex: 0x000000))
    }

    // MARK: Type (17.3)

    /// One type role: size, line height, weight, optional tracking in em.
    public struct TextStyle: Sendable, Hashable {
        public let size: Double
        public let lineHeight: Double
        public let weight: NSFont.Weight
        public let tracking: Double
        public let tabular: Bool

        public init(size: Double, lineHeight: Double, weight: NSFont.Weight, tracking: Double = 0, tabular: Bool = false) {
            self.size = size
            self.lineHeight = lineHeight
            self.weight = weight
            self.tracking = tracking
            self.tabular = tabular
        }

        public var nsFont: NSFont {
            tabular ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }

        public var font: Font {
            let base = Font.system(size: size, weight: Font.Weight(weight))
            return tabular ? base.monospacedDigit() : base
        }

        /// Extra line spacing so SwiftUI text lands on `lineHeight`.
        public var lineSpacing: Double { max(lineHeight - nsFont.boundingRectForFont.height, 0) }
    }

    public enum Typography {
        public static let title = TextStyle(size: 22, lineHeight: 28, weight: .semibold, tracking: -0.015)
        public static let headline = TextStyle(size: 14, lineHeight: 20, weight: .semibold)
        public static let body = TextStyle(size: 13, lineHeight: 18, weight: .regular)
        public static let bodyEmphasis = TextStyle(size: 13, lineHeight: 18, weight: .medium)
        public static let groupHeading = TextStyle(size: 13, lineHeight: 18, weight: .semibold)
        public static let caption = TextStyle(size: 12, lineHeight: 16, weight: .regular)
        public static let captionMedium = TextStyle(size: 12, lineHeight: 16, weight: .medium)
        /// Card button labels.
        public static let captionSemibold = TextStyle(size: 12, lineHeight: 16, weight: .semibold)
        public static let captionSmall = TextStyle(size: 11, lineHeight: 15, weight: .regular)
        /// Size caption, coordinates, dimension pill.
        public static let chip = TextStyle(size: 11, lineHeight: 22, weight: .medium, tabular: true)
        /// Annotate text tool (`annotateLastTextSize = 30`).
        public static let annotation = TextStyle(size: 30, lineHeight: 36, weight: .semibold)
        /// Button labels: 13 pt medium, never smaller, for contrast on the accent.
        public static let button = TextStyle(size: 13, lineHeight: 18, weight: .medium)
    }

    // MARK: Spacing and radii (17.4)

    /// The 4 pt grid.
    public enum Spacing {
        public static let xxs: Double = 4
        public static let xs: Double = 8
        public static let s: Double = 12
        public static let m: Double = 16
        public static let l: Double = 24
    }

    // MARK: Sizes (17.4)

    public enum QuickAccess {
        public static let cardPadding: Double = 8
        public static let cardRadius: Double = 16
        public static let thumbnailRadius: Double = 8
        public static let thumbnailMaxHeight: Double = 220
        public static let thumbnailMinHeight: Double = 96
        public static let cardGap: Double = 8
        public static let edgeInset: Double = 16
        public static let maxCards = 5
        /// The stack never grows past this fraction of `visibleFrame` height.
        public static let maxStackHeightFraction: Double = 0.70
        public static let copiedChipHeight: Double = 22
        public static let dimensionPillHeight: Double = 18
        public static let dimensionPillRadius: Double = 9
        public static let closeButtonSize: Double = 22
        public static let controlBarHeight: Double = 32
        public static let controlBarWidth: Double = 211
        public static let controlButtonWidth: Double = 28
        public static let countdownLineHeight: Double = 2
        public static let countdownLineInset: Double = 3
        /// The countdown line shows only in the last 5 s.
        public static let countdownVisibleSeconds: Double = 5
        public static let copiedChipSeconds: Double = 2
        public static let dragImageScale: Double = 0.45
        public static let dragImageRadius: Double = 6
        public static let dragImageRotationDegrees: Double = -2
        public static let dragLiftScale: Double = 1.03
        public static let swipeDismissDistance: Double = 80
        public static let swipeDismissVelocity: Double = 400
        public static let rubberBand: Double = 0.55
    }

    public enum Overlay {
        public static let chipHeight: Double = 22
        public static let chipRadius: Double = 11
        public static let chipHorizontalPadding: Double = 9
        public static let chipRingWidth: Double = 0.5
        public static let hintBarHeight: Double = 30
        public static let hintBarRadius: Double = 15
        public static let hintBarBottomInset: Double = 28
        public static let magnifierDiameter: Double = 120
        public static let magnifierPixels = 15
        public static let magnifierPixelSize: Double = 8
        public static let magnifierRingWidth: Double = 2
        public static let magnifierHairlineWidth: Double = 1
        public static let magnifierCenterStroke: Double = 1.5
        public static let magnifierGridWidth: Double = 0.5
        public static let magnifierEdgeMargin: Double = 8
        public static let magnifierOffset: Double = 24
        public static let magnifierCaptionGap: Double = 12
        public static let crosshairGap: Double = 8
        public static let crosshairWidth: Double = 1
        public static let selectionBorderWidth: Double = 1
        public static let sizeChipGap: Double = 8
        public static let handleSize: Double = 8
        public static let handleBorderWidth: Double = 1.5
        public static let windowHighlightBorder: Double = 2
        public static let windowHighlightRadius: Double = 14
        public static let windowLabelOffset: Double = 34
        /// Key hints show for the first 10 captures.
        public static let keyHintCaptures = 10
    }

    public enum Controls {
        public static let buttonHeight: Double = 24
        public static let popupHeight: Double = 24
        public static let popupFullWidthHeight: Double = 28
        public static let segmentedHeight: Double = 22
        public static let switchSize = CGSize(width: 36, height: 20)
        public static let swatchSize: Double = 36
        public static let swatchRadius: Double = 8
        public static let swatchColumns = 6
        public static let swatchGap: Double = 8
        public static let swatchRingWidth: Double = 2
        public static let swatchRingOffset: Double = 4
    }

    public enum BackgroundEditor {
        public static let windowSize = CGSize(width: 920, height: 640)
        /// The mockup's window title bar, part of its 920 x 640; the content fits in the rest.
        public static let titleBarHeight: Double = 52
        public static let sidebarWidth: Double = 300
        public static let sidebarPadding = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        public static let previewPadding: Double = 28
        public static let sliderLabelWidth: Double = 54
        public static let sliderValueWidth: Double = 40
        public static let valueFieldHeight: Double = 22
        public static let sliderRowHeight: Double = 28
        public static let previewRadius: Double = 4
        public static let alignmentSquare: Double = 18
        /// Opacity of the align grid while Ratio is Auto.
        public static let alignmentDimmedOpacity: Double = 0.55
    }

    public enum Annotate {
        public static let windowSize = CGSize(width: 1100, height: 720)
        public static let minimumSize = CGSize(width: 560, height: 400)
        public static let toolbarHeight: Double = 52
        public static let toolButtonSize = CGSize(width: 34, height: 26)
        public static let colorWellSize: Double = 16
        public static let strokeWidths: [Double] = [2, 4, 7]
        public static let defaultStrokeWidth: Double = 4
        public static let selectionBorderWidth: Double = 1.5
        public static let handleSize: Double = 8
        public static let zoomPillInset: Double = 16
        public static let pixelateCell: Double = 8
        public static let toastRise: Double = 8
        public static let toastHoldSeconds: Double = 1.5
    }

    public enum Settings {
        public static let width: Double = 480
        public static let tabSize = CGSize(width: 76, height: 52)
        public static let tabGap: Double = 4
        public static let tabRadius: Double = 10
        public static let formPadding: Double = 20
        public static let groupRadius: Double = 10
        public static let rowMinHeight: Double = 40
        public static let rowPadding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        public static let groupSpacing: Double = 16
        public static let headingTopSpacing: Double = 6
        public static let headingBottomSpacing: Double = 8
    }

    public enum Onboarding {
        public static let width: Double = 520
        public static let padding: Double = 32
        public static let iconSize: Double = 64
        public static let iconRadius: Double = 14.4
        public static let stepPadding: Double = 16
        public static let stepIconSize: Double = 36
        public static let footerHorizontalPadding: Double = 20
    }

    public enum HintPanel {
        public static let size = CGSize(width: 500, height: 64)
        public static let radius: Double = 16
        public static let padding: Double = 12
        public static let visibleSeconds: Double = 6
        /// A message chip ("Recording could not start", design D69) stays 4 s.
        public static let messageSeconds: Double = 4
        public static let rise: Double = 6
    }

    public enum Menu {
        public static let width: Double = 280
        public static let padding: Double = 6
        public static let rowHeight: Double = 24
        public static let recentRowHeight: Double = 42
        public static let thumbnailSize: Double = 32
        public static let thumbnailRadius: Double = 6
        public static let radius: Double = 12
        public static let statusDotSize: Double = 7
    }

    // MARK: M2 surfaces (design 20.2 to 20.11)

    /// Pin to screen (20.2, mockup 8).
    public enum Pin {
        /// Opaque captures are clipped to this radius (`pinRadius`).
        public static let radius: Double = 8
        public static let closeButtonSize: Double = 22
        public static let closeButtonInset: Double = 8
        public static let controlBarHeight: Double = 30
        public static let controlBarInset: Double = 8
        public static let controlBarLeadingPadding: Double = 10
        public static let controlBarTrailingPadding: Double = 4
        public static let controlBarSpacing: Double = 2
        public static let dropGlyphSize: Double = 14
        public static let sliderWidth: Double = 72
        public static let sliderTrackHeight: Double = 3
        public static let sliderKnobSize: Double = 14
        public static let valueWidth: Double = 32
        public static let valueStyle = TextStyle(size: 11, lineHeight: 15, weight: .medium, tabular: true)
        public static let dividerHeight: Double = 14
        public static let controlButtonSize = CGSize(width: 26, height: 24)
        /// Below this width the slider hides and the value becomes a scrub control.
        public static let compactChromeWidth: Double = 260
        /// Below this width only Close and More remain.
        public static let minimalChromeWidth: Double = 120
        /// `lockBadge`: 18 pt, 6 pt inside the top-left corner, 10 pt lock glyph.
        public static let lockBadgeSize: Double = 18
        public static let lockBadgeInset: Double = 6
        public static let lockGlyphSize: Double = 10
        /// The size chip sits this far above the bottom edge during a resize or zoom.
        public static let sizeChipBottomInset: Double = 8
        /// Opening from the menu or history, and closing, scale between this and 1 (M18, M19).
        public static let appearScale: Double = 0.96
    }

    /// Capture history window (20.3, mockup 9).
    public enum History {
        public static let windowSize = CGSize(width: 760, height: 560)
        public static let minimumSize = CGSize(width: 560, height: 400)
        public static let toolbarHeight: Double = 52
        public static let titleStyle = TextStyle(size: 15, lineHeight: 19, weight: .semibold)
        public static let subtitleStyle = TextStyle(size: 11, lineHeight: 15, weight: .regular)
        public static let titleLeadingInset: Double = 14
        public static let toolbarSpacing: Double = 12
        public static let searchFieldSize = CGSize(width: 190, height: 28)
        public static let searchFieldRadius: Double = 8
        public static let sectionHeadingStyle = TextStyle(size: 13, lineHeight: 18, weight: .semibold)
        public static let sectionCountStyle = TextStyle(size: 12, lineHeight: 16, weight: .regular, tabular: true)
        public static let sectionTopSpacing: Double = 16
        public static let sectionBottomSpacing: Double = 10
        public static let bodyTopPadding: Double = 4
        /// `historyTile`: 164 x 112, radius 8, gaps 16 (columns) and 14 (rows).
        public static let tileSize = CGSize(width: 164, height: 112)
        public static let tileRadius: Double = 8
        public static let columnGap: Double = 16
        public static let rowGap: Double = 14
        public static let sidePadding: Double = 28
        public static let tileStrokeWidth: Double = 0.5
        public static let captionGap: Double = 6
        public static let captionTimeStyle = TextStyle(size: 12, lineHeight: 16, weight: .medium, tabular: true)
        public static let captionAppStyle = TextStyle(size: 12, lineHeight: 16, weight: .regular)
        /// Thumbnails are 328 px on the long side (164 pt at 2x).
        public static let thumbnailPixels = 328
        /// Badges sit 6 pt inside the tile.
        public static let badgeInset: Double = 6
        public static let durationPillHeight: Double = 18
        public static let editedChipSize: Double = 20
        public static let badgeStyle = TextStyle(size: 11, lineHeight: 18, weight: .medium, tabular: true)
        /// Selected tile: 2 pt accent ring at 4 pt outside the box.
        public static let selectionRingWidth: Double = 2
        public static let selectionRingOffset: Double = 4
        public static let footerHeight: Double = 48
        public static let footerLeadingPadding: Double = 20
        public static let footerTrailingPadding: Double = 16
        public static let footerSpacing: Double = 8
        public static let footerDotSize: Double = 3
        public static let footerStyle = TextStyle(size: 12, lineHeight: 16, weight: .regular, tabular: true)
        public static let emptyIconSize: Double = 56
        public static let emptyIconRadius: Double = 16
        public static let emptyIconGap: Double = 14
        public static let emptyTitleStyle = TextStyle(size: 14, lineHeight: 20, weight: .semibold)
        public static let emptyTextMaxWidth: Double = 340
        public static let emptyTextGap: Double = 4
        public static let keyCapRadius: Double = 5
    }

    /// All-in-one HUD toolbar (20.5, mockup 10). Flat chip material, never a blur (rule 2 of 17.1).
    public enum HUD {
        /// `hudBar`: chip, 44 pt high, radius 14, 6 pt padding.
        public static let barHeight: Double = 44
        public static let barRadius: Double = 14
        public static let barPadding: Double = 6
        public static let barSpacing: Double = 6
        /// Distance from the visible frame's bottom (or top) edge.
        public static let edgeInset: Double = 28
        public static let closeButtonSize: Double = 30
        public static let dividerSize = CGSize(width: 1, height: 20)
        public static let dividerMargin: Double = 2
        public static let segmentHeight: Double = 28
        public static let segmentPadding: Double = 2
        public static let segmentTrackRadius: Double = 9
        public static let segmentRadius: Double = 7
        public static let segmentHorizontalPadding: Double = 10
        public static let segmentLabelStyle = TextStyle(size: 12, lineHeight: 16, weight: .medium)
        public static let targetButtonSize = CGSize(width: 36, height: 32)
        public static let targetButtonRadius: Double = 8
        public static let targetGlyphSize: Double = 17
        public static let optionsHeight: Double = 30
        public static let optionsHorizontalPadding: Double = 8
        public static let primaryHeight: Double = 30
        public static let primaryRadius: Double = 9
        public static let primaryHorizontalPadding: Double = 16
        public static let primaryStyle = TextStyle(size: 13, lineHeight: 18, weight: .semibold)
        /// Restored area handles: 10 pt, white, 1.5 pt accent border.
        public static let handleSize: Double = 10
        public static let handleBorderWidth: Double = 1.5
        public static let sizeChipGap: Double = 8
    }

    /// Recording countdown (20.6, mockup 11a).
    public enum Countdown {
        /// `countdownDisc`: chip, 88 pt, 44 pt semibold tabular digits.
        public static let discSize: Double = 88
        public static let ringWidth: Double = 0.5
        public static let shadowOffsetY: Double = 10
        public static let shadowBlur: Double = 30
        public static let digitStyle = TextStyle(size: 44, lineHeight: 48, weight: .semibold, tracking: -0.02, tabular: true)
        public static let hintGap: Double = 12
    }

    /// While recording (20.6, mockup 11b).
    public enum Recording {
        /// The outline sits this far outside the area so it is never in the frames.
        public static let outlineOutset: Double = 2
        public static let outlineWidth: Double = 1
        public static let outlineHairlineWidth: Double = 1
        /// The red timer status item: 18 pt capsule, 8 pt white stop square.
        public static let timerHeight: Double = 18
        public static let timerRadius: Double = 9
        public static let timerLeadingPadding: Double = 7
        public static let timerTrailingPadding: Double = 8
        public static let timerSpacing: Double = 6
        public static let stopSquareSize: Double = 8
        public static let stopSquareRadius: Double = 2
        public static let timerStyle = TextStyle(size: 12, lineHeight: 16, weight: .semibold, tabular: true)
        public static let menuWidth: Double = 260
        public static let infoStyle = TextStyle(size: 12, lineHeight: 16, weight: .regular)
        /// Smallest recordable output, in pixels.
        public static let minimumPixels = 64
        /// "Recording could not start" and "No microphone" chips.
        public static let noticeSeconds: Double = 4
    }

    /// Quick Access additions for M2 (20.2 and 20.6, mockup 11c).
    public enum QuickAccessM2 {
        /// The Pin chip mirrors Close at the top-right of the thumbnail.
        public static let pinButtonSize: Double = 22
        public static let pinButtonInset: Double = 8
        /// The video card's duration pill replaces the dimension pill.
        public static let durationPillHeight: Double = 18
        public static let durationPillRadius: Double = 9
        public static let durationGlyphSize: Double = 9
        public static let durationPillSpacing: Double = 4
        public static let openButtonSpacing: Double = 5
        /// How long a recording's note chip stays on its card ("No microphone", design 20.6).
        public static let noteSeconds: Double = 4
    }

    /// Annotate additions (20.8, mockup 12).
    public enum AnnotateM2 {
        public static let highlightOpacity: Double = 0.38
        public static let highlightRadius: Double = 2
        /// Step circle diameters for stroke widths 2, 4 and 7.
        public static let stepDiameters: [Double] = [24, 28, 36]
        /// Step number size at the 28 pt circle; scaled with the diameter.
        public static let stepNumberSize: Double = 15
        public static let stepSelectionRingWidth: Double = 1.5
        public static let stepSelectionRingOffset: Double = 2.5
        /// Freehand drops points closer than this to the last kept point.
        public static let freehandMinimumDistance: Double = 1.5
        /// Freehand hit testing: within width / 2 plus this.
        public static let freehandHitSlop: Double = 4
        public static let stylePopupSpacing: Double = 6
        public static let styleMenuWidth: Double = 236
        public static let styleMenuNoteStyle = TextStyle(size: 11, lineHeight: 15, weight: .regular)
    }

    /// Settings additions (20.10, mockup 14).
    public enum SettingsM2 {
        /// The Recording tab shot: 480 x 690.
        public static let recordingTabSize = CGSize(width: 480, height: 690)
        public static let warningRowIconSize: Double = 14
    }

    /// Menu additions (20.10, mockup 15).
    public enum MenuM2 {
        /// The menu shot: 420 x 600.
        public static let shotSize = CGSize(width: 420, height: 600)
        public static let pinnedThumbnailSize: Double = 32
    }

    // MARK: Materials (17.5)

    public enum Materials {
        /// Card, zoom pill and hint panel. Opaque `window` color under Reduce Transparency.
        public static let card: Material = .regularMaterial
        public static let edgeWidth: Double = 0.5
        public static let thumbnailStrokeWidth: Double = 0.5
        /// Card shadow: x 0, y 14, blur 32, spread -8, black 34%.
        public static let cardShadowOffsetY: Double = 14
        public static let cardShadowBlur: Double = 32
        public static let cardShadowSpread: Double = -8
        public static let cardShadowOpacity: Double = 0.34
        /// Blur behind the hover control bar on the card.
        public static let controlBarBlur: Double = 16
    }

    // MARK: Motion (17.7)

    public enum Motion {
        /// `cubic-bezier(.16, 1, .3, 1)`
        public static let enterControlPoints: (Float, Float, Float, Float) = (0.16, 1, 0.3, 1)
        /// `cubic-bezier(.4, 0, 1, 1)`
        public static let exitControlPoints: (Float, Float, Float, Float) = (0.4, 0, 1, 1)

        public static let springResponse: Double = 0.30
        public static let springDamping: Double = 1.0
        /// Swipe release and cancelled drag carry momentum.
        public static let momentumDamping: Double = 0.85
        /// First run check mark, the one playful moment.
        public static let playfulResponse: Double = 0.35
        public static let playfulDamping: Double = 0.75

        public static let cardEnterOffsetX: Double = -24
        public static let cardDismissOffsetX: Double = -40
        public static let hoverRise: Double = 4
        public static let pressScale: Double = 0.96
        public static let copyCheckStartScale: Double = 0.85
        public static let copyCheckHold: Double = 0.9
        public static let checkStartScale: Double = 0.6

        public static let reducedMotionFade: Double = 0.100
        public static let hoverIn: Double = 0.120
        public static let hoverOut: Double = 0.100
        public static let pressDown: Double = 0.080
        public static let pressUp: Double = 0.120
        public static let copiedChip: Double = 0.160
        public static let copyDone: Double = 0.120
        public static let dismiss: Double = 0.220
        public static let dragLift: Double = 0.140
        public static let countdownFade: Double = 0.200
        public static let backgroundCrossFade: Double = 0.160
        public static let swatchRing: Double = 0.100
        public static let toastIn: Double = 0.160
        public static let toastOut: Double = 0.200
        public static let firstRunStep: Double = 0.240
        public static let hintIn: Double = 0.160
        public static let hintOut: Double = 0.200
        // M2 (20.12).
        /// M18: pin opens from the menu or history.
        public static let pinEnter: Double = 0.160
        /// M19: pin closes.
        public static let pinExit: Double = 0.120
        /// M22: countdown digit.
        public static let countdownDigit: Double = 0.120
        /// M28: a trashed history tile fades and shrinks to this scale (the M19 pin close values).
        public static let historyTileExit: Double = 0.120
        public static let historyTileExitScale: Double = 0.96

        public static func enter(_ duration: Double) -> Animation {
            let points = enterControlPoints
            return .timingCurve(Double(points.0), Double(points.1), Double(points.2), Double(points.3), duration: duration)
        }

        public static func exit(_ duration: Double) -> Animation {
            let points = exitControlPoints
            return .timingCurve(Double(points.0), Double(points.1), Double(points.2), Double(points.3), duration: duration)
        }

        /// The one spring (no bounce): card entry and stack reflow.
        public static var spring: Animation { .spring(response: springResponse, dampingFraction: springDamping) }
        public static var momentumSpring: Animation {
            .spring(response: springResponse, dampingFraction: momentumDamping)
        }
        public static var playfulSpring: Animation {
            .spring(response: playfulResponse, dampingFraction: playfulDamping)
        }

        public static var enterTiming: CAMediaTimingFunction {
            let points = enterControlPoints
            return CAMediaTimingFunction(controlPoints: points.0, points.1, points.2, points.3)
        }

        public static var exitTiming: CAMediaTimingFunction {
            let points = exitControlPoints
            return CAMediaTimingFunction(controlPoints: points.0, points.1, points.2, points.3)
        }
    }
}

nonisolated extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}
