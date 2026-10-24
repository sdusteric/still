import CoreGraphics
import Foundation

/// What the user picked in the selection overlay.
public enum OverlaySelection: Sendable, Hashable {
    /// A rectangle in global top-left points on one display.
    case area(displayID: DisplayID, rect: CGRect)
    /// A window under the pointer. `includeShadow` already has Option-click applied.
    case window(WindowInfo, includeShadow: Bool)
    /// Esc, a screen change or an error closed the overlay.
    case cancelled
}

/// The selection overlay as the coordinator sees it (design 6.2 and 7). Live: the pre-built
/// panels in SnapUI. Fake: a recording presenter in tests; `snapbench latency` drives the real controller without panels.
///
/// Hotkey path rules: `present` must not wait on capture, disk or encoding, and nothing animates.
@MainActor
public protocol OverlayPresenter: AnyObject {
    /// Orders the pre-built panels front with the dim layer and crosshair over the live screen.
    func present(mode: CaptureMode, displays: [DisplayInfo])
    /// Draws one display's frozen image 1:1 under the same dim.
    func showFrozen(_ image: CapturedImage, displayID: DisplayID)
    /// Supplies the window list for window-mode hit-testing.
    func updateWindows(_ windows: [WindowInfo])
    /// Waits for the user's selection. A selection made before the frozen image arrives is kept.
    func selection() async -> OverlaySelection
    /// Orders the panels out at once, restoring the cursor.
    func dismiss()
}
