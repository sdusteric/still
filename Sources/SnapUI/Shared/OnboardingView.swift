import AppKit
import Observation
import SnapCore
import SwiftUI

/// What the first-run window asks the app to do (design 13, 17.6). Injected: tests and shots
/// never request the permission.
public struct OnboardingActions {
    /// "Allow Access...": the app asks `PermissionState.requestDecision()` and makes the one
    /// permitted request, or opens the Screen Recording pane of System Settings.
    public var requestAccess: () -> Void
    /// "Relaunch Snap", offered when capture still fails after a grant.
    public var relaunch: () -> Void
    /// "Skip for now" or "Done": closes the window.
    public var finish: () -> Void

    public init(requestAccess: @escaping () -> Void = {}, relaunch: @escaping () -> Void = {},
                finish: @escaping () -> Void = {}) {
        self.requestAccess = requestAccess
        self.relaunch = relaunch
        self.finish = finish
    }
}

@MainActor
@Observable
public final class OnboardingModel {
    /// Step 1 is done: the preflight says yes.
    public var permissionGranted: Bool
    public var cleanShotRunning: Bool
    public var offersRelaunch: Bool
    @ObservationIgnored public var actions: OnboardingActions

    public init(permissionGranted: Bool = false, cleanShotRunning: Bool = false, offersRelaunch: Bool = false,
                actions: OnboardingActions = OnboardingActions()) {
        self.permissionGranted = permissionGranted
        self.cleanShotRunning = cleanShotRunning
        self.offersRelaunch = offersRelaunch
        self.actions = actions
    }
}

/// The first-run window content: app icon, "Welcome to Snap", two steps in one grouped list and
/// a footer. Never modal; Snap works without either step (design 13, 17.6, D43).
public struct OnboardingView: View {
    let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: OnboardingModel) {
        self.model = model
    }

    static let shortcutList = "\u{21E7}\u{2318}3, \u{21E7}\u{2318}4 and \u{21E7}\u{2318}5"

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                AppIconView()
                    .padding(.bottom, 18)
                Text("Welcome to Snap")
                    .font(Theme.Typography.title.font)
                    .tracking(Theme.Typography.title.size * Theme.Typography.title.tracking)
                    .foregroundStyle(Theme.Colors.text.color)
                    .accessibilityAddTraits(.isHeader)
                Text("Two things to set up before the first capture.")
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(Theme.Colors.text2.color)
                    .padding(.top, 4)
                steps
                    .padding(.top, 20)
            }
            .padding(.horizontal, Theme.Onboarding.padding)
            .padding(.top, Theme.Onboarding.padding + 6)
            .padding(.bottom, Theme.Spacing.l)
            Rectangle().fill(Theme.Colors.separator.color).frame(height: 1)
            footer
        }
        .frame(width: Theme.Onboarding.width)
        .background(Theme.Colors.window.color)
        .animation(reduceMotion ? nil : Theme.Motion.enter(Theme.Motion.firstRunStep), value: model.permissionGranted)
    }

    private var steps: some View {
        VStack(spacing: 0) {
            if model.permissionGranted {
                // M13 lives on the inserted row: SwiftUI does not reliably run a transition on a
                // child of an inserted view, so the row carries it and hands the scale to the check.
                grantedStep.transition(grantedTransition)
            } else {
                permissionStep
            }
            Rectangle().fill(Theme.Colors.separator.color).frame(height: 1).padding(.leading, Theme.Onboarding.stepPadding)
            shortcutStep
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Colors.fill.color)
        )
    }

    private var permissionStep: some View {
        StepRow(symbol: "display", tint: Theme.Colors.accent.color, active: true) {
            Text("Allow Screen Recording").font(Theme.Typography.headline.font)
            Text("Snap reads the screen only when you press a capture shortcut. Nothing leaves this Mac.")
                .font(Theme.Typography.caption.font)
                .foregroundStyle(Theme.Colors.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                Button("Allow Access\u{2026}") { model.actions.requestAccess() }
                    .buttonStyle(.borderedProminent)
                    .font(Theme.Typography.button.font)
                Text("Then turn on Snap under Screen & System Audio Recording.")
                    .font(Theme.Typography.captionSmall.font)
                    .foregroundStyle(Theme.Colors.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            if model.offersRelaunch {
                HStack(spacing: 8) {
                    Text("If you turned Snap on, relaunch it so macOS applies the change.")
                        .font(Theme.Typography.captionSmall.font)
                        .foregroundStyle(Theme.Colors.text2.color)
                    Button("Relaunch Snap") { model.actions.relaunch() }
                }
                .padding(.top, 4)
            }
        }
    }

    private var grantedTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let check = AnyTransition.modifier(
            active: GrantedCheckScale(scale: Theme.Motion.checkStartScale), identity: GrantedCheckScale(scale: 1)
        )
        return .asymmetric(
            insertion: check.animation(Theme.Motion.playfulSpring).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var grantedStep: some View {
        HStack(alignment: .center, spacing: 12) {
            GrantedCheck()
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording is on").font(Theme.Typography.headline.font)
                Text("Snap can capture the screen.")
                    .font(Theme.Typography.caption.font)
                    .foregroundStyle(Theme.Colors.text2.color)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Onboarding.stepPadding)
        .accessibilityElement(children: .combine)
    }

    private var shortcutStep: some View {
        StepRow(symbol: "command", tint: Theme.Colors.accent.color, active: model.permissionGranted) {
            Text("Take over your shortcuts").font(Theme.Typography.headline.font)
            Text(shortcutText)
                .font(Theme.Typography.caption.font)
                .foregroundStyle(Theme.Colors.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            if model.permissionGranted && model.cleanShotRunning {
                HStack(spacing: 6) {
                    Circle().fill(Theme.Colors.warningDot.color).frame(width: 7, height: 7)
                    Text("Waiting for CleanShot X to quit")
                        .font(Theme.Typography.caption.font)
                        .foregroundStyle(Theme.Colors.warning.color)
                }
                .padding(.top, 6)
            }
        }
    }

    private var shortcutText: String {
        guard model.permissionGranted else {
            return "Snap uses \(Self.shortcutList), the same keys as CleanShot X."
        }
        if model.cleanShotRunning {
            return "CleanShot X is running and uses \(Self.shortcutList). Quit it when you are ready and Snap "
                + "registers them on its own."
        }
        return "Nothing to do: CleanShot X is not running, so \(Self.shortcutList) are Snap's."
    }

    private var footer: some View {
        HStack {
            Text("You can change all of this later in Settings.")
                .font(Theme.Typography.captionSmall.font)
                .foregroundStyle(Theme.Colors.text2.color)
            Spacer()
            if model.permissionGranted {
                Button("Done") { model.actions.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip for now") { model.actions.finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.text2.color)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .font(Theme.Typography.button.font)
        .padding(.horizontal, Theme.Onboarding.footerHorizontalPadding)
        .padding(.vertical, Theme.Spacing.s)
    }
}

/// One step: a 36 pt tinted icon tile and the text. Inactive steps are dimmed.
private struct StepRow<Content: View>: View {
    let symbol: String
    let tint: Color
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? tint.opacity(0.14) : Theme.Colors.fill.color)
                .overlay(
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(active ? tint : Theme.Colors.text3.color)
                )
                .frame(width: Theme.Onboarding.stepIconSize, height: Theme.Onboarding.stepIconSize)
            VStack(alignment: .leading, spacing: 3) {
                content
            }
            .foregroundStyle(Theme.Colors.text.color)
            Spacer(minLength: 0)
        }
        .padding(Theme.Onboarding.stepPadding)
        .opacity(active ? 1 : Theme.Onboarding.inactiveStepOpacity)
        .accessibilityElement(children: .contain)
    }
}

/// The green check that scales in from 0.6 when the permission is granted (M13). The scale comes
/// from the granted row's insertion transition, so a static render (shots) shows the final state.
private struct GrantedCheck: View {
    @Environment(\.grantedCheckScale) private var scale

    var body: some View {
        Circle()
            .fill(Theme.Colors.success.color)
            .overlay(Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
            .frame(width: Theme.Onboarding.stepIconSize, height: Theme.Onboarding.stepIconSize)
            .scaleEffect(scale)
            .accessibilityHidden(true)
    }
}

/// The M13 transition's state: the check's scale, animated frame by frame and passed down.
struct GrantedCheckScale: ViewModifier, Animatable {
    var scale: Double

    var animatableData: Double {
        get { scale }
        set { scale = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.grantedCheckScale, scale)
    }
}

extension EnvironmentValues {
    @Entry var grantedCheckScale: Double = 1
}

/// The app icon drawn in code (design 17.8): a rounded square, #3B4CE0 to #8A4DE8, with a white
/// viewfinder.
struct AppIconView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Onboarding.iconRadius, style: .continuous)
            .fill(LinearGradient(
                colors: [ThemeRGBA(hex: 0x3B4CE0).color, ThemeRGBA(hex: 0x8A4DE8).color],
                startPoint: .bottomLeading, endPoint: .topTrailing
            ))
            .overlay(
                Image(systemName: "viewfinder")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            )
            .frame(width: Theme.Onboarding.iconSize, height: Theme.Onboarding.iconSize)
            // A neutral drop shadow, as macOS draws app icons; a tinted one reads as a glow.
            .shadow(color: .black.opacity(Theme.Onboarding.iconShadowOpacity), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

/// The first-run window in its two states (mockup section 7), for tests and shots.
public enum OnboardingDemo {
    /// The window's content size in that state: the app sizes the window to fit, so the shot does too.
    public static func size(granted: Bool) -> CGSize {
        let model = OnboardingModel(permissionGranted: granted, cleanShotRunning: true)
        let height = NSHostingController(rootView: OnboardingView(model: model))
            .sizeThatFits(in: CGSize(width: Theme.Onboarding.width, height: 10_000)).height
        return CGSize(width: Theme.Onboarding.width, height: height.rounded(.up))
    }

    public static func makeView(granted: Bool = false, dark: Bool = false) -> NSView {
        let model = OnboardingModel(permissionGranted: granted, cleanShotRunning: true)
        let size = size(granted: granted)
        let view = NSHostingView(rootView: OnboardingView(model: model)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Theme.Colors.window.color))
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }
}
