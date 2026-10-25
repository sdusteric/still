import AppKit
import CoreGraphics
import SnapCore
import SnapUI
import SwiftUI

/// The background screenshot scenarios (design 16 and 20.11): each surface built from the SnapUI
/// demo builders and fakes only. Nothing here creates a window or a panel, reads or writes Snap's
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
    // M2 (design 20.11), checked by AC-M2-9 and AC-M2-10.
    case pin
    case history
    case historyEmpty = "history-empty"
    case hud
    case recordingCountdown = "recording-countdown"
    case recording
    case quickAccessVideo = "quick-access-video"
    case annotateTools = "annotate-tools"
    case backgroundMesh = "background-mesh"
    case settingsRecording = "settings-recording"
    case menuM2 = "menu-m2"
    // Reliability and trust additions (design 20.16): `scripts/shots.sh m2-polish`.
    case recordingStalled = "recording-stalled"
    case quickAccessAudio = "quick-access-audio"
    case annotateReopened = "annotate-reopened"
    case menuPermission = "menu-permission"

    /// What `scripts/shots.sh` renders by default and acceptance AC04 checks.
    static let acceptance: [ShotScenario] = [.overlayArea, .quickAccess, .backgroundEditor, .annotate, .menu, .settings]

    /// What `scripts/shots.sh m2` renders: the eleven surfaces of design 20.11.
    static let milestone2: [ShotScenario] = [
        .pin, .history, .historyEmpty, .hud, .recordingCountdown, .recording, .quickAccessVideo, .annotateTools,
        .backgroundMesh, .settingsRecording, .menuM2,
    ]

    /// What `scripts/shots.sh m2-polish` renders: the surfaces of design 20.16.
    static let polish: [ShotScenario] = [.recordingStalled, .quickAccessAudio, .annotateReopened, .menuPermission]

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
        case .pin: PinDemo.sceneSize
        case .history, .historyEmpty: HistoryDemo.size
        case .hud, .recordingCountdown, .recording: HUDDemo.sceneSize
        case .quickAccessVideo: QuickAccessDemo.videoSceneSize
        case .annotateTools: AnnotateDemo.size
        case .backgroundMesh: BackgroundEditorDemo.size
        case .settingsRecording: SettingsDemo.size
        case .menuM2: MenuM2Demo.size
        case .recordingStalled: HUDDemo.sceneSize
        case .quickAccessAudio: QuickAccessDemo.videoSceneSize
        case .annotateReopened: AnnotateDemo.size
        case .menuPermission: MenuPermissionDemo.size
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
        case .pin:
            .image(PinDemo.renderScene(dark: dark, scale: scale))
        case .history:
            .view(HistoryDemo.makeView(empty: false, dark: dark))
        case .historyEmpty:
            .view(HistoryDemo.makeView(empty: true, dark: dark))
        case .hud:
            .image(HUDDemo.renderHUD(dark: dark, scale: scale))
        case .recordingCountdown:
            .image(HUDDemo.renderCountdown(dark: dark, scale: scale))
        case .recording:
            .image(HUDDemo.renderRecording(dark: dark, scale: scale))
        case .quickAccessVideo:
            .image(QuickAccessDemo.renderVideoScene(dark: dark, scale: scale))
        case .annotateTools:
            .view(AnnotateDemo.makeToolsView(dark: dark))
        case .backgroundMesh:
            .view(BackgroundEditorDemo.makeMeshView(dark: dark))
        case .settingsRecording:
            .view(SettingsDemo.makeView(tab: .recording, dark: dark))
        case .menuM2:
            .image(MenuM2Demo.renderScene(dark: dark, scale: scale))
        case .recordingStalled:
            .image(HUDDemo.renderRecordingStalled(dark: dark, scale: scale))
        case .quickAccessAudio:
            .image(QuickAccessDemo.renderAudioScene(dark: dark, scale: scale))
        case .annotateReopened:
            .view(AnnotateDemo.makeReopenedView(dark: dark))
        case .menuPermission:
            .image(MenuPermissionDemo.renderScene(dark: dark, scale: scale))
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
