import AppKit
import SnapCore

/// Modifier keys the overlay cares about.
public struct OverlayModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = OverlayModifiers(rawValue: 1 << 0)
    public static let option = OverlayModifiers(rawValue: 1 << 1)
    public static let command = OverlayModifiers(rawValue: 1 << 2)

    public init(_ flags: NSEvent.ModifierFlags) {
        var value: OverlayModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }

    /// Shift squares the selection, Option resizes from the centre.
    var dragModifiers: DragModifiers {
        var value: DragModifiers = []
        if contains(.shift) { value.insert(.square) }
        if contains(.option) { value.insert(.fromCenter) }
        return value
    }
}

/// Keys the overlay handles, by virtual key code.
public enum OverlayKey: Sendable, Hashable {
    case escape, tab, space, returnKey
    case arrow(ArrowDirection)
    case other(UInt16)

    public init(keyCode: UInt16) {
        switch keyCode {
        case 53: self = .escape
        case 48: self = .tab
        case 49: self = .space
        case 36, 76: self = .returnKey
        case 123: self = .arrow(.left)
        case 124: self = .arrow(.right)
        case 125: self = .arrow(.down)
        case 126: self = .arrow(.up)
        default: self = .other(keyCode)
        }
    }
}

/// One input event in global top-left points, as `SelectionOverlayView` reports it.
public enum OverlayInputEvent: Sendable, Hashable {
    case mouseMoved(CGPoint)
    case mouseDown(CGPoint, clickCount: Int, modifiers: OverlayModifiers)
    case mouseDragged(CGPoint, modifiers: OverlayModifiers)
    case mouseUp(CGPoint, modifiers: OverlayModifiers)
    case rightMouseDown
    case keyDown(OverlayKey, modifiers: OverlayModifiers, isRepeat: Bool)
    case keyUp(OverlayKey)
    case modifiersChanged(OverlayModifiers)
}

@MainActor
public protocol OverlayEventSink: AnyObject {
    func overlayEvent(_ event: OverlayInputEvent)
}

/// Hides and shows the system cursor. Injected so tests never touch the real cursor.
@MainActor
public protocol OverlayCursor: AnyObject {
    func hide()
    func unhide()
}

/// `NSCursor.hide()` and `unhide()`, which must stay balanced; the controller guarantees that.
public final class SystemOverlayCursor: OverlayCursor {
    public init() {}
    public func hide() { NSCursor.hide() }
    public func unhide() { NSCursor.unhide() }
}

/// The selection overlay (design 6.2, 7): pre-built panels, one per display, ordered front on the
/// hotkey, mouse and keys mapped onto `SelectionGeometry` and `WindowHitTester`. Panels come from
/// an injected factory and are made only in `prepare` or `present`, so tests drive the controller
/// with fake surfaces (or none) and never create a window.
public final class OverlayController: OverlayPresenter, OverlayEventSink {
    /// The capture settings the overlay reads (design 12.2).
    public struct Options: Sendable, Hashable {
        public var instantCapture: Bool
        public var showMagnifier: Bool
        public var showCrosshair: Bool
        public var showKeyHints: Bool
        public var includeWindowShadow: Bool

        public init(
            instantCapture: Bool = true,
            showMagnifier: Bool = true,
            showCrosshair: Bool = true,
            showKeyHints: Bool = true,
            includeWindowShadow: Bool = true
        ) {
            self.instantCapture = instantCapture
            self.showMagnifier = showMagnifier
            self.showCrosshair = showCrosshair
            self.showKeyHints = showKeyHints
            self.includeWindowShadow = includeWindowShadow
        }

        public init(settings: CaptureSettings) {
            self.init(
                instantCapture: settings.instantCapture,
                showMagnifier: settings.showMagnifier,
                showCrosshair: settings.showCrosshair,
                showKeyHints: settings.showKeyHints,
                includeWindowShadow: settings.includeWindowShadow
            )
        }
    }

    public typealias SurfaceFactory = @MainActor (DisplayInfo, [DisplayInfo], any OverlayEventSink) -> (any OverlaySurface)?

    private enum Interaction {
        case none
        case drawing(SelectionDrag)
        case moving(last: CGPoint)
        case resizing(SelectionHandle)
    }

    public var options: Options
    /// Called once per capture with the result, after the panels are ordered out.
    public var onFinish: ((OverlaySelection) -> Void)?

    private let makeSurface: SurfaceFactory?
    private let cursor: any OverlayCursor
    private let pointerLocation: @MainActor () -> CGPoint?
    private let hitTester: WindowHitTester

    public private(set) var displays: [DisplayInfo] = []
    private var surfaces: [DisplayID: any OverlaySurface] = [:]
    public private(set) var states: [DisplayID: SelectionOverlayState] = [:]
    public private(set) var mode: CaptureMode = .area
    public private(set) var phase: OverlayPhase = .idle
    public private(set) var isPresented = false
    public private(set) var isCursorHidden = false
    public private(set) var hoveredWindow: WindowInfo?
    /// The current selection in global top-left points and the display it is on.
    public private(set) var selection: CGRect?
    public private(set) var selectionDisplay: DisplayInfo?
    private var pointer: CGPoint?
    private var windows: [WindowInfo] = []
    private var frozen: [DisplayID: CGImage] = [:]
    private var interaction: Interaction = .none
    private var modifiers: OverlayModifiers = []
    private var spaceHeld = false
    private var pendingResult: OverlaySelection?
    private var continuation: CheckedContinuation<OverlaySelection, Never>?

    /// - Parameters:
    ///   - makeSurface: builds one display's panel; nil (tests, shot mode) means no panels at all.
    ///   - pointerLocation: the pointer in global top-left points when the overlay appears.
    public init(
        options: Options = Options(),
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        cursor: any OverlayCursor,
        pointerLocation: @escaping @MainActor () -> CGPoint? = { nil },
        makeSurface: SurfaceFactory? = nil
    ) {
        self.options = options
        self.cursor = cursor
        self.pointerLocation = pointerLocation
        self.makeSurface = makeSurface
        self.hitTester = WindowHitTester(ownPID: ownPID)
    }

    /// The overlay windows, so display captures can exclude them.
    public var surfaceWindowIDs: [WindowID] {
        displays.compactMap { surfaces[$0.id]?.windowID }
    }

    // MARK: Panels

    /// Builds the panels for `displays` ahead of the hotkey (launch and screen changes).
    public func prepare(displays: [DisplayInfo]) {
        guard displays != self.displays || surfaces.count != displays.count else { return }
        for surface in surfaces.values { surface.hide() }
        surfaces = [:]
        self.displays = displays
        guard let makeSurface else { return }
        for display in displays {
            if let surface = makeSurface(display, displays, self) { surfaces[display.id] = surface }
        }
    }

    /// Screen parameters changed: the overlay closes (cursor restored) and panels are rebuilt.
    public func screenParametersChanged(displays: [DisplayInfo]) {
        if isPresented { finish(.cancelled) }
        self.displays = []
        prepare(displays: displays)
    }

    // MARK: OverlayPresenter

    public func present(mode: CaptureMode, displays: [DisplayInfo]) {
        if let waiting = continuation {
            continuation = nil
            waiting.resume(returning: .cancelled)
        }
        prepare(displays: displays)
        pendingResult = nil
        interaction = .none
        modifiers = []
        spaceHeld = false
        selection = nil
        selectionDisplay = nil
        hoveredWindow = nil
        windows = []
        frozen = [:]
        phase = .idle
        pointer = pointerLocation()

        if mode == .fullscreen {
            // Fullscreen has no overlay: the display under the pointer is the selection (design 6.4).
            let target = pointer.flatMap { CoordinateSpace.nearestDisplay(to: $0, in: displays) } ?? displays.first
            self.mode = .area
            if let target {
                pendingResult = .area(displayID: target.id, rect: target.frameTopLeft)
            } else {
                pendingResult = .cancelled
            }
            return
        }

        self.mode = mode
        isPresented = true
        hideCursor()
        rebuildStates()
        let keyDisplay = pointer.flatMap { CoordinateSpace.nearestDisplay(to: $0, in: displays) } ?? displays.first
        for display in displays {
            guard let state = states[display.id] else { continue }
            surfaces[display.id]?.show(state, makeKey: display.id == keyDisplay?.id)
        }
    }

    public func showFrozen(_ image: CapturedImage, displayID: DisplayID) {
        frozen[displayID] = image.cgImage
        guard isPresented else { return }
        refresh(displayID)
    }

    public func updateWindows(_ windows: [WindowInfo]) {
        self.windows = windows
        guard isPresented else { return }
        updateHover()
        refreshAll()
    }

    public func selection() async -> OverlaySelection {
        if let result = pendingResult {
            pendingResult = nil
            return result
        }
        return await withCheckedContinuation { continuation in
            if let result = pendingResult {
                pendingResult = nil
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    public func dismiss() {
        endSession()
        if let waiting = continuation {
            continuation = nil
            waiting.resume(returning: .cancelled)
        }
    }

    // MARK: Events

    public func overlayEvent(_ event: OverlayInputEvent) {
        handle(event)
    }

    /// Maps one input event onto the selection. Points are global top-left.
    public func handle(_ event: OverlayInputEvent) {
        guard isPresented else { return }
        switch event {
        case .mouseMoved(let point):
            pointerMoved(to: point)
        case .mouseDown(let point, let clickCount, let modifiers):
            self.modifiers = modifiers
            mouseDown(at: point, clickCount: clickCount)
        case .mouseDragged(let point, let modifiers):
            self.modifiers = modifiers
            mouseDragged(to: point)
        case .mouseUp(let point, let modifiers):
            self.modifiers = modifiers
            mouseUp(at: point)
        case .rightMouseDown:
            finish(.cancelled)
        case .keyDown(let key, let modifiers, let isRepeat):
            self.modifiers = modifiers
            keyDown(key, isRepeat: isRepeat)
        case .keyUp(let key):
            if key == .space { spaceHeld = false }
        case .modifiersChanged(let modifiers):
            self.modifiers = modifiers
            if case .drawing = interaction, let point = pointer { mouseDragged(to: point) }
        }
    }

    private func pointerMoved(to point: CGPoint) {
        pointer = point
        if mode == .window { updateHover() }
        refreshAll()
    }

    private func mouseDown(at point: CGPoint, clickCount: Int) {
        pointer = point
        if mode == .window {
            updateHover()
            refreshAll()
            return
        }
        if phase == .adjusting, let rect = selection {
            if clickCount >= 2, rect.contains(point) {
                finish(.area(displayID: selectionDisplay?.id ?? 0, rect: rect))
                return
            }
            if let handle = SelectionHandle.hit(point, rect: rect) {
                interaction = .resizing(handle)
                return
            }
            if rect.contains(point) {
                interaction = .moving(last: point)
                return
            }
        }
        guard let display = CoordinateSpace.nearestDisplay(to: point, in: displays) else { return }
        let drag = SelectionDrag(start: point, geometry: SelectionGeometry(display: display), modifiers: modifiers.dragModifiers)
        interaction = .drawing(drag)
        selectionDisplay = display
        selection = drag.rect
        phase = .dragging
        refreshAll()
    }

    private func mouseDragged(to point: CGPoint) {
        pointer = point
        switch interaction {
        case .none:
            refreshAll()
        case .drawing(var drag):
            selection = drag.update(pointer: point, modifiers: modifiers.dragModifiers, moving: spaceHeld)
            interaction = .drawing(drag)
            refreshAll()
        case .moving(let last):
            guard let rect = selection, let display = selectionDisplay else { return }
            let move = SelectionGeometry(display: display).moved(rect, from: last, to: point)
            selection = move.rect
            interaction = .moving(last: move.last)
            refreshAll()
        case .resizing(let handle):
            guard let rect = selection, let display = selectionDisplay else { return }
            selection = Self.resize(rect, handle: handle, to: point, geometry: SelectionGeometry(display: display))
            refreshAll()
        }
    }

    private func mouseUp(at point: CGPoint) {
        if mode == .window {
            pointer = point
            updateHover()
            if let window = hoveredWindow {
                finish(.window(window, includeShadow: options.includeWindowShadow != modifiers.contains(.option)))
            }
            return
        }
        switch interaction {
        case .drawing:
            mouseDragged(to: point)
            interaction = .none
            guard let rect = selection, let display = selectionDisplay else { return }
            if SelectionGeometry(display: display).isClick(rect) {
                // A click with no drag captures the window under the pointer, else cancels (D10).
                if let window = hitTester.window(at: point, in: windows) {
                    finish(.window(window, includeShadow: options.includeWindowShadow))
                } else {
                    finish(.cancelled)
                }
            } else if options.instantCapture {
                finish(.area(displayID: display.id, rect: rect))
            } else {
                phase = .adjusting
                refreshAll()
            }
        case .moving, .resizing:
            interaction = .none
            refreshAll()
        case .none:
            break
        }
    }

    private func keyDown(_ key: OverlayKey, isRepeat: Bool) {
        switch key {
        case .escape:
            finish(.cancelled)
        case .tab:
            guard !isRepeat, !isDrawing else { return }
            toggleMode()
        case .space:
            spaceHeld = true
        case .returnKey:
            if phase == .adjusting, let rect = selection, let display = selectionDisplay {
                finish(.area(displayID: display.id, rect: rect))
            }
        case .arrow(let direction):
            guard phase == .adjusting, let rect = selection, let display = selectionDisplay else { return }
            let geometry = SelectionGeometry(display: display)
            let large = modifiers.contains(.shift)
            selection = modifiers.contains(.command)
                ? geometry.resized(rect, direction, large: large)
                : geometry.nudged(rect, direction, large: large)
            refreshAll()
        case .other:
            break
        }
    }

    private var isDrawing: Bool {
        if case .drawing = interaction { return true }
        return false
    }

    private func toggleMode() {
        mode = mode == .window ? .area : .window
        phase = .idle
        interaction = .none
        selection = nil
        selectionDisplay = nil
        updateHover()
        refreshAll()
    }

    private func updateHover() {
        guard mode == .window, let pointer else {
            hoveredWindow = nil
            return
        }
        hoveredWindow = hitTester.window(at: pointer, in: windows)
    }

    /// Drags one of the 8 handles: corners move two edges, sides move one. The opposite edges stay.
    static func resize(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint, geometry: SelectionGeometry) -> CGRect {
        let target = geometry.snap(geometry.clamp(point))
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .topLeft: minX = target.x; minY = target.y
        case .top: minY = target.y
        case .topRight: maxX = target.x; minY = target.y
        case .right: maxX = target.x
        case .bottomRight: maxX = target.x; maxY = target.y
        case .bottom: maxY = target.y
        case .bottomLeft: minX = target.x; maxY = target.y
        case .left: minX = target.x
        }
        return geometry.snap(SelectionGeometry.normalize(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)))
    }

    // MARK: Finishing

    /// Every exit path (confirm, click, cancel, error, screen change) comes through here, so the
    /// panels always leave and the cursor always comes back.
    private func finish(_ result: OverlaySelection) {
        guard isPresented else { return }
        endSession()
        if let waiting = continuation {
            continuation = nil
            waiting.resume(returning: result)
        } else {
            pendingResult = result
        }
        onFinish?(result)
    }

    private func endSession() {
        isPresented = false
        interaction = .none
        for surface in surfaces.values { surface.hide() }
        showCursor()
    }

    private func hideCursor() {
        guard !isCursorHidden else { return }
        isCursorHidden = true
        cursor.hide()
    }

    private func showCursor() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        cursor.unhide()
    }

    // MARK: State

    private func rebuildStates() {
        states = [:]
        for display in displays { states[display.id] = makeState(for: display) }
    }

    private func makeState(for display: DisplayInfo) -> SelectionOverlayState {
        let onThisDisplay: Bool
        if let selectionDisplay, phase != .idle, mode == .area {
            onThisDisplay = selectionDisplay.id == display.id
        } else if let pointer {
            onThisDisplay = CoordinateSpace.nearestDisplay(to: pointer, in: displays)?.id == display.id
        } else {
            onThisDisplay = false
        }
        var shownPointer = onThisDisplay ? pointer : nil
        if case .drawing(let drag) = interaction, onThisDisplay { shownPointer = drag.pointer }
        let windowHere = hoveredWindow.flatMap { window in
            display.frameTopLeft.intersects(window.frame) ? window : nil
        }
        return SelectionOverlayState(
            display: display,
            frozenImage: frozen[display.id],
            mode: mode,
            phase: phase,
            pointer: shownPointer,
            selection: selectionDisplay?.id == display.id ? selection : nil,
            hoveredWindow: windowHere,
            showsMagnifier: options.showMagnifier,
            showsCrosshair: options.showCrosshair,
            showsKeyHints: options.showKeyHints
        )
    }

    private func refresh(_ displayID: DisplayID) {
        guard let display = displays.first(where: { $0.id == displayID }) else { return }
        let state = makeState(for: display)
        guard states[displayID] != state else { return }
        states[displayID] = state
        surfaces[displayID]?.update(state)
    }

    private func refreshAll() {
        for display in displays { refresh(display.id) }
    }
}
