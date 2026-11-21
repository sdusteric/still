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

/// A key pressed while the HUD holds the overlay for the recording countdown (design 20.6).
public enum CountdownKey: Sendable, Hashable {
    /// Return: start recording now.
    case startNow
    /// Esc: cancel, nothing is written.
    case cancel
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
        /// Recordings at the display's scale (Retina) or at 1x, for the HUD's "Too small to
        /// record" check (design 20.6).
        public var recordsAtRetina: Bool

        public init(
            instantCapture: Bool = true,
            showMagnifier: Bool = false,
            showCrosshair: Bool = true,
            showKeyHints: Bool = true,
            includeWindowShadow: Bool = true,
            recordsAtRetina: Bool = true
        ) {
            self.instantCapture = instantCapture
            self.showMagnifier = showMagnifier
            self.showCrosshair = showCrosshair
            self.showKeyHints = showKeyHints
            self.includeWindowShadow = includeWindowShadow
            self.recordsAtRetina = recordsAtRetina
        }

        public init(settings: SnapCore.Settings) {
            self.init(settings: settings.capture)
            recordsAtRetina = settings.recording.scale == .retina
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
    /// Called once per capture with the result, after the panels are ordered out (for a HUD
    /// Record result, while they stay up for the countdown).
    public var onFinish: ((OverlaySelection) -> Void)?
    /// The HUD's Options menu rows for a mode (the app reads its settings and input devices).
    public var hudOptionItems: (HUDMode) -> [AllInOneOptionItem] = { _ in [] }
    /// A row of the HUD's Options menu was chosen.
    public var onHUDOption: ((AllInOneOption) -> Void)?
    /// Return or Esc during the recording countdown.
    public var onCountdownKey: ((CountdownKey) -> Void)?
    /// A display's name for the HUD's Fullscreen label chip.
    public var displayName: (DisplayID) -> String? = { _ in nil }

    private let makeSurface: SurfaceFactory?
    private let cursor: any OverlayCursor
    private let pointerLocation: @MainActor () -> CGPoint?
    private let visibleDisplays: @MainActor ([DisplayInfo]) -> [VisibleDisplay]
    private let hitTester: WindowHitTester

    public private(set) var displays: [DisplayInfo] = []
    private var surfaces: [DisplayID: any OverlaySurface] = [:]
    public private(set) var states: [DisplayID: SelectionOverlayState] = [:]
    public private(set) var mode: CaptureMode = .area
    public private(set) var phase: OverlayPhase = .idle
    public private(set) var isPresented = false {
        didSet { if isPresented != oldValue { onKeyGrabChanged?(isPresented) } }
    }
    /// True when the overlay comes up and false when it goes: the app grabs `grabbedKeys` as global
    /// hotkeys meanwhile. macOS sends no keys to a non-activating panel of an app that is not
    /// active, so without the grab Esc, Return and Tab never reach the overlay.
    public var onKeyGrabChanged: ((Bool) -> Void)?
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

    // MARK: HUD state (design 20.5)

    /// The all-in-one HUD's mode, target and area while the overlay runs as the HUD; nil for the
    /// plain Cmd+Shift+4 overlay. Kept after the HUD closes, so the app can store mode and target.
    public private(set) var hud: AllInOneState?
    /// The toolbar's frame in global top-left points, on `toolbarDisplay`.
    public private(set) var toolbarFrame: CGRect?
    public private(set) var toolbarEdge: HUDToolbarEdge = .bottom
    public private(set) var toolbarDisplay: DisplayInfo?
    /// Shown in place of the size chip: "Too small to record", or what the app sets.
    public private(set) var hudNotice: String?
    /// After Record: what is being recorded, held under the dim for the countdown.
    public private(set) var recordTarget: CGRect?
    /// Seconds left in the countdown disc; nil before the first tick.
    public private(set) var countdownSeconds: Int?
    /// The last Options menu built, for tests.
    public private(set) var lastOptionsMenu: NSMenu?
    private var hudModeChanged: (@MainActor (HUDMode) -> Void)?
    private var toolbarPress = false
    private var previousArea: (rect: CGRect, display: DisplayInfo)?

    /// - Parameters:
    ///   - makeSurface: builds one display's panel; nil (tests, shot mode) means no panels at all.
    ///   - pointerLocation: the pointer in global top-left points when the overlay appears.
    ///   - visibleDisplays: each display's visible frame (no menu bar or Dock), for the HUD toolbar.
    public init(
        options: Options = Options(),
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        cursor: any OverlayCursor,
        pointerLocation: @escaping @MainActor () -> CGPoint? = { nil },
        visibleDisplays: @escaping @MainActor ([DisplayInfo]) -> [VisibleDisplay] = { $0.map { VisibleDisplay($0) } },
        makeSurface: SurfaceFactory? = nil
    ) {
        self.options = options
        self.cursor = cursor
        self.pointerLocation = pointerLocation
        self.visibleDisplays = visibleDisplays
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
        resetSession()

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

    /// Clears everything one capture leaves behind, before the next one is presented.
    private func resetSession() {
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
        hud = nil
        hudModeChanged = nil
        toolbarFrame = nil
        toolbarDisplay = nil
        hudNotice = nil
        recordTarget = nil
        countdownSeconds = nil
        toolbarPress = false
        previousArea = nil
        pointer = pointerLocation()
    }

    /// The all-in-one HUD (design 20.5, M16): the same pre-built panels, plus the toolbar, the
    /// restored area with its handles and size chip, and the target. Nothing animates. The
    /// cursor stays visible, since the toolbar and handles are clicked.
    public func presentHUD(
        _ state: AllInOneState, displays: [DisplayInfo], modeChanged: @escaping @MainActor (HUDMode) -> Void
    ) {
        if let waiting = continuation {
            continuation = nil
            waiting.resume(returning: .cancelled)
        }
        prepare(displays: displays)
        resetSession()
        hud = state
        hudModeChanged = modeChanged
        mode = Self.drawingMode(for: state.target)
        if let area = state.area,
           let display = CoordinateSpace.nearestDisplay(to: CGPoint(x: area.midX, y: area.midY), in: displays) {
            selection = area
            selectionDisplay = display
            phase = .adjusting
        }
        isPresented = true
        if mode == .window { updateHover() }
        layoutToolbar()
        rebuildStates()
        let keyDisplay = toolbarDisplay ?? displays.first
        for display in displays {
            guard let state = states[display.id] else { continue }
            surfaces[display.id]?.show(state, makeKey: display.id == keyDisplay?.id)
        }
    }

    /// True between a HUD Record confirm and `dismiss()`: the panels show the countdown.
    public var isHoldingForRecording: Bool { isPresented && recordTarget != nil }

    /// Shows `seconds` in the countdown disc over the record target (design 20.6, M22); nil
    /// shows the held target with no disc.
    public func showCountdown(_ seconds: Int?) {
        guard isHoldingForRecording else { return }
        countdownSeconds = seconds
        refreshAll()
    }

    /// Replaces the HUD's size chip with `text` ("Not enough disk space"); nil restores it.
    public func setHUDNotice(_ text: String?) {
        guard hud != nil else { return }
        hudNotice = text
        refreshAll()
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

    /// The keys the overlay and the HUD act on, as Carbon key codes and modifiers: Esc, Return and
    /// Enter, Tab, Space, the arrows alone and with Shift, Command and both, and 1, 2, 3 and R.
    public static let grabbedKeys: [KeyShortcut] = {
        let shift = KeyShortcut.Modifier.shift
        let command = KeyShortcut.Modifier.command
        var keys = [53, 36, 76, 48, 49, 18, 19, 20, 15].map { KeyShortcut(keyCode: UInt32($0), modifiers: 0) }
        for arrow: UInt32 in [123, 124, 125, 126] {
            for modifiers in [0, shift, command, shift | command] {
                keys.append(KeyShortcut(keyCode: arrow, modifiers: modifiers))
            }
        }
        return keys
    }()

    /// A grabbed key went down or up: handled like the panel's own key event.
    public func grabbedKey(at index: Int, pressed: Bool) {
        guard Self.grabbedKeys.indices.contains(index) else { return }
        let shortcut = Self.grabbedKeys[index]
        let key = OverlayKey(keyCode: UInt16(shortcut.keyCode))
        guard pressed else {
            handle(.keyUp(key))
            return
        }
        var modifiers: OverlayModifiers = []
        if shortcut.modifiers & KeyShortcut.Modifier.shift != 0 { modifiers.insert(.shift) }
        if shortcut.modifiers & KeyShortcut.Modifier.command != 0 { modifiers.insert(.command) }
        handle(.keyDown(key, modifiers: modifiers, isRepeat: false))
    }

    /// Maps one input event onto the selection. Points are global top-left.
    public func handle(_ event: OverlayInputEvent) {
        guard isPresented else { return }
        if hud != nil {
            handleHUD(event)
            return
        }
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
            // During a drag Space moves the rectangle; otherwise it switches to window mode
            // and highlights the window under the pointer, as Tab does (design 6.5).
            if isDrawing {
                spaceHeld = true
            } else if !isRepeat {
                toggleMode()
            }
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
        recordTarget = nil
        countdownSeconds = nil
        toolbarPress = false
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
            showsKeyHints: options.showKeyHints,
            hud: hudDrawing(for: display)
        )
    }

    private func hudDrawing(for display: DisplayInfo) -> HUDOverlayDrawing? {
        guard let hud else { return nil }
        let pointerDisplay = pointer.flatMap { CoordinateSpace.nearestDisplay(to: $0, in: displays) }
        var countdown: Int?
        if let target = recordTarget, let seconds = countdownSeconds,
           CoordinateSpace.nearestDisplay(to: CGPoint(x: target.midX, y: target.midY), in: displays)?.id == display.id {
            countdown = seconds
        }
        return HUDOverlayDrawing(
            mode: hud.mode,
            target: hud.target,
            toolbarOrigin: toolbarDisplay?.id == display.id ? toolbarFrame?.origin : nil,
            notice: hudNotice,
            highlightsDisplay: hud.target == .fullscreen && recordTarget == nil && pointerDisplay?.id == display.id,
            displayName: displayName(display.id),
            recordTarget: recordTarget,
            countdown: countdown
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

// MARK: HUD events (design 20.5)

extension OverlayController {
    /// The overlay drawing mode for a HUD target.
    static func drawingMode(for target: CaptureMode) -> CaptureMode { target }

    /// Virtual key codes of the HUD's letter and digit keys (`kVK_ANSI_1` to `3`, `kVK_ANSI_R`).
    static func hudKey(_ key: OverlayKey, modifiers: OverlayModifiers) -> HUDKey? {
        switch key {
        case .escape: return .escape
        case .tab: return .tab
        case .returnKey: return .returnKey
        case .arrow(let direction):
            let step = modifiers.contains(.shift) ? 10.0 : 1.0
            switch direction {
            case .left: return .arrow(dx: -step, dy: 0)
            case .right: return .arrow(dx: step, dy: 0)
            case .up: return .arrow(dx: 0, dy: -step)
            case .down: return .arrow(dx: 0, dy: step)
            }
        case .space: return nil
        case .other(let code):
            guard !modifiers.contains(.command) else { return nil }
            switch code {
            case 18: return .one
            case 19: return .two
            case 20: return .three
            case 15: return .r
            default: return nil
            }
        }
    }

    func handleHUD(_ event: OverlayInputEvent) {
        if recordTarget != nil {
            // The countdown only listens for Return and Esc; the panel stays key for them.
            if case .keyDown(let key, _, _) = event {
                if key == .returnKey { onCountdownKey?(.startNow) }
                if key == .escape { onCountdownKey?(.cancel) }
            }
            return
        }
        guard let hud else { return }
        switch event {
        case .mouseMoved(let point):
            pointer = point
            if hud.target == .window { updateHover() }
            refreshAll()
        case .mouseDown(let point, let clickCount, let modifiers):
            self.modifiers = modifiers
            pointer = point
            if let item = toolbarItem(at: point) {
                toolbarPress = true
                perform(item)
                return
            }
            if hud.target == .area {
                hudAreaMouseDown(at: point, clickCount: clickCount)
            } else {
                if hud.target == .window { updateHover() }
                refreshAll()
            }
        case .mouseDragged(let point, let modifiers):
            guard !toolbarPress else { return }
            self.modifiers = modifiers
            if hud.target == .area {
                mouseDragged(to: point)
            } else {
                pointer = point
                refreshAll()
            }
        case .mouseUp(let point, let modifiers):
            if toolbarPress {
                toolbarPress = false
                return
            }
            self.modifiers = modifiers
            pointer = point
            switch hud.target {
            case .area:
                hudAreaMouseUp(at: point)
            case .window:
                updateHover()
                if hoveredWindow != nil { confirmHUD() }
            case .fullscreen:
                confirmHUD()
            }
        case .rightMouseDown:
            finish(.cancelled)
        case .keyDown(let key, let modifiers, let isRepeat):
            self.modifiers = modifiers
            hudKeyDown(key, isRepeat: isRepeat)
        case .keyUp(let key):
            if key == .space { spaceHeld = false }
        case .modifiersChanged(let modifiers):
            self.modifiers = modifiers
            if case .drawing = interaction, let point = pointer { mouseDragged(to: point) }
        }
    }

    /// The toolbar control under a global point, if the toolbar is there.
    public func toolbarItem(at point: CGPoint) -> AllInOneToolbarItem? {
        guard let hud, let frame = toolbarFrame, frame.contains(point) else { return nil }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return AllInOneToolbarLayout.layout(for: hud.mode).hit(local)
    }

    /// What a toolbar click does.
    public func perform(_ item: AllInOneToolbarItem) {
        guard isPresented, hud != nil, recordTarget == nil else { return }
        switch item {
        case .close: finish(.cancelled)
        case .mode(let mode): setHUDMode(mode)
        case .target(let target): setHUDTarget(target)
        case .options: showOptionsMenu()
        case .primary: confirmHUD()
        }
    }

    /// Screenshot or Record (M16: no animation). Record hides the frozen layer; the coordinator
    /// learns of the switch so it can start the frozen captures Record mode skipped (D59).
    public func setHUDMode(_ newMode: HUDMode) {
        guard var state = hud, state.setMode(newMode) == .changed else { return }
        hud = state
        hudNotice = nil
        layoutToolbar()
        refreshAll()
        hudModeChanged?(newMode)
    }

    /// Area, Window or Fullscreen. The area is kept, so switching back shows it again.
    public func setHUDTarget(_ target: CaptureMode) {
        guard var state = hud, state.setTarget(target) == .changed else { return }
        hud = state
        hudNotice = nil
        interaction = .none
        mode = Self.drawingMode(for: target)
        phase = target == .area && selection != nil ? .adjusting : .idle
        updateHover()
        refreshAll()
    }

    private func hudKeyDown(_ key: OverlayKey, isRepeat: Bool) {
        if key == .space {
            spaceHeld = true
            return
        }
        guard let hudKey = Self.hudKey(key, modifiers: modifiers), let state = hud else { return }
        switch hudKey {
        case .one: setHUDTarget(.area)
        case .two: setHUDTarget(.window)
        case .three: setHUDTarget(.fullscreen)
        case .tab:
            guard !isRepeat, !isHUDDrawing else { return }
            setHUDTarget(state.target == .window ? .area : .window)
        case .r:
            guard !isRepeat else { return }
            setHUDMode(state.mode.toggled)
        case .returnKey: confirmHUD()
        case .escape: finish(.cancelled)
        case .arrow:
            guard state.target == .area, case .arrow(let direction) = key, let rect = selection,
                  let display = selectionDisplay else { return }
            let geometry = SelectionGeometry(display: display)
            let large = modifiers.contains(.shift)
            selection = modifiers.contains(.command)
                ? geometry.resized(rect, direction, large: large)
                : geometry.nudged(rect, direction, large: large)
            areaChanged()
        }
    }

    private var isHUDDrawing: Bool {
        if case .drawing = interaction { return true }
        return false
    }

    /// Instant capture does not apply in the HUD: a drag leaves an editable area; Return, a
    /// double-click inside or the primary button confirms (20.5).
    private func hudAreaMouseDown(at point: CGPoint, clickCount: Int) {
        if phase == .adjusting, let rect = selection {
            if clickCount >= 2, rect.contains(point) {
                confirmHUD()
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
        previousArea = selection.flatMap { rect in selectionDisplay.map { (rect, $0) } }
        let drag = SelectionDrag(start: point, geometry: SelectionGeometry(display: display), modifiers: modifiers.dragModifiers)
        interaction = .drawing(drag)
        selectionDisplay = display
        selection = drag.rect
        phase = .dragging
        refreshAll()
    }

    private func hudAreaMouseUp(at point: CGPoint) {
        switch interaction {
        case .drawing:
            mouseDragged(to: point)
            interaction = .none
            if let rect = selection, let display = selectionDisplay, SelectionGeometry(display: display).isClick(rect) {
                // A click outside the area keeps the area it had.
                selection = previousArea?.rect
                selectionDisplay = previousArea?.display
            }
            phase = selection == nil ? .idle : .adjusting
            previousArea = nil
            areaChanged()
        case .moving, .resizing:
            interaction = .none
            areaChanged()
        case .none:
            break
        }
    }

    private func areaChanged() {
        hud?.setArea(selection)
        hudNotice = nil
        layoutToolbar()
        refreshAll()
    }

    /// Places the toolbar on the display under the pointer (design 20.5): 28 pt above the visible
    /// frame's bottom, or below its top when the area would sit under it.
    func layoutToolbar() {
        guard let hud else { return }
        let display = toolbarDisplay
            ?? pointer.flatMap { CoordinateSpace.nearestDisplay(to: $0, in: displays) }
            ?? displays.first
        guard let display else { return }
        toolbarDisplay = display
        let visible = visibleDisplays(displays).first { $0.id == display.id } ?? VisibleDisplay(display)
        let size = AllInOneToolbarLayout.layout(for: hud.mode).size
        let area = selectionDisplay?.id == display.id ? selection : nil
        let placed = AllInOneState.toolbarFrame(size: size, display: visible, area: area)
        toolbarFrame = placed.frame
        toolbarEdge = placed.edge
    }

    /// Return, a double-click or the primary button. Screenshot mode finishes like Cmd+Shift+4;
    /// Record mode keeps the panels up for the countdown and hands back the target (20.6).
    public func confirmHUD() {
        guard isPresented, let hud, recordTarget == nil else { return }
        switch hud.target {
        case .area:
            guard let rect = selection, rect.width > 0, rect.height > 0, let display = selectionDisplay else { return }
            guard hud.mode == .record else {
                finish(.area(displayID: display.id, rect: rect))
                return
            }
            guard isRecordable(rect, on: display) else {
                hudNotice = "Too small to record"
                refreshAll()
                return
            }
            holdForRecording(.record(.area(rect)), target: rect)
        case .window:
            guard let window = hoveredWindow else { return }
            if hud.mode == .screenshot {
                finish(.window(window, includeShadow: options.includeWindowShadow != modifiers.contains(.option)))
            } else {
                holdForRecording(.record(.window(window)), target: window.frame)
            }
        case .fullscreen:
            let display = pointer.flatMap { CoordinateSpace.nearestDisplay(to: $0, in: displays) } ?? displays.first
            guard let display else { return }
            if hud.mode == .screenshot {
                finish(.fullscreen(displayID: display.id))
            } else {
                holdForRecording(.record(.fullscreen(displayID: display.id)), target: display.frameTopLeft)
            }
        }
    }

    /// At least 64 px on a side after rounding down to even pixels (design 20.6).
    func isRecordable(_ rect: CGRect, on display: DisplayInfo) -> Bool {
        let scale = options.recordsAtRetina ? display.scale : 1
        do {
            _ = try RecordingPlan.evenPixelSize(width: rect.width, height: rect.height, scale: scale)
            return true
        } catch {
            return false
        }
    }

    /// Resolves the selection with a Record result but keeps the panels: the toolbar, handles
    /// and chips go, the dim and the target's border stay for the countdown (M23 removes them).
    private func holdForRecording(_ result: OverlaySelection, target: CGRect) {
        recordTarget = target
        countdownSeconds = nil
        interaction = .none
        refreshAll()
        if let waiting = continuation {
            continuation = nil
            waiting.resume(returning: result)
        } else {
            pendingResult = result
        }
        onFinish?(result)
    }

    private func showOptionsMenu() {
        guard let hud, let frame = toolbarFrame, let display = toolbarDisplay,
              let slot = AllInOneToolbarLayout.layout(for: hud.mode).frame(of: .options) else { return }
        let menu = AllInOneOptions.makeMenu(hudOptionItems(hud.mode)) { [weak self] option in
            self?.onHUDOption?(option)
        }
        lastOptionsMenu = menu
        let local = CGPoint(
            x: frame.minX + slot.minX - display.frameTopLeft.minX,
            y: frame.minY + (toolbarEdge == .bottom ? slot.minY : slot.maxY) - display.frameTopLeft.minY
        )
        surfaces[display.id]?.popUpMenu(menu, at: local)
    }
}
