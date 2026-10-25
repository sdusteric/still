import CoreGraphics
import Foundation

/// A display as pins and the HUD toolbar see it: its frame and its `visibleFrame` (without the
/// menu bar and Dock), both in global top-left points, the space `screenRect` in `item.json` uses.
/// By convention the first display in a list is the main display.
public struct VisibleDisplay: Sendable, Hashable, Codable, Identifiable {
    public var id: DisplayID
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(id: DisplayID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// A display whose visible frame is the whole frame, for fakes and tests.
    public init(_ display: DisplayInfo, menuBarHeight: Double = 0, dockHeight: Double = 0) {
        let frame = display.frameTopLeft
        let visible = CGRect(
            x: frame.minX, y: frame.minY + menuBarHeight,
            width: frame.width, height: max(frame.height - menuBarHeight - dockHeight, 0)
        )
        self.init(id: display.id, frame: frame, visibleFrame: visible)
    }
}

/// One pinned capture (design 20.2). `frame` is in global top-left points.
public struct Pin: Sendable, Hashable, Identifiable {
    public let id: Int
    public var itemID: String
    /// The image at 100%: its pixel size divided by its scale.
    public var pointSize: CGSize
    public var frame: CGRect
    /// 0.2 to 1 in 0.05 steps.
    public var opacity: Double
    public var clickThrough: Bool
    public var createdAt: Date
    /// The display the pin is on, for relocation when a display disappears.
    public var displayID: DisplayID?

    /// Current size as a fraction of `pointSize` (1 is 100%).
    public var zoom: Double { pointSize.width > 0 ? frame.width / pointSize.width : 1 }
    public var zoomPercent: Int { Int((zoom * 100).rounded()) }
    public var opacityPercent: Int { Int((opacity * 100).rounded()) }
}

/// Where a pin's resize drag is anchored: the dragged edge or corner.
public enum PinResizeHandle: Sendable, Hashable, CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
}

/// A row of the menu bar's "Pinned Captures" submenu.
public struct PinMenuEntry: Sendable, Hashable, Identifiable {
    public var id: Int
    public var itemID: String
    public var createdAt: Date
    public var clickThrough: Bool
}

/// The pins on screen and every decision about them (design 20.2): placement, the cap of 8, move,
/// aspect-locked resize, zoom around a point, opacity steps, click-through and relocation when a
/// display disappears. Pure: displays are injected. `PinController` in SnapUI draws what this decides.
public struct PinBoard: Sendable, Hashable {
    public static let capacity = 8
    public static let minimumZoom = 0.1
    public static let maximumZoom = 4.0
    public static let zoomStep = 0.1
    static let zoomStepsPerUnit = 10.0
    /// No pin is smaller than this on its short side, unless the image itself is (design 20.2).
    public static let minimumShortSide: Double = 48
    /// The fallback placement fits the image into this fraction of the pointer display's visible frame.
    public static let fallbackFitFraction = 0.6
    public static let minimumOpacity = 0.2
    public static let opacityStep = 0.05
    static let opacityStepsPerUnit = 20.0

    public private(set) var pins: [Pin] = []
    public private(set) var displays: [VisibleDisplay]
    private var nextID = 1

    public init(displays: [VisibleDisplay]) {
        self.displays = displays
    }

    public var isEmpty: Bool { pins.isEmpty }
    public var count: Int { pins.count }

    public func pin(_ id: Int) -> Pin? { pins.first { $0.id == id } }

    /// The submenu rows, newest first.
    public var menuEntries: [PinMenuEntry] {
        pins.reversed().map {
            PinMenuEntry(id: $0.id, itemID: $0.itemID, createdAt: $0.createdAt, clickThrough: $0.clickThrough)
        }
    }

    /// Item ids that are pinned, for the history sweep's in-use set.
    public var pinnedItemIDs: Set<String> { Set(pins.map(\.itemID)) }

    // MARK: Adding and closing

    public struct AddResult: Sendable, Hashable {
        public var pin: Pin
        /// The oldest pin, closed because the board was full.
        public var closed: Pin?
    }

    /// Adds a pin for an image of `pointSize` points. A ninth pin closes the oldest.
    /// - Parameters:
    ///   - screenRect: the capture's own screen rect, when `item.json` has one.
    ///   - pointer: the pointer location, global top-left points.
    @discardableResult
    public mutating func add(
        itemID: String, pointSize: CGSize, screenRect: CGRect?, pointer: CGPoint, createdAt: Date = Date()
    ) -> AddResult {
        let frame = PinBoard.placement(pointSize: pointSize, screenRect: screenRect, pointer: pointer, displays: displays)
        let pin = Pin(
            id: nextID, itemID: itemID, pointSize: pointSize, frame: frame, opacity: 1,
            clickThrough: false, createdAt: createdAt, displayID: display(containing: frame)?.id
        )
        nextID += 1
        var closed: Pin?
        if pins.count >= PinBoard.capacity {
            closed = pins.removeFirst()
        }
        pins.append(pin)
        return AddResult(pin: pin, closed: closed)
    }

    @discardableResult
    public mutating func close(_ id: Int) -> Pin? {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return nil }
        return pins.remove(at: index)
    }

    @discardableResult
    public mutating func closeAll() -> [Pin] {
        defer { pins.removeAll() }
        return pins
    }

    // MARK: Placement

    /// Design D47: at the capture's own rect at 100% when that rect lies fully inside one display's
    /// visible frame; otherwise centered on the pointer's display, scaled down to fit 60% of its
    /// visible frame. Always clamped inside the visible frame.
    public static func placement(
        pointSize: CGSize, screenRect: CGRect?, pointer: CGPoint, displays: [VisibleDisplay]
    ) -> CGRect {
        if let rect = screenRect, rect.width > 0, rect.height > 0,
           let display = displays.first(where: { $0.visibleFrame.contains(rect) }) {
            let frame = CGRect(
                x: rect.midX - pointSize.width / 2, y: rect.midY - pointSize.height / 2,
                width: pointSize.width, height: pointSize.height
            )
            return clamp(frame, in: display.visibleFrame)
        }
        guard let display = pointerDisplay(pointer, displays: displays) else {
            return CGRect(origin: .zero, size: pointSize)
        }
        let visible = display.visibleFrame
        let fit = min(
            1,
            visible.width * fallbackFitFraction / max(pointSize.width, 1),
            visible.height * fallbackFitFraction / max(pointSize.height, 1)
        )
        let size = CGSize(width: pointSize.width * fit, height: pointSize.height * fit)
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        return clamp(frame, in: visible)
    }

    /// The display under the pointer, else the main (first) one.
    public static func pointerDisplay(_ pointer: CGPoint, displays: [VisibleDisplay]) -> VisibleDisplay? {
        displays.first { $0.frame.contains(pointer) } ?? displays.first
    }

    /// Shrinks `frame` (aspect kept) when it is larger than `bounds`, then moves it inside.
    public static func clamp(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var size = frame.size
        if size.width > bounds.width || size.height > bounds.height, size.width > 0, size.height > 0 {
            let factor = min(bounds.width / size.width, bounds.height / size.height)
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - size.width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Moving, resizing, zooming

    /// Moves a pin to `origin` (1:1 with the drag), clamped to the display its center is on.
    @discardableResult
    public mutating func move(_ id: Int, to origin: CGPoint) -> Pin? {
        update(id) { pin, board in
            let moved = CGRect(origin: origin, size: pin.frame.size)
            let display = board.display(containing: moved) ?? board.nearestDisplay(to: moved)
            pin.frame = display.map { PinBoard.clamp(moved, in: $0.visibleFrame) } ?? moved
            pin.displayID = display?.id ?? pin.displayID
        }
    }

    /// Resizes from `handle` toward `point` with the aspect locked; the opposite edge or corner
    /// stays put. Edges drive their own axis, corners the larger change.
    @discardableResult
    public mutating func resize(_ id: Int, handle: PinResizeHandle, to point: CGPoint) -> Pin? {
        update(id) { pin, board in
            let frame = pin.frame
            let aspect = pin.pointSize.height > 0 ? pin.pointSize.width / pin.pointSize.height : 1
            let proposedWidth: Double
            let proposedHeight: Double
            switch handle {
            case .left, .topLeft, .bottomLeft: proposedWidth = frame.maxX - point.x
            case .right, .topRight, .bottomRight: proposedWidth = point.x - frame.minX
            case .top, .bottom: proposedWidth = frame.width
            }
            switch handle {
            case .top, .topLeft, .topRight: proposedHeight = frame.maxY - point.y
            case .bottom, .bottomLeft, .bottomRight: proposedHeight = point.y - frame.minY
            case .left, .right: proposedHeight = frame.height
            }
            var width: Double
            switch handle {
            case .left, .right: width = proposedWidth
            case .top, .bottom: width = proposedHeight * aspect
            default: width = max(proposedWidth, proposedHeight * aspect)
            }
            width = board.clampedWidth(width, for: pin)
            let height = width / aspect
            var origin = frame.origin
            switch handle {
            case .left, .topLeft, .bottomLeft: origin.x = frame.maxX - width
            case .right, .topRight, .bottomRight: origin.x = frame.minX
            case .top, .bottom: origin.x = frame.midX - width / 2
            }
            switch handle {
            case .top, .topLeft, .topRight: origin.y = frame.maxY - height
            case .bottom, .bottomLeft, .bottomRight: origin.y = frame.minY
            case .left, .right: origin.y = frame.midY - height / 2
            }
            board.place(&pin, CGRect(x: origin.x, y: origin.y, width: width, height: height))
        }
    }

    /// Zooms by `steps` of 10% (positive grows) around `point`, which stays over the same image pixel.
    @discardableResult
    public mutating func zoom(_ id: Int, by steps: Int, around point: CGPoint) -> Pin? {
        guard let current = pin(id) else { return nil }
        let level = (current.zoom * PinBoard.zoomStepsPerUnit).rounded() + Double(steps)
        return setZoom(id, level / PinBoard.zoomStepsPerUnit, around: point)
    }

    /// Sets the zoom (1 is 100%) around `point`, or around the pin's center when nil (Cmd+0).
    @discardableResult
    public mutating func setZoom(_ id: Int, _ zoom: Double, around point: CGPoint? = nil) -> Pin? {
        update(id) { pin, board in
            let frame = pin.frame
            let anchor = point ?? CGPoint(x: frame.midX, y: frame.midY)
            let width = board.clampedWidth(zoom * pin.pointSize.width, for: pin)
            let factor = frame.width > 0 ? width / frame.width : 1
            let origin = CGPoint(
                x: anchor.x - (anchor.x - frame.minX) * factor,
                y: anchor.y - (anchor.y - frame.minY) * factor
            )
            board.place(&pin, CGRect(origin: origin, size: CGSize(width: width, height: frame.height * factor)))
        }
    }

    /// The lowest zoom for an image: 10%, raised so the short side stays at least 48 pt, but never
    /// above 100%.
    public static func minimumZoom(for pointSize: CGSize) -> Double {
        let shortSide = min(pointSize.width, pointSize.height)
        guard shortSide > 0 else { return minimumZoom }
        return min(1, max(minimumZoom, minimumShortSide / shortSide))
    }

    // MARK: Opacity and click-through

    /// Sets the opacity, rounded to 5% steps and kept in 20% to 100%.
    @discardableResult
    public mutating func setOpacity(_ id: Int, _ value: Double) -> Pin? {
        update(id) { pin, _ in pin.opacity = PinBoard.normalizedOpacity(value) }
    }

    /// Scroll wheel and slider steps: `steps` of 5%.
    @discardableResult
    public mutating func stepOpacity(_ id: Int, by steps: Int) -> Pin? {
        guard let current = pin(id) else { return nil }
        return setOpacity(id, (current.opacity * PinBoard.opacityStepsPerUnit + Double(steps)) / PinBoard.opacityStepsPerUnit)
    }

    public static func normalizedOpacity(_ value: Double) -> Double {
        // Whole steps divided once, so 0.95 is exactly 19 / 20.
        let stepped = (value * opacityStepsPerUnit).rounded() / opacityStepsPerUnit
        return min(max(stepped, minimumOpacity), 1)
    }

    /// Keys on a focused pin: 2 to 9 set 20% to 90%, 0 sets 100%. Other keys are not opacity keys.
    public static func opacity(forKey key: Character) -> Double? {
        switch key {
        case "0": 1
        case "2"..."9": key.wholeNumberValue.map { Double($0) / 10 }
        default: nil
        }
    }

    @discardableResult
    public mutating func setClickThrough(_ id: Int, _ on: Bool) -> Pin? {
        update(id) { pin, _ in pin.clickThrough = on }
    }

    @discardableResult
    public mutating func toggleClickThrough(_ id: Int) -> Pin? {
        update(id) { pin, _ in pin.clickThrough.toggle() }
    }

    // MARK: Displays

    /// New display layout. Pins whose display is gone move to the center of the main display,
    /// clamped; the rest are clamped to their display. Returns the pins that moved.
    @discardableResult
    public mutating func displaysChanged(_ newDisplays: [VisibleDisplay]) -> [Pin] {
        displays = newDisplays
        guard let main = newDisplays.first else { return [] }
        var moved: [Pin] = []
        for index in pins.indices {
            var pin = pins[index]
            let before = pin.frame
            if let current = newDisplays.first(where: { $0.id == pin.displayID }) {
                pin.frame = PinBoard.clamp(pin.frame, in: current.visibleFrame)
            } else {
                let visible = main.visibleFrame
                let centered = CGRect(
                    x: visible.midX - before.width / 2, y: visible.midY - before.height / 2,
                    width: before.width, height: before.height
                )
                pin.frame = PinBoard.clamp(centered, in: visible)
                pin.displayID = main.id
            }
            pins[index] = pin
            if pin.frame != before { moved.append(pin) }
        }
        return moved
    }

    // MARK: Chip

    /// The size chip during a resize or zoom: `460 × 268 · 100%`.
    public static func sizeChipText(_ pin: Pin) -> String {
        let width = Int(pin.frame.width.rounded())
        let height = Int(pin.frame.height.rounded())
        return "\(width) \u{00D7} \(height) \u{00B7} \(pin.zoomPercent)%"
    }

    // MARK: Helpers

    private mutating func update(_ id: Int, _ body: (inout Pin, PinBoard) -> Void) -> Pin? {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return nil }
        var pin = pins[index]
        body(&pin, self)
        pins[index] = pin
        return pin
    }

    /// Keeps a width within the zoom limits, the 48 pt floor and the pin's display.
    private func clampedWidth(_ width: Double, for pin: Pin) -> Double {
        let base = pin.pointSize.width
        guard base > 0 else { return width }
        var maximum = PinBoard.maximumZoom * base
        if let display = displays.first(where: { $0.id == pin.displayID }) ?? display(containing: pin.frame) {
            let aspect = pin.pointSize.height > 0 ? base / pin.pointSize.height : 1
            maximum = min(maximum, display.visibleFrame.width, display.visibleFrame.height * aspect)
        }
        let minimum = min(PinBoard.minimumZoom(for: pin.pointSize) * base, maximum)
        return min(max(width, minimum), maximum)
    }

    private func place(_ pin: inout Pin, _ frame: CGRect) {
        let display = displays.first(where: { $0.id == pin.displayID }) ?? self.display(containing: frame)
        pin.frame = display.map { PinBoard.clamp(frame, in: $0.visibleFrame) } ?? frame
    }

    private func display(containing frame: CGRect) -> VisibleDisplay? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.first { $0.frame.contains(center) }
    }

    private func nearestDisplay(to frame: CGRect) -> VisibleDisplay? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { distance(center, $0.frame) < distance(center, $1.frame) }
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
