import AppKit
import SnapCore
import SwiftUI

/// What a pin view calls. The panel supplies one per pin; shots use `inert`.
public struct PinViewHandler {
    public var perform: @MainActor (PinCommand) -> Void
    public var hover: @MainActor (Bool) -> Void
    /// Opacity scrub or scroll: steps of 5%.
    public var stepOpacity: @MainActor (Int) -> Void
    /// Opens the More menu.
    public var showMore: @MainActor () -> Void
    public var moveBegan: @MainActor () -> Void
    /// Translation since the drag began, top-left points.
    public var moveChanged: @MainActor (CGSize) -> Void
    public var moveEnded: @MainActor () -> Void
    /// Pinch: steps of 10% (positive grows).
    public var zoom: @MainActor (Int) -> Void

    public init(
        perform: @escaping @MainActor (PinCommand) -> Void = { _ in },
        hover: @escaping @MainActor (Bool) -> Void = { _ in },
        stepOpacity: @escaping @MainActor (Int) -> Void = { _ in },
        showMore: @escaping @MainActor () -> Void = {},
        moveBegan: @escaping @MainActor () -> Void = {},
        moveChanged: @escaping @MainActor (CGSize) -> Void = { _ in },
        moveEnded: @escaping @MainActor () -> Void = {},
        zoom: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        self.perform = perform
        self.hover = hover
        self.stepOpacity = stepOpacity
        self.showMore = showMore
        self.moveBegan = moveBegan
        self.moveChanged = moveChanged
        self.moveEnded = moveEnded
        self.zoom = zoom
    }

    public static var inert: PinViewHandler { PinViewHandler() }
}

/// One pinned capture (design 20.2, mockup 8): the image at the pin's opacity, clipped to radius 8
/// with a 0.5 pt ring for opaque captures, the hover chrome, the lock badge of a click-through pin
/// and the size chip during a resize or zoom.
public struct PinView: View {
    let model: PinModel
    let handler: PinViewHandler
    /// Shots draw the card shadow themselves; the live panel uses the window server's shadow.
    let drawsShadow: Bool
    /// False for `ImageRenderer`: the AppKit event view cannot be drawn offscreen.
    let interactive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: PinModel, handler: PinViewHandler = .inert, drawsShadow: Bool = false, interactive: Bool = true) {
        self.model = model
        self.handler = handler
        self.drawsShadow = drawsShadow
        self.interactive = interactive
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: model.isOpaque ? Theme.Pin.radius : 0, style: .continuous)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            image
            if interactive {
                PinEventView(handler: handler)
            }
            if model.showsChrome {
                PinChromeView(model: model, handler: handler)
                    .transition(.opacity)
            }
            if model.clickThrough {
                lockBadge
                    .padding(Theme.Pin.lockBadgeInset)
            }
        }
        .overlay(alignment: .bottom) {
            if let text = model.sizeChipText {
                // Appears and leaves with no fade (M21).
                PinSizeChip(text: text)
                    .padding(.bottom, Theme.Pin.sizeChipBottomInset)
                    .transition(.identity)
            }
        }
        .frame(width: model.frame.width, height: model.frame.height)
        .animation(
            model.showsChrome
                ? Theme.Motion.enter(Theme.Motion.hoverIn)
                : Theme.Motion.exit(Theme.Motion.hoverOut),
            value: model.showsChrome
        )
        .onHover { handler.hover($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned capture, \(model.opacityText) opacity")
    }

    private var image: some View {
        Image(decorative: model.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: model.frame.width, height: model.frame.height)
            .clipShape(shape)
            .overlay {
                if model.isOpaque {
                    shape.strokeBorder(Theme.Colors.cardEdge.color, lineWidth: Theme.Materials.edgeWidth)
                }
            }
            .compositingGroup()
            .shadow(
                color: .black.opacity(drawsShadow && model.isOpaque ? Theme.Materials.cardShadowOpacity : 0),
                radius: (Theme.Materials.cardShadowBlur + Theme.Materials.cardShadowSpread) / 2,
                y: Theme.Materials.cardShadowOffsetY
            )
            .opacity(model.opacity)
            .allowsHitTesting(false)
    }

    /// Why clicks pass through: an 18 pt badge 6 pt inside the top-left corner (design D50).
    private var lockBadge: some View {
        Image(systemName: "lock")
            .font(.system(size: Theme.Pin.lockGlyphSize, weight: .semibold))
            .foregroundStyle(Theme.Colors.chipText.color)
            .frame(width: Theme.Pin.lockBadgeSize, height: Theme.Pin.lockBadgeSize)
            .background(Circle().fill(Theme.Colors.lockBadge.color))
            .overlay(Circle().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
            .allowsHitTesting(false)
            .accessibilityLabel("Click-through on")
    }
}

/// `460 × 268 · 100%`: the chip of 17.2 with tabular digits.
struct PinSizeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.chip.font)
            .foregroundStyle(Theme.Colors.chipText.color)
            .padding(.horizontal, Theme.Overlay.chipHorizontalPadding)
            .frame(height: Theme.Overlay.chipHeight)
            .background(Capsule().fill(Theme.Colors.chip.color))
            .overlay(Capsule().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// The AppKit layer under the chrome: a drag anywhere on the image moves the pin 1:1, the scroll
/// wheel steps the opacity and a pinch zooms (design 20.2). It asks for key status on a click so
/// the pin's keys work without activating Snap.
struct PinEventView: NSViewRepresentable {
    var handler: PinViewHandler

    func makeNSView(context: Context) -> PinEventSourceView {
        let view = PinEventSourceView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: PinEventSourceView, context: Context) {
        view.handler = handler
    }
}

final class PinEventSourceView: NSView {
    /// Scroll distance, in points of precise delta, for one 5% opacity step.
    static let scrollPointsPerStep = 12.0
    /// Pinch magnification for one 10% zoom step.
    static let magnificationPerStep = 0.1

    var handler: PinViewHandler = .inert
    private var dragStart: CGPoint?
    private var scrollAccumulator = 0.0
    private var magnifyAccumulator = 0.0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = NSEvent.mouseLocation
        handler.moveBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        // Screen points grow upward; the board's top-left space grows downward.
        handler.moveChanged(CGSize(width: now.x - start.x, height: start.y - now.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        handler.moveEnded()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.scrollPointsPerStep
        scrollAccumulator += delta
        let steps = Int((scrollAccumulator / Self.scrollPointsPerStep).rounded(.towardZero))
        guard steps != 0 else { return }
        scrollAccumulator -= Double(steps) * Self.scrollPointsPerStep
        handler.stepOpacity(steps)
    }

    override func magnify(with event: NSEvent) {
        magnifyAccumulator += event.magnification
        let steps = Int((magnifyAccumulator / Self.magnificationPerStep).rounded(.towardZero))
        guard steps != 0 else { return }
        magnifyAccumulator -= Double(steps) * Self.magnificationPerStep
        handler.zoom(steps)
    }
}
