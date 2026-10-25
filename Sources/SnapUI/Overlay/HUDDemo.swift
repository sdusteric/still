import AppKit
import SnapCore
import SwiftUI

/// The HUD and recording shot scenes (design 20.11: `hud`, `recording-countdown`, `recording`),
/// at the mockup's positions on the M2 fake desktop: the restored area 640 x 400 at (330, 150)
/// over the Notes window. The HUD scenes come from the real `OverlayController` in HUD mode with
/// no panels, so the shots show what the controller decides.
public enum HUDDemo {
    /// 1280 x 800 points at 2x.
    public static let display = DisplayInfo(id: 1, frameTopLeft: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)
    public static let area = CGRect(x: 330, y: 150, width: 640, height: 400)
    public static var sceneSize: CGSize { display.frameTopLeft.size }
    /// The pointer rests on the toolbar, so no magnifier or crosshair shows.
    static let pointer = CGPoint(x: 640, y: 750)
    /// The recording menu's top-left corner under the timer (mockup 11b).
    static let recordingMenuOrigin = CGPoint(x: 936, y: 30)

    /// A HUD controller on the demo display with the last area restored. Shows nothing.
    public static func makeController(mode: HUDMode) -> OverlayController {
        let controller = OverlayController(cursor: InertDemoCursor(), pointerLocation: { pointer })
        let last = LastArea(displayID: display.id, displayFrame: display.frameTopLeft, rect: area)
        let state = AllInOneState(mode: mode, target: .area, lastArea: last, displays: [display])
        controller.presentHUD(state, displays: [display]) { _ in }
        return controller
    }

    /// Mockup 10: Screenshot mode over the frozen desktop, the area with handles and its size
    /// chip, the toolbar at the bottom.
    public static func hudState(dark: Bool) -> SelectionOverlayState? {
        let controller = makeController(mode: .screenshot)
        if let desktop = PinDemo.desktop(dark: dark) {
            controller.showFrozen(CapturedImage(cgImage: desktop, scale: 2, displayID: display.id), displayID: display.id)
        }
        return controller.states[display.id]
    }

    /// Mockup 11a: Record confirmed, the countdown at 3 over the live desktop.
    public static func countdownState() -> SelectionOverlayState? {
        let controller = makeController(mode: .record)
        controller.confirmHUD()
        controller.showCountdown(3)
        return controller.states[display.id]
    }

    public static func renderHUD(dark: Bool, scale: Double = 2) -> CGImage? {
        guard let state = hudState(dark: dark) else { return nil }
        return OverlayDemo.render(state, dark: dark, scale: scale)
    }

    /// The overlay drawn over the desktop it leaves live (Record mode hides the frozen layer).
    public static func renderCountdown(dark: Bool, scale: Double = 2) -> CGImage? {
        guard let state = countdownState(), let overlay = OverlayDemo.render(state, dark: dark, scale: scale),
              let desktop = PinDemo.desktop(dark: dark, scale: scale) else { return nil }
        return M2DemoArt.render(size: sceneSize, scale: scale) { context in
            M2DemoArt.draw(desktop, in: CGRect(origin: .zero, size: sceneSize), context: context)
            M2DemoArt.draw(overlay, in: CGRect(origin: .zero, size: sceneSize), context: context)
        }
    }

    // MARK: Recording (mockup 11b)

    /// What the recording menu shows in the scene.
    public static let recordingMenuInput = RecordingMenuInput(
        target: .area, size: area.size, fps: 30, format: .h264, microphoneName: "MacBook Pro Microphone", systemAudio: false
    )

    /// The live desktop with the red timer in the menu bar and the outline 2 pt outside the area.
    static func recordingDesktop(dark: Bool, scale: Double = 2) -> CGImage? {
        let notes = M2DemoArt.notes(dark: dark, scale: scale)
        return M2DemoArt.render(size: sceneSize, scale: scale) { context in
            M2DemoArt.wallpaper(CGRect(origin: .zero, size: sceneSize), dark: dark, in: context)
            M2DemoArt.appWindow(PinDemo.browserFrame, title: "Browser", dark: dark, scale: scale, in: context) { body in
                M2DemoArt.browserBody(body, dark: dark)
            }
            M2DemoArt.window(PinDemo.notesFrame, dark: dark, scale: scale, in: context) { frame in
                if let notes { M2DemoArt.draw(notes, in: frame, context: context) }
            }
            recordingMenuBar(width: sceneSize.width, dark: dark, context: context)
            RecordingOutline.draw(around: area, context: context)
        }
    }

    /// The fake menu bar with the timer where the Snap symbol sits.
    static func recordingMenuBar(width: Double, dark: Bool, context: CGContext) {
        context.setFillColor(dark ? M2DemoArt.rgb(0x141418, alpha: 0.5) : CGColor(gray: 1, alpha: 0.42))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
        let color = M2DemoArt.text(dark: dark)
        var x = 14.0
        M2DemoArt.line("Notes", x: x, y: 0, font: M2DemoArt.font(13, .bold), color: color, lineHeight: 24)
        x += M2DemoArt.lineWidth("Notes", font: M2DemoArt.font(13, .bold)) + 16
        for item in ["File", "Edit", "View", "Window"] {
            M2DemoArt.line(item, x: x, y: 0, font: M2DemoArt.font(13, .medium), color: color, lineHeight: 24)
            x += M2DemoArt.lineWidth(item, font: M2DemoArt.font(13, .medium)) + 16
        }
        let clock = "Sat 14:03"
        let clockWidth = M2DemoArt.lineWidth(clock, font: M2DemoArt.font(13, .medium))
        M2DemoArt.line(clock, x: width - 14 - clockWidth, y: 0, font: M2DemoArt.font(13, .medium), color: color, lineHeight: 24)
        let text = RecordingIndicator.recording(since: 0).text(now: 42)
        let size = RecordingStatusItemView.capsuleSize(for: text)
        let timer = CGRect(x: width - 14 - clockWidth - 12 - size.width, y: (24 - size.height) / 2, width: size.width, height: size.height)
        RecordingStatusItemView.draw(text: text, in: timer, red: Theme.Colors.record.cgColor(dark: dark), context: context)
    }

    public static func recordingScene(dark: Bool) -> some View {
        let desktop = recordingDesktop(dark: dark)
        return ZStack(alignment: .topLeading) {
            if let desktop {
                Image(decorative: desktop, scale: 2).frame(width: sceneSize.width, height: sceneSize.height)
            }
            MenuPreviewView(
                items: RecordingMenuModel(recordingMenuInput).items, width: Theme.Recording.menuWidth
            )
            .offset(x: recordingMenuOrigin.x, y: recordingMenuOrigin.y)
        }
        .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    public static func renderRecording(dark: Bool, scale: Double = 2) -> CGImage? {
        QuickAccessDemo.render(recordingScene(dark: dark), size: sceneSize, dark: dark, scale: scale)
    }
}

/// Shot mode never touches the real cursor.
private final class InertDemoCursor: OverlayCursor {
    func hide() {}
    func unhide() {}
}
