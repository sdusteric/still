import AppKit
import Observation
import SnapCore
import SwiftUI

/// The countdown line of the last 5 s (17.6): it starts at `startFraction` of the card width and
/// drains linearly to nothing over `duration` seconds.
public struct QuickAccessCountdown: Sendable, Hashable {
    public var startFraction: Double
    public var startDate: Date
    public var duration: Double

    public init(startFraction: Double, startDate: Date, duration: Double) {
        self.startFraction = startFraction
        self.startDate = startDate
        self.duration = duration
    }

    /// A line that does not move, for shots.
    public static func fixed(_ fraction: Double) -> QuickAccessCountdown {
        QuickAccessCountdown(startFraction: fraction, startDate: .distantPast, duration: .infinity)
    }

    public func fraction(at date: Date) -> Double {
        guard duration.isFinite, duration > 0 else { return startFraction }
        let elapsed = max(date.timeIntervalSince(startDate), 0)
        return max(startFraction * (1 - elapsed / duration), 0)
    }
}

/// One card's view state.
@Observable
public final class QuickAccessCardModel: Identifiable {
    public let id: String
    public var thumbnail: CGImage
    /// Bumped when Background changes the thumbnail, so the view cross-fades.
    public var thumbnailVersion = 0
    public var pointSize: CGSize
    public var size: QuickAccessSize
    public var corner: QuickAccessCorner
    public var showsCopied = false
    public var isHovered = false
    public var isDragging = false
    public var backgroundApplied = false
    public var savedURL: URL?
    /// The button that shows a check for 900 ms after it succeeded.
    public var confirmedAction: QuickAccessCardAction?
    public var countdown: QuickAccessCountdown?
    /// Option is held: Copy writes the file URL (design 9) and its button says so.
    public var copiesFile = false
    public var swipeOffset = 0.0
    @ObservationIgnored var pendingCloseAction: QuickAccessStack.CardAction?

    public init(
        id: String,
        thumbnail: CGImage,
        pointSize: CGSize,
        size: QuickAccessSize = .medium,
        corner: QuickAccessCorner = .bottomLeft
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        self.size = size
        self.corner = corner
    }

    public var thumbnailSize: CGSize {
        CGSize(
            width: QuickAccessLayout.thumbnailWidth(size),
            height: QuickAccessLayout.thumbnailHeight(pointSize: pointSize, size: size)
        )
    }

    public var cardSize: CGSize {
        CGSize(
            width: thumbnailSize.width + 2 * Theme.QuickAccess.cardPadding,
            height: thumbnailSize.height + 2 * Theme.QuickAccess.cardPadding
        )
    }

    /// `842 × 516` in points.
    public var dimensionText: String { OverlayDrawing.sizeText(pointSize) }

    /// Labels are dropped when the bar would not fit: Small, or Medium with the Reveal button.
    public var compactBar: Bool {
        size == .small || (size == .medium && savedURL != nil)
    }
}

/// What a card view calls. The controller supplies one per card; shots use `inert`.
public struct QuickAccessCardHandler {
    public var edgeSign: Double
    public var perform: @MainActor (QuickAccessCardAction) -> Void
    public var hover: @MainActor (Bool) -> Void
    public var dragBegan: @MainActor () -> Void
    public var dragEnded: @MainActor (Bool) -> Void
    public var swipeChanged: @MainActor (Double) -> Void
    public var swipeEnded: @MainActor (Double, Double) -> Void
    public var dragURL: @MainActor () -> URL?

    public init(
        edgeSign: Double = -1,
        perform: @escaping @MainActor (QuickAccessCardAction) -> Void = { _ in },
        hover: @escaping @MainActor (Bool) -> Void = { _ in },
        dragBegan: @escaping @MainActor () -> Void = {},
        dragEnded: @escaping @MainActor (Bool) -> Void = { _ in },
        swipeChanged: @escaping @MainActor (Double) -> Void = { _ in },
        swipeEnded: @escaping @MainActor (Double, Double) -> Void = { _, _ in },
        dragURL: @escaping @MainActor () -> URL? = { nil }
    ) {
        self.edgeSign = edgeSign
        self.perform = perform
        self.hover = hover
        self.dragBegan = dragBegan
        self.dragEnded = dragEnded
        self.swipeChanged = swipeChanged
        self.swipeEnded = swipeEnded
        self.dragURL = dragURL
    }

    public static var inert: QuickAccessCardHandler { QuickAccessCardHandler() }
}

/// One Quick Access card (design 8, 17.6): thumbnail with the dimension pill and the Copied chip;
/// on hover a scrim, a close button and the control bar (Background split button, Annotate, Save,
/// Copy, and Reveal after a save).
public struct QuickAccessCardView: View {
    let card: QuickAccessCardModel
    let handler: QuickAccessCardHandler
    /// False for `ImageRenderer`: the AppKit drag source cannot be drawn offscreen.
    let interactive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    public init(card: QuickAccessCardModel, handler: QuickAccessCardHandler = .inert, interactive: Bool = true) {
        self.card = card
        self.handler = handler
        self.interactive = interactive
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.QuickAccess.cardRadius, style: .continuous)
    }

    public var body: some View {
        thumbnail
            .padding(Theme.QuickAccess.cardPadding)
            .background {
                if reduceTransparency {
                    cardShape.fill(Theme.Colors.window.color)
                } else {
                    cardShape.fill(Theme.Materials.card)
                }
            }
            .overlay {
                cardShape.strokeBorder(Theme.Colors.cardEdge.color, lineWidth: Theme.Materials.edgeWidth)
            }
            .overlay(alignment: .bottomLeading) { countdownLine }
            .compositingGroup()
            .shadow(
                color: .black.opacity(Theme.Materials.cardShadowOpacity),
                radius: (Theme.Materials.cardShadowBlur + Theme.Materials.cardShadowSpread) / 2,
                y: Theme.Materials.cardShadowOffsetY
            )
            .offset(x: card.swipeOffset)
            .onHover { hovering in handler.hover(hovering) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Screenshot \(card.dimensionText)")
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        let size = card.thumbnailSize
        let shape = RoundedRectangle(cornerRadius: Theme.QuickAccess.thumbnailRadius, style: .continuous)
        return ZStack {
            Theme.Colors.thumbnailBacking.color
            Image(decorative: card.thumbnail, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .id(card.thumbnailVersion)
                .transition(.opacity)
            if card.isHovered {
                Theme.Colors.scrim.color
                    .transition(.opacity)
            }
            if interactive {
                ThumbnailDragView(image: card.thumbnail, displaySize: size, handler: handler)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Theme.Colors.thumbnailStroke.color, lineWidth: Theme.Materials.thumbnailStrokeWidth)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            if !card.isHovered {
                dimensionPill.padding(Theme.Spacing.xs).transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if card.showsCopied && !card.isHovered {
                copiedChip.padding(Theme.Spacing.xs).transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if card.isHovered {
                closeButton.padding(Theme.Spacing.xs).transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if card.isHovered {
                controlBar
                    .padding(.bottom, Theme.Spacing.xs)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Theme.Motion.hoverRise)))
            }
        }
        .scaleEffect(card.isDragging && !reduceMotion ? Theme.QuickAccess.dragLiftScale : 1)
        .shadow(color: .black.opacity(card.isDragging ? 0.3 : 0), radius: card.isDragging ? 10 : 0, y: card.isDragging ? 6 : 0)
    }

    private var dimensionPill: some View {
        Text(card.dimensionText)
            .font(Theme.Typography.chip.font)
            .foregroundStyle(Theme.Colors.chipText.color)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(height: Theme.QuickAccess.dimensionPillHeight)
            .background(Capsule().fill(Theme.Colors.dimensionPill.color))
            .allowsHitTesting(false)
    }

    private var copiedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Colors.copiedCheck.color)
            Text("Copied")
                .font(.system(size: Theme.Typography.chip.size, weight: .semibold))
                .foregroundStyle(Theme.Colors.chipText.color)
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: Theme.QuickAccess.copiedChipHeight)
        .background(chipBackground)
        .allowsHitTesting(false)
    }

    private var chipBackground: some View {
        Capsule()
            .fill(Theme.Colors.chip.color)
            .overlay(Capsule().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
    }

    private var closeButton: some View {
        Button { handler.perform(.close) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Colors.chipText.color)
                .frame(width: Theme.QuickAccess.closeButtonSize, height: Theme.QuickAccess.closeButtonSize)
                .background(Circle().fill(Theme.Colors.chip.color))
                .overlay(Circle().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
        }
        .buttonStyle(CardPressStyle(reduceMotion: reduceMotion))
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 2) {
            backgroundSplitButton
            iconButton("pencil", label: "Annotate", key: "A", action: .annotate)
            iconButton(card.confirmedAction == .save ? "checkmark" : "square.and.arrow.down", label: "Save", key: "S", action: .save)
            iconButton(
                card.confirmedAction == .copy ? "checkmark" : (card.copiesFile ? "doc" : "doc.on.doc"),
                label: card.copiesFile ? "Copy File" : "Copy", key: card.copiesFile ? "\u{2325}C" : "C",
                action: card.copiesFile ? .copyFile : .copy
            )
            if card.savedURL != nil {
                iconButton("folder", label: "Show in Finder", key: nil, action: .reveal)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Theme.QuickAccess.controlBarHeight)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                Capsule().fill(Theme.Colors.chip.color)
            }
        }
        .overlay(Capsule().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
        .environment(\.colorScheme, .dark)
    }

    private var backgroundSplitButton: some View {
        HStack(spacing: 0) {
            Button { handler.perform(.background) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                    if !card.compactBar {
                        Text("Background")
                            .font(Theme.Typography.captionSemibold.font)
                            .fixedSize()
                    }
                }
                .padding(.leading, card.compactBar ? 7 : 9)
                .padding(.trailing, 5)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle(reduceMotion: reduceMotion))
            .help(card.backgroundApplied ? "Remove Background (B)" : "Background (B)")
            .accessibilityLabel(card.backgroundApplied ? "Remove Background" : "Apply Background")

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: 12)

            Button { handler.perform(.backgroundEditor) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle(reduceMotion: reduceMotion))
            .help("Edit Background")
            .accessibilityLabel("Edit Background")
        }
        .padding(.trailing, 2)
        .foregroundStyle(Theme.Colors.chipText.color)
        .background(Capsule().fill(Color.white.opacity(card.backgroundApplied ? 0.30 : 0.18)))
    }

    private func iconButton(_ symbol: String, label: String, key: String?, action: QuickAccessCardAction) -> some View {
        Button { handler.perform(action) } label: {
            ZStack {
                // The check cross-fades in from .85 scale (17.7 M5b); Reduce Motion keeps the fade.
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.chipText.color)
                    .id(symbol)
                    .transition(
                        reduceMotion ? .opacity : .scale(scale: Theme.Motion.copyCheckStartScale).combined(with: .opacity)
                    )
            }
            .frame(width: Theme.QuickAccess.controlButtonWidth, height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(CardPressStyle(reduceMotion: reduceMotion))
        .help(key.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }

    // MARK: Countdown

    @ViewBuilder private var countdownLine: some View {
        if let countdown = card.countdown, !card.isHovered {
            let width = card.thumbnailSize.width
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !countdown.duration.isFinite)) { context in
                Capsule()
                    .fill(Theme.Colors.text3.color)
                    .frame(width: width * countdown.fraction(at: context.date), height: Theme.QuickAccess.countdownLineHeight)
            }
            .padding(.leading, Theme.QuickAccess.cardPadding)
            .padding(.bottom, Theme.QuickAccess.countdownLineInset)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// Press feedback for card buttons (17.7 M4): highlight, and scale .96 unless Reduce Motion.
struct CardPressStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0)))
            .scaleEffect(configuration.isPressed && !reduceMotion ? Theme.Motion.pressScale : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: Theme.Motion.pressDown)
                    : Theme.Motion.enter(Theme.Motion.pressUp),
                value: configuration.isPressed
            )
    }
}

/// The card stack in the panel: newest at the corner edge, 8 pt apart, entry and dismissal as in
/// 17.7 M1, M2 and M6.
public struct QuickAccessStackView: View {
    let cards: [QuickAccessCardModel]
    let corner: QuickAccessCorner
    let handler: (String) -> QuickAccessCardHandler
    let interactive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        cards: [QuickAccessCardModel],
        corner: QuickAccessCorner,
        interactive: Bool = true,
        handler: @escaping (String) -> QuickAccessCardHandler
    ) {
        self.cards = cards
        self.corner = corner
        self.interactive = interactive
        self.handler = handler
    }

    private var isLeft: Bool { corner == .bottomLeft || corner == .topLeft }
    private var isBottom: Bool { corner == .bottomLeft || corner == .bottomRight }

    /// Bottom corners list the oldest first so the newest sits at the bottom edge.
    private var ordered: [QuickAccessCardModel] { isBottom ? cards.reversed() : cards }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let sign: Double = isLeft ? 1 : -1
        return .asymmetric(
            insertion: .offset(x: Theme.Motion.cardEnterOffsetX * sign).combined(with: .opacity),
            removal: .offset(x: Theme.Motion.cardDismissOffsetX * sign).combined(with: .opacity)
        )
    }

    public var body: some View {
        VStack(alignment: isLeft ? .leading : .trailing, spacing: Theme.QuickAccess.cardGap) {
            ForEach(ordered) { card in
                QuickAccessCardView(card: card, handler: handler(card.id), interactive: interactive)
                    .transition(transition)
            }
        }
        .padding(QuickAccessLayout.shadowMargin)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: Alignment(horizontal: isLeft ? .leading : .trailing, vertical: isBottom ? .bottom : .top)
        )
    }
}

/// The stack bound to a controller, for the panel.
struct QuickAccessControllerView: View {
    let controller: QuickAccessController

    var body: some View {
        QuickAccessStackView(cards: controller.cards, corner: controller.settings.corner) { id in
            controller.handler(for: id)
        }
    }
}

// MARK: Demo

/// Fixed cards for the `quick-access` shot and the tests (mockup section 2): an older card with
/// Background applied in its last 5 s, a hovered card, and the newest card with "Copied".
public enum QuickAccessDemo {
    public static let sceneSize = CGSize(width: 600, height: 760)

    public static func cards(dark: Bool = false) -> [QuickAccessCardModel] {
        guard let window = OverlayDemo.windowImage(dark: dark, scale: 1),
              let tall = OverlayDemo.windowImage(dark: dark, size: CGSize(width: 560, height: 640), scale: 1),
              let edited = backgroundImage(around: window) else { return [] }
        let newest = QuickAccessCardModel(id: "demo-newest", thumbnail: window, pointSize: CGSize(width: 842, height: 516))
        newest.showsCopied = true
        let hovered = QuickAccessCardModel(id: "demo-hovered", thumbnail: tall, pointSize: CGSize(width: 560, height: 640))
        hovered.isHovered = true
        let older = QuickAccessCardModel(id: "demo-older", thumbnail: edited, pointSize: CGSize(width: 914, height: 588))
        older.backgroundApplied = true
        older.countdown = .fixed(0.34)
        return [newest, hovered, older]
    }

    /// The stack at the bottom-left of a fake desktop corner, 16 pt in.
    public static func scene(cards: [QuickAccessCardModel], dark: Bool, size: CGSize = sceneSize) -> some View {
        let inset = Theme.QuickAccess.edgeInset - QuickAccessLayout.shadowMargin
        return ZStack(alignment: .bottomLeading) {
            if let desktop = OverlayDemo.desktopImage(dark: dark, scale: 1) {
                // The bottom-left corner of the 1280 x 800 desktop, at its own size.
                Image(decorative: desktop, scale: 1)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    .clipped()
            }
            QuickAccessStackView(cards: cards, corner: .bottomLeft, interactive: false) { _ in .inert }
                .frame(width: QuickAccessLayout.cardWidth(.medium) + 2 * QuickAccessLayout.shadowMargin)
                .offset(x: inset, y: -inset)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Renders a SwiftUI view with `ImageRenderer` at `scale`, resolving materials in the given
    /// appearance. No window.
    public static func render<Content: View>(_ content: Content, size: CGSize, dark: Bool, scale: Double = 2) -> CGImage? {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    public static func renderScene(dark: Bool, scale: Double = 2) -> CGImage? {
        render(scene(cards: cards(dark: dark), dark: dark), size: sceneSize, dark: dark, scale: scale)
    }

    /// A Background-style thumbnail: the window on a violet gradient with a margin.
    static func backgroundImage(around window: CGImage) -> CGImage? {
        let margin = 36
        let width = window.width + 2 * margin
        let height = window.height + 2 * margin
        guard let context = SyntheticImages.makeContext(width: width, height: height, flipped: false) else { return nil }
        let colors = [
            CGColor(srgbRed: 0.36, green: 0.30, blue: 0.88, alpha: 1),
            CGColor(srgbRed: 0.66, green: 0.36, blue: 0.86, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: SyntheticImages.colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        let rect = CGRect(x: margin, y: margin, width: window.width, height: window.height)
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
        context.draw(window, in: rect)
        return context.makeImage()
    }
}
