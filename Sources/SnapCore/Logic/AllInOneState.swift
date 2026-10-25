import CoreGraphics
import Foundation

/// The last confirmed area (design D58), stored in `state.json`. `displayFrame` is the display's
/// frame when the area was confirmed: the fingerprint that must match for a restore. All rects are
/// global top-left points.
public struct LastArea: Sendable, Hashable, Codable {
    public var displayID: DisplayID
    public var displayFrame: CGRect
    public var rect: CGRect

    public init(displayID: DisplayID, displayFrame: CGRect, rect: CGRect) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.rect = rect
    }

    /// The area to store for `rect`, on the display that holds its center (or the first display).
    public static func store(_ rect: CGRect, displays: [DisplayInfo]) -> LastArea? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = displays.first(where: { $0.frameTopLeft.contains(center) }) ?? displays.first else { return nil }
        return LastArea(displayID: display.id, displayFrame: display.frameTopLeft, rect: rect)
    }

    /// The stored rect, exactly, when a display with the same id and the same frame is present.
    public func restore(on displays: [DisplayInfo]) -> CGRect? {
        guard displays.contains(where: { $0.id == displayID && $0.frameTopLeft == displayFrame }) else { return nil }
        guard rect.width > 0, rect.height > 0, displayFrame.contains(rect) else { return nil }
        return rect
    }
}

/// A key the HUD handles (design 20.5).
public enum HUDKey: Sendable, Hashable {
    case one, two, three
    case r
    case tab
    case returnKey
    case escape
    /// An arrow nudge in points (1, or 10 with Shift), x right and y down.
    case arrow(dx: Double, dy: Double)

    /// The key for a typed character, case insensitive.
    public init?(character: Character) {
        switch character.lowercased() {
        case "1": self = .one
        case "2": self = .two
        case "3": self = .three
        case "r": self = .r
        case "\t": self = .tab
        case "\r", "\n": self = .returnKey
        case "\u{1B}": self = .escape
        default: return nil
        }
    }
}

/// What a HUD key asks the controller to do.
public enum HUDOutcome: Sendable, Hashable {
    /// Nothing changed.
    case none
    /// Mode, target or area changed: redraw.
    case changed
    case confirm
    case cancel
}

/// Where the HUD toolbar sits (design 20.5).
public enum HUDToolbarEdge: Sendable, Hashable {
    case bottom, top
}

/// The all-in-one HUD's state (design 20.5): mode, target, the editable area and the toolbar
/// position. Pure; `OverlayController` in HUD mode draws it.
public struct AllInOneState: Sendable, Hashable {
    /// The toolbar sits this far inside the visible frame's bottom (or top) edge.
    public static let toolbarEdgeInset: Double = 28

    public var mode: HUDMode
    public var target: CaptureMode
    /// The area in global top-left points; nil until one is restored or drawn.
    public var area: CGRect?
    /// True when `area` came from the stored last area.
    public private(set) var restoredArea: Bool

    public init(mode: HUDMode = .screenshot, target: CaptureMode = .area, lastArea: LastArea? = nil, displays: [DisplayInfo] = []) {
        self.mode = mode
        self.target = target
        let restored = lastArea?.restore(on: displays)
        self.area = restored
        self.restoredArea = restored != nil
    }

    /// Screenshot mode starts the frozen display capture and shows it; Record mode shows the live
    /// screen behind the dim and requests no frozen capture (design D59).
    public var showsFrozenLayer: Bool { mode == .screenshot }
    public var needsFrozenCapture: Bool { mode == .screenshot }

    /// The primary button title: "Capture" or "Record".
    public var primaryTitle: String { mode == .screenshot ? "Capture" : "Record" }

    /// Return confirms an area only once there is one; window and fullscreen confirm the target
    /// under the pointer.
    public var canConfirm: Bool {
        target != .area || (area.map { $0.width > 0 && $0.height > 0 } ?? false)
    }

    public mutating func handle(_ key: HUDKey) -> HUDOutcome {
        switch key {
        case .one: return setTarget(.area)
        case .two: return setTarget(.window)
        case .three: return setTarget(.fullscreen)
        case .r:
            mode = mode.toggled
            return .changed
        case .tab:
            return setTarget(target == .window ? .area : .window)
        case .returnKey:
            return canConfirm ? .confirm : .none
        case .escape:
            return .cancel
        case .arrow(let dx, let dy):
            guard target == .area, let current = area else { return .none }
            area = current.offsetBy(dx: dx, dy: dy)
            return .changed
        }
    }

    public mutating func setTarget(_ newTarget: CaptureMode) -> HUDOutcome {
        guard newTarget != target else { return .none }
        target = newTarget
        return .changed
    }

    public mutating func setMode(_ newMode: HUDMode) -> HUDOutcome {
        guard newMode != mode else { return .none }
        mode = newMode
        return .changed
    }

    /// A drawn or edited area (drag, handles). Clears the restored flag.
    public mutating func setArea(_ rect: CGRect?) {
        area = rect
        restoredArea = false
    }

    // MARK: Toolbar

    /// The toolbar frame on `display`: centered, 28 pt above the visible frame's bottom; moved to
    /// 28 pt below its top when the area would sit under it.
    public static func toolbarFrame(size: CGSize, display: VisibleDisplay, area: CGRect?) -> (frame: CGRect, edge: HUDToolbarEdge) {
        let visible = display.visibleFrame
        let x = visible.midX - size.width / 2
        let bottom = CGRect(x: x, y: visible.maxY - toolbarEdgeInset - size.height, width: size.width, height: size.height)
        if let area, area.intersects(bottom) {
            let top = CGRect(x: x, y: visible.minY + toolbarEdgeInset, width: size.width, height: size.height)
            return (top, .top)
        }
        return (bottom, .bottom)
    }
}
