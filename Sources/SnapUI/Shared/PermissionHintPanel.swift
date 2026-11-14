import AppKit
import Observation
import SnapCore
import SwiftUI

/// "Screen Recording needs your OK" (design 13, 17.6, 20.16): 500 pt wide, card material, a
/// warning-tinted monitor icon and an "Open System Settings" button.
public struct PermissionHintView: View {
    var onOpenSettings: () -> Void
    /// Permission was asked for before and macOS still says no: the entry in System Settings is
    /// stale (often after a rebuild), so turning it on does nothing until Snap is removed and added.
    var reapproval: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(reapproval: Bool = false, onOpenSettings: @escaping () -> Void = {}) {
        self.reapproval = reapproval
        self.onOpenSettings = onOpenSettings
    }

    static func detail(reapproval: Bool) -> String {
        reapproval
            ? "If Still is already on, remove it, add it back, then relaunch Still."
            : "Turn on Still in Screen & System Audio Recording."
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.HintPanel.radius, style: .continuous)
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "display")
                // Monochrome keeps the screen empty, as in the mockup; the default fills it.
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.warning.color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.Colors.warningBackground.color))
            VStack(alignment: .leading, spacing: 0) {
                Text("Screen Recording needs your OK")
                    .font(Theme.Typography.headline.font)
                    .foregroundStyle(Theme.Colors.text.color)
                Text(Self.detail(reapproval: reapproval))
                    .font(Theme.Typography.caption.font)
                    .foregroundStyle(Theme.Colors.text2.color)
                    .padding(.top, 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            // The text takes all the room up to the button, so the title wraps only where it must.
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open System Settings", action: onOpenSettings)
                .controlSize(.regular)
                .fixedSize()
        }
        .padding(.vertical, Theme.HintPanel.padding)
        .padding(.leading, 14)
        .padding(.trailing, Theme.HintPanel.padding)
        .frame(width: Theme.HintPanel.size.width)
        .background {
            if reduceTransparency {
                shape.fill(Theme.Colors.window.color)
            } else {
                shape.fill(Theme.Materials.card)
            }
        }
        .overlay { shape.strokeBorder(Theme.Colors.cardEdge.color, lineWidth: Theme.Materials.edgeWidth) }
        .compositingGroup()
        .shadow(
            color: .black.opacity(Theme.Materials.cardShadowOpacity),
            radius: (Theme.Materials.cardShadowBlur + Theme.Materials.cardShadowSpread) / 2,
            y: Theme.Materials.cardShadowOffsetY
        )
    }
}

/// What the hint controller needs from its window. Tests use none.
@MainActor
public protocol PermissionHintSurface: AnyObject {
    /// The window number while the panel is on screen, so display captures can exclude it.
    /// Nil while it is ordered out.
    var windowID: WindowID? { get }
    func show(frame: CGRect)
    func hide()
}

/// The hint's visibility, animated by the hosted view (17.7 M14).
@Observable
final class PermissionHintModel {
    var visible = false
    /// A one-line message chip shown in place of the permission card, nil for the card.
    var message: String?
    /// The chip is a warning (triangle) or a confirmation such as "Text copied" (check).
    var messageIsWarning = true
    var reapproval = false
}

/// A one-line hint chip near the pointer, such as "Recording could not start" (design D69).
struct HintMessageChip: View {
    let message: String
    var warning = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? Theme.Colors.warningDot.color : Theme.Colors.success.color)
            Text(message)
                .font(Theme.Typography.captionSemibold.font)
                .foregroundStyle(Theme.Colors.chipText.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(Theme.Colors.chip.color)
                .overlay(Capsule().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// Shows the hint near the pointer for 6 s when a capture hotkey is pressed without permission
/// (design 13). No modal alert and no permission request: the button only calls `onOpenSettings`.
@Observable
public final class PermissionHintController {
    public typealias SurfaceFactory = @MainActor (PermissionHintController) -> (any PermissionHintSurface)?

    public private(set) var isVisible = false
    /// True from `show` until the panel is ordered out, which is after the fade-out ends.
    @ObservationIgnored public private(set) var isPanelOnScreen = false
    let model = PermissionHintModel()

    @ObservationIgnored public var onOpenSettings: @MainActor () -> Void
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let makeSurface: SurfaceFactory?
    @ObservationIgnored private var surface: (any PermissionHintSurface)?
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private var hideAt: TimeInterval?
    @ObservationIgnored private var orderOutAt: TimeInterval?
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// Room around the card inside the panel for its shadow and the 6 pt rise.
    public static let margin = 40.0

    public init(
        clock: any Clock,
        reduceMotion: @escaping @MainActor () -> Bool = { false },
        onOpenSettings: @escaping @MainActor () -> Void = {},
        makeSurface: SurfaceFactory? = nil
    ) {
        self.clock = clock
        self.reduceMotion = reduceMotion
        self.onOpenSettings = onOpenSettings
        self.makeSurface = makeSurface
    }

    /// The panel frame in `NSScreen` coordinates: centred under the pointer, kept inside `visibleFrame`.
    public static func panelFrame(pointer: CGPoint, visibleFrame: CGRect) -> CGRect {
        let width = Theme.HintPanel.size.width + 2 * margin
        let height = Theme.HintPanel.size.height + 2 * margin
        var x = pointer.x - width / 2
        var y = pointer.y - Theme.Spacing.l - height + margin
        x = min(max(x, visibleFrame.minX - margin), visibleFrame.maxX - width + margin)
        y = min(max(y, visibleFrame.minY - margin), visibleFrame.maxY - height + margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The message chip on screen, nil while the permission card (or nothing) is shown.
    public var message: String? { isVisible ? model.message : nil }

    /// Shows the hint near `pointer` (`NSScreen` coordinates); a second call restarts the 6 s.
    /// - Parameter reapproval: the stale-entry text (`PermissionState.needsReapproval`).
    public func show(near pointer: CGPoint, visibleFrame: CGRect, reapproval: Bool = false) {
        model.reapproval = reapproval
        present(message: nil, seconds: Theme.HintPanel.visibleSeconds, near: pointer, visibleFrame: visibleFrame)
    }

    /// Shows a one-line chip near `pointer` for 4 s in place of the permission card, such as
    /// "Recording could not start" (design D69) or "Text copied".
    public func show(message: String, warning: Bool = true, near pointer: CGPoint, visibleFrame: CGRect) {
        model.messageIsWarning = warning
        present(message: message, seconds: Theme.HintPanel.messageSeconds, near: pointer, visibleFrame: visibleFrame)
    }

    /// The text under the title while the permission card shows, for tests.
    public var detail: String? {
        isVisible && model.message == nil ? PermissionHintView.detail(reapproval: model.reapproval) : nil
    }

    private func present(message: String?, seconds: Double, near pointer: CGPoint, visibleFrame: CGRect) {
        if surface == nil, let makeSurface { surface = makeSurface(self) }
        surface?.show(frame: Self.panelFrame(pointer: pointer, visibleFrame: visibleFrame))
        model.message = message
        isVisible = true
        isPanelOnScreen = surface != nil
        orderOutAt = nil
        hideAt = clock.now() + seconds
        withAnimation(reduceMotion() ? .easeOut(duration: Theme.Motion.hintIn) : Theme.Motion.enter(Theme.Motion.hintIn)) {
            model.visible = true
        }
        schedule()
    }

    public func hide() {
        guard isVisible else { return }
        isVisible = false
        hideAt = nil
        withAnimation(Theme.Motion.exit(Theme.Motion.hintOut)) {
            model.visible = false
        }
        orderOutAt = clock.now() + Theme.Motion.hintOut
        schedule()
    }

    /// The panel's window while it is on screen (fading out included), for the capture to exclude.
    public var surfaceWindowIDs: [WindowID] {
        guard isPanelOnScreen, let id = surface?.windowID else { return [] }
        return [id]
    }

    func openSettings() {
        onOpenSettings()
        hide()
    }

    /// Applies timers that have run out. Tests call it after advancing a `FakeClock`.
    public func processTimers() {
        let now = clock.now()
        if let hideAt, hideAt <= now { hide() }
        if let orderOutAt, orderOutAt <= now {
            self.orderOutAt = nil
            surface?.hide()
            isPanelOnScreen = false
        }
        schedule()
    }

    private func schedule() {
        timerTask?.cancel()
        timerTask = nil
        guard let next = [hideAt, orderOutAt].compactMap({ $0 }).min() else { return }
        let delay = max(next - clock.now(), 0.001)
        let clock = clock
        timerTask = Task { [weak self] in
            do { try await clock.sleep(seconds: delay) } catch { return }
            self?.processTimers()
        }
    }
}

/// The hosted view: fades in and rises 6 pt, fades out (opacity only under Reduce Motion).
struct PermissionHintPanelContent: View {
    let controller: PermissionHintController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let message = controller.model.message {
                HintMessageChip(message: message, warning: controller.model.messageIsWarning)
            } else {
                PermissionHintView(reapproval: controller.model.reapproval) { controller.openSettings() }
            }
        }
        .opacity(controller.model.visible ? 1 : 0)
        .offset(y: controller.model.visible || reduceMotion ? 0 : Theme.HintPanel.rise)
        .padding(PermissionHintController.margin)
    }
}

/// The small non-activating panel that carries the hint. It never becomes key or main.
public final class PermissionHintPanel: NSPanel, PermissionHintSurface {
    public init(controller: PermissionHintController) {
        super.init(
            contentRect: CGRect(origin: .zero, size: PermissionHintController.panelFrame(pointer: .zero, visibleFrame: .zero).size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let hosting = FirstMouseHostingView(rootView: PermissionHintPanelContent(controller: controller))
        hosting.sizingOptions = []
        contentView = hosting
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    public var windowID: WindowID? { isVisible && windowNumber > 0 ? WindowID(windowNumber) : nil }

    public func show(frame: CGRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    public func hide() {
        orderOut(nil)
    }

    public static func makeSurface(controller: PermissionHintController) -> (any PermissionHintSurface)? {
        PermissionHintPanel(controller: controller)
    }
}
