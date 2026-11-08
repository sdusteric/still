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
    /// Dismissed by a swipe: the release carried the card toward the edge, so its removal only
    /// fades (M7) instead of adding the M6 offset.
    public var swipeDismissed = false
    /// A screenshot, or a recording shown by its poster (design 20.6).
    public let kind: QuickAccessStack.CardKind
    /// A recording's length for the duration pill.
    public var durationSeconds: Double?
    /// The 4 s note chip ("Stopped: the window closed", "No microphone"), nil when none.
    public var note: String?
    /// A recording that does not play: Reveal in Finder and Close only (design D69).
    public var revealOnly = false
    /// Whether the asked-for audio is in a recording (design 20.6): a speaker in the duration pill
    /// when it is, a warning pill beside it when it is not. Nil when no audio was asked for.
    public var audioCheck: AudioCheck?
    @ObservationIgnored var pendingCloseAction: QuickAccessStack.CardAction?

    public init(
        id: String,
        thumbnail: CGImage,
        pointSize: CGSize,
        size: QuickAccessSize = .medium,
        corner: QuickAccessCorner = .bottomLeft,
        kind: QuickAccessStack.CardKind = .screenshot,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        self.size = size
        self.corner = corner
        self.kind = kind
        self.durationSeconds = durationSeconds
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

    public var isVideo: Bool { kind == .video }

    /// Whether the card offers `action`: what its kind allows, and only Reveal and Close on a
    /// recording that does not play.
    public func allows(_ action: QuickAccessCardAction) -> Bool {
        guard action.isAvailable(on: kind) else { return false }
        return !revealOnly || action == .reveal || action == .close
    }

    /// The duration pill of a video card: `0:42`, `1:02:05` after an hour.
    public var durationText: String { Self.durationText(durationSeconds ?? 0) }

    /// Whole seconds, rounded to the nearest: `0:42`, `12:05`, `1:02:05`.
    public static func durationText(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// What the pill at the bottom-left says: the size, or a recording's duration.
    public var pillText: String { isVideo ? durationText : dimensionText }

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
            .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        guard card.isVideo else { return "Screenshot \(card.dimensionText)" }
        let audio = card.audioCheck.map { $0.warning ?? "with audio" }
        return ["Recording \(card.durationText)", audio].compactMap(\.self).joined(separator: ", ")
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
                Group {
                    if card.isVideo {
                        HStack(spacing: Theme.QuickAccessM2.durationPillSpacing) {
                            durationPill
                            if let warning = card.audioCheck?.warning { audioWarningPill(warning) }
                        }
                    } else {
                        dimensionPill
                    }
                }
                .padding(Theme.Spacing.xs)
                .transition(.opacity)
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
            } else if let note = card.note {
                noteChip(note).padding(Theme.Spacing.xs).transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if card.isHovered && card.kind.canPin {
                pinButton.padding(Theme.QuickAccessM2.pinButtonInset).transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if card.isHovered {
                Group {
                    if card.isVideo { videoControlBar } else { controlBar }
                }
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
            // M10: the size text changes in place while the card height springs.
            .transaction { $0.animation = nil }
    }

    /// A recording's duration in place of the dimension pill: play glyph and `0:42` (mockup 11c).
    private var durationPill: some View {
        HStack(spacing: Theme.QuickAccessM2.durationPillSpacing) {
            Image(systemName: "play.fill")
                .font(.system(size: Theme.QuickAccessM2.durationGlyphSize, weight: .bold))
            Text(card.durationText)
                .font(Theme.Typography.chip.font)
            if card.audioCheck == .captured {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: Theme.QuickAccessM2.audioGlyphSize, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.Colors.chipText.color)
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .frame(height: Theme.QuickAccessM2.durationPillHeight)
        .background(Capsule().fill(Theme.Colors.dimensionPill.color))
        .allowsHitTesting(false)
    }

    /// "No audio track" or "Microphone silent" beside the duration pill, for as long as the card is
    /// up: the file is what gets shared, so the warning is not timed like the note chip. At Small
    /// only the glyph shows.
    private func audioWarningPill(_ warning: String) -> some View {
        HStack(spacing: Theme.QuickAccessM2.durationPillSpacing) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: Theme.QuickAccessM2.audioGlyphSize, weight: .semibold))
                .foregroundStyle(Theme.Colors.warningDot.color)
            if card.size != .small {
                Text(warning)
                    .font(Theme.Typography.chip.font)
                    .foregroundStyle(Theme.Colors.chipText.color)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, card.size == .small ? 6 : 7)
        .frame(height: Theme.QuickAccessM2.durationPillHeight)
        .background(Capsule().fill(Theme.Colors.dimensionPill.color))
        .allowsHitTesting(false)
        .help(warning)
        .accessibilityLabel(warning)
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

    /// A note about how the recording ended, in the Copied chip's style with a warning glyph.
    private func noteChip(_ note: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Colors.warningDot.color)
            Text(note)
                .font(.system(size: Theme.Typography.chip.size, weight: .semibold))
                .foregroundStyle(Theme.Colors.chipText.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: Theme.QuickAccess.copiedChipHeight)
        .background(chipBackground)
        .allowsHitTesting(false)
        .accessibilityLabel(note)
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

    /// Pin to Screen, mirroring Close at the top-right (design 20.2, mockup 11c).
    private var pinButton: some View {
        Button { handler.perform(.pin) } label: {
            Image(systemName: "pin")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Colors.chipText.color)
                .frame(width: Theme.QuickAccessM2.pinButtonSize, height: Theme.QuickAccessM2.pinButtonSize)
                .background(Circle().fill(Theme.Colors.chip.color))
                .overlay(Circle().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
        }
        .buttonStyle(CardPressStyle(reduceMotion: reduceMotion))
        .help("Pin to Screen (P)")
        .accessibilityLabel("Pin to Screen")
    }

    // MARK: Control bar

    /// The video card's bar (design 20.6): the labeled Open button, then Save, Reveal and Copy.
    private var videoControlBar: some View {
        HStack(spacing: 2) {
            if card.revealOnly {
                iconButton("folder", label: "Show in Finder", key: "R", action: .reveal)
            } else {
                videoActions
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

    @ViewBuilder private var videoActions: some View {
            Button { handler.perform(.open) } label: {
                HStack(spacing: Theme.QuickAccessM2.openButtonSpacing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    if card.size != .small {
                        Text("Open")
                            .font(Theme.Typography.captionSemibold.font)
                            .fixedSize()
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 10)
                .frame(height: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(CardPressStyle(reduceMotion: reduceMotion))
            .foregroundStyle(Theme.Colors.chipText.color)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .help("Open (O)")
            .accessibilityLabel("Open")
            iconButton(card.confirmedAction == .save ? "checkmark" : "square.and.arrow.down", label: "Save", key: "S", action: .save)
            iconButton("folder", label: "Show in Finder", key: "R", action: .reveal)
            iconButton(card.confirmedAction == .copy ? "checkmark" : "square.on.square", label: "Copy", key: "C", action: .copy)
    }

    private var controlBar: some View {
        HStack(spacing: 2) {
            backgroundSplitButton
            iconButton("pencil.line", label: "Annotate", key: "A", action: .annotate)
            iconButton(card.confirmedAction == .save ? "checkmark" : "square.and.arrow.down", label: "Save", key: "S", action: .save)
            iconButton(
                card.confirmedAction == .copy ? "checkmark" : (card.copiesFile ? "doc" : "square.on.square"),
                label: card.copiesFile ? "Copy File" : "Copy", key: card.copiesFile ? "\u{2325}C" : "C",
                action: card.copiesFile ? .copyFile : .copy, help: card.copiesFile ? nil : "Copy (C), Copy Text (T)"
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
                    Image(systemName: "rectangle.center.inset.filled")
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

    private func iconButton(
        _ symbol: String, label: String, key: String?, action: QuickAccessCardAction, help: String? = nil
    ) -> some View {
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
        .help(help ?? key.map { "\(label) (\($0))" } ?? label)
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

    /// Entry rides the transaction's spring (M1). The removal has its own exit curve (M6), so the
    /// cards that stay can close the gap on the spring (M2) in the same transaction.
    private func transition(for card: QuickAccessCardModel) -> AnyTransition {
        guard !reduceMotion else {
            return .asymmetric(
                insertion: .opacity,
                removal: .opacity.animation(QuickAccessMotion.removal(reduceMotion: true))
            )
        }
        let sign: Double = isLeft ? 1 : -1
        let removal = AnyTransition.modifier(
            active: CardRemovalOffset(card: card, offset: Theme.Motion.cardDismissOffsetX * sign),
            identity: CardRemovalOffset(card: card, offset: 0)
        )
        return .asymmetric(
            insertion: .offset(x: Theme.Motion.cardEnterOffsetX * sign).combined(with: .opacity),
            removal: removal.combined(with: .opacity).animation(QuickAccessMotion.removal(reduceMotion: false))
        )
    }

    public var body: some View {
        VStack(alignment: isLeft ? .leading : .trailing, spacing: Theme.QuickAccess.cardGap) {
            ForEach(ordered) { card in
                QuickAccessCardView(card: card, handler: handler(card.id), interactive: interactive)
                    .transition(transition(for: card))
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

/// The M6 removal offset, read when the removal runs: a swiped card already moved toward the
/// edge with its release velocity, so it only fades.
private struct CardRemovalOffset: ViewModifier {
    let card: QuickAccessCardModel
    let offset: Double

    func body(content: Content) -> some View {
        content.offset(x: card.swipeDismissed ? 0 : offset)
    }
}

/// The animations of the stack's reflow and removal (17.7 M2, M6, M7; Reduce Motion rows).
public enum QuickAccessMotion {
    /// Cards that stay move to their new place (gap closing, a card's height changing): the
    /// spring, or at once under Reduce Motion.
    public static func reflow(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Theme.Motion.spring
    }

    /// A closing card leaves on the exit curve in 220 ms, or fades in 100 ms under Reduce Motion.
    public static func removal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Theme.Motion.reducedMotionFade) : Theme.Motion.exit(Theme.Motion.dismiss)
    }

    /// A swipe past the threshold hands its release velocity (points per second, toward the edge)
    /// to the momentum spring over the M6 distance.
    public static func swipeRelease(velocity: Double) -> Animation {
        let distance = abs(Theme.Motion.cardDismissOffsetX)
        return .interpolatingSpring(
            Spring(response: Theme.Motion.springResponse, dampingRatio: Theme.Motion.momentumDamping),
            initialVelocity: max(velocity, 0) / distance
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

    // MARK: Video card scene

    /// The `quick-access-video` shot (mockup 11c): 600 x 760 pt.
    public static let videoSceneSize = CGSize(width: 600, height: 760)
    static let messagesFrame = CGRect(x: 300, y: 90, width: 276, height: 520)

    /// Top to bottom: a hovered screenshot card with the Pin chip, a hovered video card and a
    /// fresh video card with the duration pill and Copied.
    public static func videoCards(dark: Bool = false) -> [QuickAccessCardModel] {
        guard let notes = M2DemoArt.notes(dark: dark, scale: 1),
              let poster = M2DemoArt.terminal(M2DemoArt.buildLines, size: CGSize(width: 360, height: 225), dark: dark, bar: true)
        else { return [] }
        let recording = CGSize(width: 1280, height: 800)
        let fresh = QuickAccessCardModel(
            id: "demo-video-fresh", thumbnail: poster, pointSize: recording, kind: .video, durationSeconds: 42
        )
        fresh.showsCopied = true
        let hoveredVideo = QuickAccessCardModel(
            id: "demo-video-hovered", thumbnail: poster, pointSize: recording, kind: .video, durationSeconds: 42
        )
        hoveredVideo.isHovered = true
        let screenshot = QuickAccessCardModel(id: "demo-screenshot", thumbnail: notes, pointSize: CGSize(width: 842, height: 516))
        screenshot.isHovered = true
        return [fresh, hoveredVideo, screenshot]
    }

    /// The desktop of the video card scene: wallpaper, menu bar and a Messages window.
    public static func videoDesktop(dark: Bool, scale: Double = 2) -> CGImage? {
        M2DemoArt.render(size: videoSceneSize, scale: scale) { context in
            M2DemoArt.wallpaper(CGRect(origin: .zero, size: videoSceneSize), dark: dark, in: context)
            M2DemoArt.appWindow(messagesFrame, title: "Messages", dark: dark, scale: scale, in: context) { body in
                let width = body.width - 32
                let font = M2DemoArt.font(13)
                let first = CGRect(x: body.minX + 16, y: body.minY + 16, width: width, height: 32)
                M2DemoArt.fillRounded(first, radius: 16, color: Theme.Colors.thumbnailBacking.cgColor(dark: dark), in: context)
                M2DemoArt.line("Can you show me the bug?", x: first.minX + 12, y: first.minY + 7, font: font,
                               color: M2DemoArt.text(dark: dark), lineHeight: 18)
                let reply = "Recording it now."
                let replyWidth = M2DemoArt.lineWidth(reply, font: font) + 24
                let second = CGRect(x: body.maxX - 16 - replyWidth, y: first.maxY + 10, width: replyWidth, height: 32)
                M2DemoArt.fillRounded(second, radius: 16, color: Theme.Colors.accent.cgColor(dark: dark), in: context)
                M2DemoArt.line(reply, x: second.minX + 12, y: second.minY + 7, font: font, color: .white, lineHeight: 18)
            }
            M2DemoArt.menuBar(width: videoSceneSize.width, dark: dark, in: context)
        }
    }

    public static func videoScene(dark: Bool) -> some View {
        let inset = Theme.QuickAccess.edgeInset - QuickAccessLayout.shadowMargin
        let desktop = videoDesktop(dark: dark)
        return ZStack(alignment: .bottomLeading) {
            if let desktop {
                Image(decorative: desktop, scale: 2)
                    .frame(width: videoSceneSize.width, height: videoSceneSize.height)
            }
            QuickAccessStackView(cards: videoCards(dark: dark), corner: .bottomLeft, interactive: false) { _ in .inert }
                .frame(width: QuickAccessLayout.cardWidth(.medium) + 2 * QuickAccessLayout.shadowMargin)
                .offset(x: inset, y: -inset)
        }
        .frame(width: videoSceneSize.width, height: videoSceneSize.height, alignment: .bottomLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    public static func renderVideoScene(dark: Bool, scale: Double = 2) -> CGImage? {
        render(videoScene(dark: dark), size: videoSceneSize, dark: dark, scale: scale)
    }

    // MARK: Audio check scene

    /// Top to bottom: a recording whose microphone was silent, one that lost its audio track, and
    /// the newest, whose sound came through (design 20.6, audio check).
    public static func audioCards(dark: Bool = false) -> [QuickAccessCardModel] {
        guard let poster = M2DemoArt.terminal(M2DemoArt.buildLines, size: CGSize(width: 360, height: 225), dark: dark, bar: true)
        else { return [] }
        let recording = CGSize(width: 1280, height: 800)
        let checks: [(String, AudioCheck, Double)] = [
            ("demo-audio-captured", .captured, 42), ("demo-audio-missing", .noTrack, 95), ("demo-audio-silent", .microphoneSilent, 3_725),
        ]
        return checks.map { id, check, seconds in
            let card = QuickAccessCardModel(id: id, thumbnail: poster, pointSize: recording, kind: .video, durationSeconds: seconds)
            card.audioCheck = check
            card.showsCopied = check == .captured
            return card
        }
    }

    /// The `quick-access-audio` shot: the three audio cards on the video scene's desktop.
    public static func audioScene(dark: Bool) -> some View {
        let inset = Theme.QuickAccess.edgeInset - QuickAccessLayout.shadowMargin
        let desktop = videoDesktop(dark: dark)
        return ZStack(alignment: .bottomLeading) {
            if let desktop {
                Image(decorative: desktop, scale: 2)
                    .frame(width: videoSceneSize.width, height: videoSceneSize.height)
            }
            QuickAccessStackView(cards: audioCards(dark: dark), corner: .bottomLeft, interactive: false) { _ in .inert }
                .frame(width: QuickAccessLayout.cardWidth(.medium) + 2 * QuickAccessLayout.shadowMargin)
                .offset(x: inset, y: -inset)
        }
        .frame(width: videoSceneSize.width, height: videoSceneSize.height, alignment: .bottomLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    public static func renderAudioScene(dark: Bool, scale: Double = 2) -> CGImage? {
        render(audioScene(dark: dark), size: videoSceneSize, dark: dark, scale: scale)
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
