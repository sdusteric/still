import SnapCore
import SwiftUI

/// The hover chrome of an unlocked pin (design 20.2, mockup 8): Close 8 pt inside the top-left
/// corner and, 8 pt inside the top-right corner, a 30 pt chip bar with the drop glyph, the 72 pt
/// opacity slider, the value, a divider, the click-through toggle and More. Under 260 pt the
/// slider hides and the value is a scrub control; under 120 pt only Close and More remain.
struct PinChromeView: View {
    let model: PinModel
    let handler: PinViewHandler

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            closeButton
                .padding(Theme.Pin.closeButtonInset)
            controlBar
                .padding(Theme.Pin.controlBarInset)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .environment(\.colorScheme, .dark)
    }

    private var closeButton: some View {
        Button { handler.perform(.close) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Colors.chipText.color)
                .frame(width: Theme.Pin.closeButtonSize, height: Theme.Pin.closeButtonSize)
                .background(Circle().fill(Theme.Colors.chip.color))
                .overlay(Circle().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
                .contentShape(Circle())
        }
        .buttonStyle(CardPressStyle(reduceMotion: false))
        .help("Close (Esc)")
        .accessibilityLabel("Close Pin")
    }

    private var controlBar: some View {
        let layout = model.chromeLayout
        return HStack(spacing: Theme.Pin.controlBarSpacing) {
            if layout != .minimal {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "drop")
                        .font(.system(size: Theme.Pin.dropGlyphSize - 2, weight: .medium))
                        .frame(width: Theme.Pin.dropGlyphSize, height: Theme.Pin.dropGlyphSize)
                    if layout == .full {
                        PinOpacitySlider(opacity: model.opacity) { handler.perform(.setOpacity($0)) }
                    }
                    valueLabel(scrubs: layout == .compact)
                }
                .padding(.trailing, Theme.Spacing.xxs)
                Rectangle()
                    .fill(Theme.Colors.chipDivider.color)
                    .frame(width: 1, height: Theme.Pin.dividerHeight)
                    .padding(.horizontal, Theme.Spacing.xxs)
                barButton(
                    "cursorarrow.slash", help: model.clickThrough ? "Turn Off Click-Through (L)" : "Click-Through (L)",
                    label: "Click-Through"
                ) { handler.perform(.toggleClickThrough) }
            }
            barButton("ellipsis", help: "More", label: "More") { handler.showMore() }
        }
        .padding(.leading, layout == .minimal ? Theme.Pin.controlBarTrailingPadding : Theme.Pin.controlBarLeadingPadding)
        .padding(.trailing, Theme.Pin.controlBarTrailingPadding)
        .frame(height: Theme.Pin.controlBarHeight)
        .foregroundStyle(Theme.Colors.chipText.color)
        .background(Capsule().fill(Theme.Colors.chip.color))
        .overlay(Capsule().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
    }

    @ViewBuilder
    private func valueLabel(scrubs: Bool) -> some View {
        let text = Text(model.opacityText)
            .font(Theme.Pin.valueStyle.font)
            .lineLimit(1)
            .fixedSize()
            .frame(width: Theme.Pin.valueWidth, alignment: .trailing)
        if scrubs {
            text
                .contentShape(Rectangle())
                .gesture(PinScrub.gesture(stepOpacity: handler.stepOpacity))
                .help("Drag to change the opacity")
                .accessibilityLabel("Opacity \(model.opacityText)")
        } else {
            text.accessibilityHidden(true)
        }
    }

    private func barButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: Theme.Pin.controlButtonSize.width, height: Theme.Pin.controlButtonSize.height)
                .contentShape(Capsule())
        }
        .buttonStyle(CardPressStyle(reduceMotion: false))
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The value as a scrub control on a narrow pin: a drag left or right steps the opacity by 5%
/// every few points, live (M21).
enum PinScrub {
    static let pointsPerStep = 6.0

    @MainActor
    static func gesture(stepOpacity: @escaping @MainActor (Int) -> Void) -> some Gesture {
        let applied = Box()
        return DragGesture(minimumDistance: 1)
            .onChanged { value in
                let steps = Int((value.translation.width / pointsPerStep).rounded(.towardZero))
                if steps != applied.steps {
                    stepOpacity(steps - applied.steps)
                    applied.steps = steps
                }
            }
            .onEnded { _ in applied.steps = 0 }
    }

    @MainActor
    final class Box {
        var steps = 0
    }
}

/// The 72 pt slider: white track at 0.28, white fill and a 14 pt knob. 20% to 100% in 5% steps,
/// updated live while dragging (design D49).
struct PinOpacitySlider: View {
    let opacity: Double
    let onChange: (Double) -> Void

    var body: some View {
        let width = Theme.Pin.sliderWidth
        let fraction = min(max(opacity, 0), 1)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.Colors.pinSliderTrack.color)
                .frame(width: width, height: Theme.Pin.sliderTrackHeight)
            Capsule()
                .fill(Theme.Colors.pinSliderFill.color)
                .frame(width: width * fraction, height: Theme.Pin.sliderTrackHeight)
            Circle()
                .fill(Theme.Colors.pinSliderFill.color)
                .frame(width: Theme.Pin.sliderKnobSize, height: Theme.Pin.sliderKnobSize)
                .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                .offset(x: width * fraction - Theme.Pin.sliderKnobSize / 2)
        }
        .frame(width: width, height: Theme.Pin.sliderKnobSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onChange(PinBoard.normalizedOpacity(value.location.x / width)) }
        )
        .accessibilityElement()
        .accessibilityLabel("Opacity")
        .accessibilityValue("\(Int((opacity * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? PinBoard.opacityStep : -PinBoard.opacityStep
            onChange(PinBoard.normalizedOpacity(opacity + step))
        }
    }
}
