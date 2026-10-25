import AppKit
import Observation
import SnapCore

/// What opens a pin (design 20.2): the item's image, its size and where it was captured.
public struct PinRequest: Sendable {
    public var itemID: String
    /// The current image (the edited one when there is one), decoded once and kept for the pin's life.
    public var image: CGImage
    /// The image at 100%: its pixel size divided by its scale.
    public var pointSize: CGSize
    /// The capture's own screen rect from `item.json`, global top-left points.
    public var screenRect: CGRect?
    /// Window captures keep their alpha and captured shadow: no clip, no ring, no panel shadow.
    public var isWindowCapture: Bool
    /// The PNG in history, for Reveal in Finder. A pin outlives its file after the sweep.
    public var fileURL: URL?
    public var createdAt: Date
    public var origin: PinOrigin

    public init(
        itemID: String,
        image: CGImage,
        pointSize: CGSize,
        screenRect: CGRect? = nil,
        isWindowCapture: Bool = false,
        fileURL: URL? = nil,
        createdAt: Date = Date(),
        origin: PinOrigin = .menu
    ) {
        self.itemID = itemID
        self.image = image
        self.pointSize = pointSize
        self.screenRect = screenRect
        self.isWindowCapture = isWindowCapture
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.origin = origin
    }
}

/// Where a pin was opened from, which picks its entry motion (20.12 M17, M18).
public enum PinOrigin: Sendable, Hashable {
    /// The Pin chip on a card; the frame is the card thumbnail's, global top-left points.
    case card(thumbnailFrame: CGRect?)
    case menu
    case history
}

/// How a panel appears or leaves (20.12 M17 to M19). `PinController` decides; the panel animates.
public enum PinTransition: Sendable, Hashable {
    /// M17: the image grows from the card thumbnail's frame to the pin frame (spring 0.30 / 1.0).
    case grow(from: CGRect)
    /// M18 on open (fade in, scale .96 to 1, 160 ms), M19 on close (fade out, scale to .96, 120 ms).
    case fadeScale
    /// Reduce Motion: a 100 ms fade at the pin frame.
    case fade
}

/// What a pin's keys, menu and buttons do.
public enum PinCommand: Sendable, Hashable {
    case close
    case copy
    case save
    case annotate
    case showInQuickAccess
    case reveal
    case resetSize
    case toggleClickThrough
    case zoomIn
    case zoomOut
    case setOpacity(Double)
}

/// Keys on a pin that is key (design 20.2): Esc or Cmd+W close, Cmd+C copy, Cmd+S save, A annotate,
/// L click-through, 2 to 9 and 0 opacity, Cmd+= and Cmd+- zoom, Cmd+0 back to 100%.
public enum PinKey {
    /// `characters` is `charactersIgnoringModifiers`.
    public static func command(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> PinCommand? {
        if keyCode == 53 { return .close }
        let key = characters?.lowercased() ?? ""
        let others = modifiers.intersection([.control, .option])
        guard others.isEmpty else { return nil }
        if modifiers.contains(.command) {
            switch key {
            case "w": return .close
            case "c": return .copy
            case "s": return .save
            case "=", "+": return .zoomIn
            case "-": return .zoomOut
            case "0": return .resetSize
            default: return nil
            }
        }
        if key.count == 1, let character = key.first, let opacity = PinBoard.opacity(forKey: character) {
            return .setOpacity(opacity)
        }
        switch key {
        case "a": return .annotate
        case "l": return .toggleClickThrough
        default: return nil
        }
    }
}

/// One row of the More menu (design 20.2).
public struct PinMenuItem: Sendable, Hashable {
    public var title: String
    /// The key shown at the right, for example `⌘C`.
    public var keyEquivalent: String?
    public var command: PinCommand
    public var isEnabled: Bool
    /// A separator goes above this row.
    public var separatorBefore: Bool

    public init(title: String, keyEquivalent: String? = nil, command: PinCommand, isEnabled: Bool = true, separatorBefore: Bool = false) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.command = command
        self.isEnabled = isEnabled
        self.separatorBefore = separatorBefore
    }
}

/// The hover chrome's three widths (design 20.2): the full bar, the value as a scrub control under
/// 260 pt, and only Close and More under 120 pt.
public enum PinChromeLayout: Sendable, Hashable {
    case full, compact, minimal

    public init(width: Double) {
        if width < Theme.Pin.minimalChromeWidth {
            self = .minimal
        } else if width < Theme.Pin.compactChromeWidth {
            self = .compact
        } else {
            self = .full
        }
    }
}

/// One pin's view state. `PinController` changes it only from what `PinBoard` decided.
@Observable
public final class PinModel: Identifiable {
    public let id: Int
    public let itemID: String
    public let image: CGImage
    public let pointSize: CGSize
    /// Area and fullscreen captures: clipped to radius 8 with the ring and the card shadow.
    public let isOpaque: Bool
    public let fileURL: URL?
    public let createdAt: Date
    /// Global top-left points.
    public var frame: CGRect
    /// 0.2 to 1.
    public var opacity: Double
    public var clickThrough = false
    public var isHovered = false
    /// `460 × 268 · 100%` while a resize or zoom is showing the size chip, else nil.
    public var sizeChipText: String?

    public init(
        id: Int,
        itemID: String,
        image: CGImage,
        pointSize: CGSize,
        isOpaque: Bool,
        frame: CGRect,
        opacity: Double = 1,
        fileURL: URL? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.image = image
        self.pointSize = pointSize
        self.isOpaque = isOpaque
        self.frame = frame
        self.opacity = opacity
        self.fileURL = fileURL
        self.createdAt = createdAt
    }

    public var chromeLayout: PinChromeLayout { PinChromeLayout(width: frame.width) }
    public var opacityText: String { "\(Int((opacity * 100).rounded()))%" }
    /// The hover chrome shows only on an unlocked pin under the pointer.
    public var showsChrome: Bool { isHovered && !clickThrough }
}

/// What the app does for a pin command. Supplied by the app wiring, so this UI does not depend on
/// the pasteboard, the save folder or the editors.
public struct PinActions {
    /// Copies the pin's image; true on success.
    public var copy: @MainActor (PinModel) -> Bool
    public var save: @MainActor (PinModel) -> Void
    public var annotate: @MainActor (String) -> Void
    public var showInQuickAccess: @MainActor (String) -> Void
    public var reveal: @MainActor (URL) -> Void
    /// A pin closed; its item may now be swept.
    public var closed: @MainActor (String) -> Void

    public init(
        copy: @escaping @MainActor (PinModel) -> Bool = { _ in false },
        save: @escaping @MainActor (PinModel) -> Void = { _ in },
        annotate: @escaping @MainActor (String) -> Void = { _ in },
        showInQuickAccess: @escaping @MainActor (String) -> Void = { _ in },
        reveal: @escaping @MainActor (URL) -> Void = { _ in },
        closed: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.copy = copy
        self.save = save
        self.annotate = annotate
        self.showInQuickAccess = showInQuickAccess
        self.reveal = reveal
        self.closed = closed
    }
}

/// One pin's window. The live one is `PinPanel`; tests use a recording factory and shot mode none.
/// Frames are global top-left points, as `PinBoard` keeps them.
@MainActor
public protocol PinSurface: AnyObject {
    func present(frame: CGRect, transition: PinTransition)
    func setFrame(_ frame: CGRect)
    /// `ignoresMouseEvents` on or off (design D50).
    func setClickThrough(_ on: Bool)
    func dismiss(transition: PinTransition)
}

/// The pins on screen (design 20.2): owns the `PinBoard`, one model and one panel per pin, and
/// the size chip timer. It draws nothing `PinBoard` did not decide. Panels come from an injected
/// factory, so tests and shot mode never create one.
@Observable
public final class PinController {
    public typealias SurfaceFactory = @MainActor (PinController, PinModel) -> (any PinSurface)?

    /// The size chip stays this long after the last zoom step, then leaves without a fade (M21).
    public static let sizeChipHoldSeconds = 1.0

    /// Oldest first, as the board orders them.
    public private(set) var pins: [PinModel] = []

    @ObservationIgnored public var actions: PinActions
    @ObservationIgnored public private(set) var board: PinBoard
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let displays: @MainActor () -> [VisibleDisplay]
    @ObservationIgnored private let pointer: @MainActor () -> CGPoint
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private let fileExists: @MainActor (URL) -> Bool
    @ObservationIgnored private let makeSurface: SurfaceFactory?
    @ObservationIgnored private var surfaces: [Int: any PinSurface] = [:]
    @ObservationIgnored private var chipHideAt: [Int: TimeInterval] = [:]
    @ObservationIgnored private var resizing: Set<Int> = []
    @ObservationIgnored private var moveStart: [Int: CGPoint] = [:]
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// - Parameters:
    ///   - displays: current displays, global top-left points, the main display first.
    ///   - pointer: the pointer, global top-left points.
    ///   - makeSurface: builds one panel per pin; nil (tests, shot mode) means no panel.
    public init(
        clock: any Clock,
        actions: PinActions = PinActions(),
        displays: @escaping @MainActor () -> [VisibleDisplay],
        pointer: @escaping @MainActor () -> CGPoint = { .zero },
        reduceMotion: @escaping @MainActor () -> Bool = { false },
        fileExists: @escaping @MainActor (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) },
        makeSurface: SurfaceFactory? = nil
    ) {
        self.clock = clock
        self.actions = actions
        self.displays = displays
        self.pointer = pointer
        self.reduceMotion = reduceMotion
        self.fileExists = fileExists
        self.makeSurface = makeSurface
        self.board = PinBoard(displays: displays())
    }

    public func pin(_ id: Int) -> PinModel? { pins.first { $0.id == id } }

    /// Item ids that are pinned, for the history sweep's in-use set (design D54).
    public var pinnedItemIDs: Set<String> { board.pinnedItemIDs }

    /// The menu's "Pinned Captures" rows, newest first.
    public var menuEntries: [PinMenuEntry] { board.menuEntries }

    // MARK: Opening and closing

    /// Opens a pin and returns its id. A ninth pin closes the oldest (design D51).
    @discardableResult
    public func open(_ request: PinRequest) -> Int {
        board.displaysChanged(displays())
        let result = board.add(
            itemID: request.itemID, pointSize: request.pointSize, screenRect: request.screenRect,
            pointer: pointer(), createdAt: request.createdAt
        )
        if let oldest = result.closed { removePin(oldest.id) }
        let model = PinModel(
            id: result.pin.id, itemID: request.itemID, image: request.image, pointSize: request.pointSize,
            isOpaque: !request.isWindowCapture, frame: result.pin.frame, opacity: result.pin.opacity,
            fileURL: request.fileURL, createdAt: request.createdAt
        )
        pins.append(model)
        if let makeSurface, let surface = makeSurface(self, model) {
            surfaces[model.id] = surface
            surface.present(frame: model.frame, transition: entryTransition(for: request.origin))
        }
        return model.id
    }

    /// The entry motion: M17 from a card, M18 from the menu or history, a fade under Reduce Motion.
    public func entryTransition(for origin: PinOrigin) -> PinTransition {
        if reduceMotion() { return .fade }
        if case .card(let frame?) = origin { return .grow(from: frame) }
        return .fadeScale
    }

    public var exitTransition: PinTransition { reduceMotion() ? .fade : .fadeScale }

    public func close(_ id: Int) {
        guard board.close(id) != nil else { return }
        removePin(id)
    }

    public func closeAll() {
        for pin in board.closeAll() { removePin(pin.id) }
    }

    private func removePin(_ id: Int) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        let model = pins.remove(at: index)
        surfaces.removeValue(forKey: id)?.dismiss(transition: exitTransition)
        chipHideAt[id] = nil
        resizing.remove(id)
        moveStart[id] = nil
        actions.closed(model.itemID)
    }

    // MARK: Moving, resizing, zooming (1:1, no easing, M21)

    public func moveBegan(_ id: Int) {
        guard let model = pin(id) else { return }
        moveStart[id] = model.frame.origin
    }

    /// The drag's translation since `moveBegan`, top-left points.
    public func moveChanged(_ id: Int, translation: CGSize) {
        guard let start = moveStart[id] ?? pin(id)?.frame.origin else { return }
        board.move(id, to: CGPoint(x: start.x + translation.width, y: start.y + translation.height))
        sync(id)
    }

    public func moveEnded(_ id: Int) {
        moveStart[id] = nil
    }

    /// A resize drag began: the size chip shows until it ends.
    public func resizeBegan(_ id: Int) {
        resizing.insert(id)
        chipHideAt[id] = nil
        showSizeChip(id)
    }

    /// Resizes from `handle` toward `point` (top-left points), aspect locked by the board.
    public func resize(_ id: Int, handle: PinResizeHandle, to point: CGPoint) {
        board.resize(id, handle: handle, to: point)
        sync(id)
        showSizeChip(id)
    }

    /// The panel's live resize produced `frame`; the board turns it into an aspect-locked frame
    /// anchored at the edges that did not move, and the panel follows when it differs.
    public func panelResized(_ id: Int, to frame: CGRect) {
        guard let current = pin(id)?.frame, current != frame else { return }
        guard let (handle, point) = Self.resizeDrag(from: current, to: frame) else { return }
        resize(id, handle: handle, to: point)
    }

    public func resizeEnded(_ id: Int) {
        resizing.remove(id)
        pin(id)?.sizeChipText = nil
    }

    /// Which edge or corner moved between two frames, and where it went.
    static func resizeDrag(from old: CGRect, to new: CGRect) -> (PinResizeHandle, CGPoint)? {
        let epsilon = 0.5
        let left = abs(new.minX - old.minX) > epsilon
        let right = abs(new.maxX - old.maxX) > epsilon
        let top = abs(new.minY - old.minY) > epsilon
        let bottom = abs(new.maxY - old.maxY) > epsilon
        let horizontal: Bool? = left ? true : (right ? false : nil)
        let vertical: Bool? = top ? true : (bottom ? false : nil)
        let x = left ? new.minX : new.maxX
        let y = top ? new.minY : new.maxY
        switch (horizontal, vertical) {
        case (true?, true?): return (.topLeft, CGPoint(x: x, y: y))
        case (true?, false?): return (.bottomLeft, CGPoint(x: x, y: y))
        case (false?, true?): return (.topRight, CGPoint(x: x, y: y))
        case (false?, false?): return (.bottomRight, CGPoint(x: x, y: y))
        case (true?, nil): return (.left, CGPoint(x: x, y: new.midY))
        case (false?, nil): return (.right, CGPoint(x: x, y: new.midY))
        case (nil, true?): return (.top, CGPoint(x: new.midX, y: y))
        case (nil, false?): return (.bottom, CGPoint(x: new.midX, y: y))
        case (nil, nil): return nil
        }
    }

    /// Pinch or Cmd+= and Cmd+-: 10% steps around `point`, or around the pointer when it is over
    /// the pin, else the center.
    public func zoom(_ id: Int, by steps: Int, around point: CGPoint? = nil) {
        guard let model = pin(id) else { return }
        let pointer = pointer()
        let anchor = point ?? (model.frame.contains(pointer) ? pointer : CGPoint(x: model.frame.midX, y: model.frame.midY))
        board.zoom(id, by: steps, around: anchor)
        sync(id)
        flashSizeChip(id)
    }

    /// Cmd+0 and Reset Size: back to 100% around the center.
    public func resetSize(_ id: Int) {
        board.setZoom(id, 1)
        sync(id)
        flashSizeChip(id)
    }

    // MARK: Opacity and click-through

    public func setOpacity(_ id: Int, _ value: Double) {
        board.setOpacity(id, value)
        syncState(id)
    }

    /// Scroll wheel and the compact scrub control: steps of 5%.
    public func stepOpacity(_ id: Int, by steps: Int) {
        board.stepOpacity(id, by: steps)
        syncState(id)
    }

    public func setClickThrough(_ id: Int, _ on: Bool) {
        board.setClickThrough(id, on)
        syncState(id)
    }

    public func toggleClickThrough(_ id: Int) {
        board.toggleClickThrough(id)
        syncState(id)
    }

    /// The menu's Unlock item.
    public func unlock(_ id: Int) { setClickThrough(id, false) }

    public func setHovered(_ id: Int, _ hovered: Bool) {
        guard let model = pin(id) else { return }
        let value = hovered && !model.clickThrough
        if model.isHovered != value { model.isHovered = value }
    }

    // MARK: Displays

    /// A display was added, removed or rearranged: pins on a lost display move to the main one.
    public func displaysChanged() {
        for moved in board.displaysChanged(displays()) { sync(moved.id) }
    }

    // MARK: Commands

    public func perform(_ command: PinCommand, on id: Int) {
        guard let model = pin(id) else { return }
        switch command {
        case .close: close(id)
        case .copy: _ = actions.copy(model)
        case .save: actions.save(model)
        case .annotate: actions.annotate(model.itemID)
        case .showInQuickAccess: actions.showInQuickAccess(model.itemID)
        case .reveal:
            if let url = model.fileURL, fileExists(url) { actions.reveal(url) }
        case .resetSize: resetSize(id)
        case .toggleClickThrough: toggleClickThrough(id)
        case .zoomIn: zoom(id, by: 1)
        case .zoomOut: zoom(id, by: -1)
        case .setOpacity(let value): setOpacity(id, value)
        }
    }

    /// A key on a pin that is key; true when it was a pin key.
    @discardableResult
    public func handleKey(_ id: Int, characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let command = PinKey.command(characters: characters, keyCode: keyCode, modifiers: modifiers) else { return false }
        perform(command, on: id)
        return true
    }

    /// The More menu (design 20.2). Reveal is disabled once the sweep removed the file.
    public func moreMenu(for id: Int) -> [PinMenuItem] {
        guard let model = pin(id) else { return [] }
        let revealable = model.fileURL.map(fileExists) ?? false
        return [
            PinMenuItem(title: "Copy", keyEquivalent: "\u{2318}C", command: .copy),
            PinMenuItem(title: "Save", keyEquivalent: "\u{2318}S", command: .save),
            PinMenuItem(title: "Open in Annotate", keyEquivalent: "A", command: .annotate),
            PinMenuItem(title: "Show in Quick Access", command: .showInQuickAccess, separatorBefore: true),
            PinMenuItem(title: "Reveal in Finder", command: .reveal, isEnabled: revealable),
            PinMenuItem(title: "Reset Size", keyEquivalent: "\u{2318}0", command: .resetSize, separatorBefore: true),
            PinMenuItem(title: "Close", keyEquivalent: "\u{238B}", command: .close),
        ]
    }

    // MARK: Size chip

    private func showSizeChip(_ id: Int) {
        guard let model = pin(id), let pin = board.pin(id) else { return }
        model.sizeChipText = PinBoard.sizeChipText(pin)
    }

    private func flashSizeChip(_ id: Int) {
        showSizeChip(id)
        guard !resizing.contains(id) else { return }
        chipHideAt[id] = clock.now() + Self.sizeChipHoldSeconds
        processTimers()
    }

    /// Hides size chips whose hold has passed, then schedules the next wake-up.
    public func processTimers() {
        let now = clock.now()
        for (id, until) in chipHideAt where until <= now {
            chipHideAt[id] = nil
            pin(id)?.sizeChipText = nil
        }
        timerTask?.cancel()
        timerTask = nil
        guard let next = chipHideAt.values.min() else { return }
        let clock = clock
        let delay = max(next - now, 0.001)
        timerTask = Task { [weak self] in
            do {
                try await clock.sleep(seconds: delay)
            } catch {
                return
            }
            self?.processTimers()
        }
    }

    // MARK: Board to model and panel

    private func sync(_ id: Int) {
        guard let pin = board.pin(id), let model = self.pin(id) else { return }
        if model.frame != pin.frame {
            model.frame = pin.frame
            surfaces[id]?.setFrame(pin.frame)
        }
        if model.sizeChipText != nil { model.sizeChipText = PinBoard.sizeChipText(pin) }
    }

    private func syncState(_ id: Int) {
        guard let pin = board.pin(id), let model = self.pin(id) else { return }
        if model.opacity != pin.opacity { model.opacity = pin.opacity }
        if model.clickThrough != pin.clickThrough {
            model.clickThrough = pin.clickThrough
            if pin.clickThrough { model.isHovered = false }
            surfaces[id]?.setClickThrough(pin.clickThrough)
        }
    }
}
