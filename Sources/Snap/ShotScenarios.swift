import AppKit
import CoreGraphics
import SnapCore
import SnapUI
import SwiftUI

/// The background screenshot scenarios (design 16): each surface built from the SnapUI demo
/// builders and fakes only. Nothing here creates a window or a panel, reads or writes Snap's
/// state, or touches a SnapSystem type.
enum ShotScenario: String, CaseIterable, Sendable {
    case overlayArea = "overlay-area"
    case overlayBefore = "overlay-before"
    case overlayWindow = "overlay-window"
    case quickAccess = "quick-access"
    case backgroundEditor = "background-editor"
    case annotate
    case menu
    case settings
    case settingsShortcuts = "settings-shortcuts"
    case onboarding
    case onboardingGranted = "onboarding-granted"
    case permissionHint = "permission-hint"

    /// What `scripts/shots.sh` renders by default and acceptance AC04 checks.
    static let acceptance: [ShotScenario] = [.overlayArea, .quickAccess, .backgroundEditor, .annotate, .menu, .settings]

    /// The size in points (design 16 table); the PNG is this times the scale.
    var pointSize: CGSize {
        switch self {
        case .overlayArea, .overlayBefore, .overlayWindow: OverlayDemo.display.frameTopLeft.size
        case .quickAccess: QuickAccessDemo.sceneSize
        case .backgroundEditor: BackgroundEditorDemo.size
        case .annotate: AnnotateDemo.size
        case .menu: MenuDemo.size
        case .settings, .settingsShortcuts: SettingsDemo.size
        case .onboarding: OnboardingDemo.size(granted: false)
        case .onboardingGranted: OnboardingDemo.size(granted: true)
        case .permissionHint: ShotScenario.hintSceneSize
        }
    }

    /// Room around the hint card for its shadow.
    private static let hintMargin = 40.0
    private static let hintSceneSize = CGSize(
        width: Theme.HintPanel.size.width + 2 * hintMargin, height: Theme.HintPanel.size.height + 2 * hintMargin
    )

    /// What to draw: an AppKit tree for `cacheDisplay`, or a finished image.
    enum Content {
        case view(NSView)
        case image(CGImage?)
    }

    func content(dark: Bool, scale: Double) -> Content {
        switch self {
        case .overlayArea:
            .image(OverlayDemo.render(OverlayDemo.areaState(dark: dark), dark: dark, scale: scale))
        case .overlayBefore:
            .image(OverlayDemo.render(OverlayDemo.beforeState(dark: dark), dark: dark, scale: scale))
        case .overlayWindow:
            .image(OverlayDemo.render(OverlayDemo.windowState(dark: dark), dark: dark, scale: scale))
        case .quickAccess:
            .image(QuickAccessDemo.renderScene(dark: dark, scale: scale))
        case .backgroundEditor:
            .view(BackgroundEditorDemo.makeView(dark: dark))
        case .annotate:
            .view(AnnotateDemo.makeView(dark: dark))
        case .menu:
            .view(MenuDemo.makeView(dark: dark))
        case .settings:
            .view(SettingsDemo.makeView(tab: .capture, dark: dark))
        case .settingsShortcuts:
            .view(SettingsDemo.makeView(tab: .shortcuts, dark: dark))
        case .onboarding:
            .view(OnboardingDemo.makeView(granted: false, dark: dark))
        case .onboardingGranted:
            .view(OnboardingDemo.makeView(granted: true, dark: dark))
        case .permissionHint:
            .image(QuickAccessDemo.render(hintScene(dark: dark), size: pointSize, dark: dark, scale: scale))
        }
    }

    /// The hint panel content over a plain desktop strip.
    private func hintScene(dark: Bool) -> some View {
        ZStack {
            Color(nsColor: (dark ? ThemeRGBA(hex: 0x1D2240) : ThemeRGBA(hex: 0xD9E2F5)).nsColor)
            PermissionHintView()
                .frame(width: Theme.HintPanel.size.width)
        }
        .frame(width: pointSize.width, height: pointSize.height)
    }
}
