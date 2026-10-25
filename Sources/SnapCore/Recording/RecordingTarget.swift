import CoreGraphics
import Foundation

/// What a recording captures (design 20.6): an area, one window or a whole display. Rects are in
/// global top-left points, the space `DisplayInfo.frameTopLeft` and `WindowInfo.frame` use.
public enum RecordingTarget: Sendable, Hashable {
    /// An area selected in the overlay or HUD. It is recorded from the display it overlaps most.
    case area(CGRect)
    /// One window, recorded on its own (desktop independent), without its shadow.
    case window(WindowInfo)
    /// The whole display under the pointer.
    case fullscreen(displayID: DisplayID)

    public var mode: CaptureMode {
        switch self {
        case .area: .area
        case .window: .window
        case .fullscreen: .fullscreen
        }
    }

    /// The app that owned the window, for `sourceApp` and the `{app}` file name token.
    public var sourceApp: String? {
        if case .window(let window) = self { return window.ownerName }
        return nil
    }
}
