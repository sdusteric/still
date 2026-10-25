import CoreGraphics
import Foundation

/// What the user picked in the selection overlay or the all-in-one HUD.
public enum OverlaySelection: Sendable, Hashable {
    /// A rectangle in global top-left points on one display.
    case area(displayID: DisplayID, rect: CGRect)
    /// A window under the pointer. `includeShadow` already has Option-click applied.
    case window(WindowInfo, includeShadow: Bool)
    /// The HUD's Fullscreen target in Screenshot mode: the whole display (design 20.5).
    case fullscreen(displayID: DisplayID)
    /// The HUD confirmed in Record mode (design 20.5, 20.6). The presenter keeps its panels up for
    /// the countdown; whoever runs the recording dismisses them.
    case record(RecordingTarget)
    /// Esc, a screen change or an error closed the overlay.
    case cancelled
}

/// The overlay as the coordinator sees it (design 6.2, 7 and 20.5). Live: the pre-built panels in
/// SnapUI. Fake: a recording presenter in tests; `snapbench latency` drives the real controller
/// without panels.
///
/// Hotkey path rules: `present` and `presentHUD` must not wait on capture, disk or encoding, and
/// nothing animates.
@MainActor
public protocol OverlayPresenter: AnyObject {
    /// Orders the pre-built panels front with the dim layer and crosshair over the live screen.
    func present(mode: CaptureMode, displays: [DisplayInfo])
    /// Orders the same panels front as the all-in-one HUD: the toolbar, the restored area and the
    /// target in `state`. `modeChanged` is called when the user switches Screenshot and Record, so
    /// the coordinator can start the frozen captures that Record mode never asked for (D59).
    func presentHUD(_ state: AllInOneState, displays: [DisplayInfo], modeChanged: @escaping @MainActor (HUDMode) -> Void)
    /// Draws one display's frozen image 1:1 under the same dim. In HUD Record mode it is kept
    /// but not shown.
    func showFrozen(_ image: CapturedImage, displayID: DisplayID)
    /// Supplies the window list for window-mode hit-testing.
    func updateWindows(_ windows: [WindowInfo])
    /// Waits for the user's selection. A selection made before the frozen image arrives is kept.
    func selection() async -> OverlaySelection
    /// Orders the panels out at once, restoring the cursor.
    func dismiss()
}
