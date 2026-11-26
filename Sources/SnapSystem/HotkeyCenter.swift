import Carbon
import Foundation
import SnapCore

/// One key press of a registered hotkey.
public struct HotkeyPress: Sendable, Hashable {
    public var action: ShortcutAction
    /// Carbon event time: seconds since boot, the base of `ProcessInfo.systemUptime`.
    public var eventTime: TimeInterval
    /// `systemUptime` when the handler ran.
    public var receivedUptime: TimeInterval

    public init(action: ShortcutAction, eventTime: TimeInterval, receivedUptime: TimeInterval) {
        self.action = action
        self.eventTime = eventTime
        self.receivedUptime = receivedUptime
    }

    /// The event time on `clock`, for `CaptureCoordinator.begin(eventTime:)`: now, minus the time
    /// the event spent in the queue before the handler ran.
    public func time(on clock: any SnapCore.Clock) -> TimeInterval {
        clock.now() - max(0, receivedUptime - eventTime)
    }
}

/// Global hotkeys through Carbon `RegisterEventHotKey` on the application event target (design
/// 12.3). Needs no Accessibility or Input Monitoring permission. Never used by tests or tools.
@MainActor
public final class HotkeyCenter {
    /// The outcome of registering one combo, shown next to the shortcut in settings.
    public struct Registration: Sendable, Hashable {
        public var action: ShortcutAction
        public var combo: HotkeyCombo
        public var status: OSStatus

        public var isRegistered: Bool { status == noErr }

        /// Nil on success, else the text for settings (never an alert).
        public var message: String? {
            isRegistered ? nil : HotkeyCenter.describe(status)
        }
    }

    /// "SNAP" as a four-character code, so events of other handlers are ignored.
    nonisolated static let signature: OSType = 0x534E_4150
    /// "SNPK": the overlay's grabbed keys (`grab`), told apart from the shortcuts.
    nonisolated static let grabSignature: OSType = 0x534E_504B

    private let box: HotkeyHandlerBox
    private var handlerRef: EventHandlerRef?
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var grabRefs: [EventHotKeyRef] = []
    private var onGrabbedKey: (@MainActor (Int, Bool) -> Void)?
    public private(set) var registrations: [ShortcutAction: Registration] = [:]

    /// - Parameter onPress: runs on the main actor for every press of a registered combo.
    public init(onPress: @escaping @MainActor (HotkeyPress) -> Void) {
        let grabbed = GrabbedKeyRelay()
        box = HotkeyHandlerBox { signature, id, pressed, eventTime in
            if signature == HotkeyCenter.grabSignature {
                grabbed.forward?(Int(id), pressed)
                return
            }
            let actions = ShortcutAction.allCases
            guard pressed, Int(id) < actions.count else { return }
            onPress(HotkeyPress(
                action: actions[Int(id)], eventTime: eventTime, receivedUptime: ProcessInfo.processInfo.systemUptime
            ))
        }
        relay = grabbed
    }

    private let relay: GrabbedKeyRelay

    isolated deinit {
        releaseGrab()
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Takes `keys` (key code and Carbon modifiers) as global hotkeys until `releaseGrab()`, so
    /// the capture overlay gets Esc, Return and the rest while another app is active: macOS does
    /// not send keys to a non-activating panel of an app that is not active. `onKey` gets the
    /// index in `keys` and whether the key went down (true) or up. Returns how many registered.
    @discardableResult
    public func grab(_ keys: [KeyShortcut], onKey: @escaping @MainActor (Int, Bool) -> Void) -> Int {
        releaseGrab()
        guard installHandlerIfNeeded() == noErr else { return 0 }
        relay.forward = onKey
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                key.keyCode, key.modifiers, EventHotKeyID(signature: HotkeyCenter.grabSignature, id: UInt32(index)),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref { grabRefs.append(ref) }
        }
        return grabRefs.count
    }

    public func releaseGrab() {
        for ref in grabRefs { UnregisterEventHotKey(ref) }
        grabRefs.removeAll()
        relay.forward = nil
    }

    /// Registers what `plan.register` lists, replacing earlier registrations. Deferred combos (CleanShot
    /// running) stay unregistered until the plan is applied again.
    @discardableResult
    public func apply(_ plan: HotkeyPlan) -> [Registration] {
        register(plan.register)
    }

    /// Unregisters everything, then registers `combos`, reporting the OSStatus of each.
    @discardableResult
    public func register(_ combos: [ShortcutAction: HotkeyCombo]) -> [Registration] {
        unregisterAll()
        let handlerStatus = installHandlerIfNeeded()
        var results: [Registration] = []
        for action in ShortcutAction.allCases {
            guard let combo = combos[action] else { continue }
            var status = handlerStatus
            if status == noErr {
                let index = UInt32(ShortcutAction.allCases.firstIndex(of: action) ?? 0)
                var ref: EventHotKeyRef?
                status = RegisterEventHotKey(
                    combo.keyCode, combo.modifiers, EventHotKeyID(signature: HotkeyCenter.signature, id: index),
                    GetApplicationEventTarget(), 0, &ref
                )
                if status == noErr, let ref { refs[action] = ref }
            }
            let registration = Registration(action: action, combo: combo, status: status)
            registrations[action] = registration
            results.append(registration)
        }
        return results
    }

    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        registrations.removeAll()
    }

    /// A short text for an OSStatus from `RegisterEventHotKey`.
    public nonisolated static func describe(_ status: OSStatus) -> String {
        switch Int(status) {
        case Int(noErr): "Registered"
        case eventHotKeyExistsErr: "Another app already registered this shortcut (\(status))."
        case eventHotKeyInvalidErr: "macOS rejected this shortcut (\(status))."
        default: "Could not register this shortcut (OSStatus \(status))."
        }
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        return InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEventHandler, eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(box).toOpaque(), &handlerRef
        )
    }
}

/// The one documented `@unchecked Sendable` boundary: Carbon hands this box to a C callback as an
/// opaque pointer. The callback runs on the main thread, which is the only place `handler` is called.
/// The handler gets the hotkey's signature, its id, whether it went down, and the event time.
final class HotkeyHandlerBox: @unchecked Sendable {
    let handler: @MainActor (OSType, UInt32, Bool, TimeInterval) -> Void

    init(handler: @escaping @MainActor (OSType, UInt32, Bool, TimeInterval) -> Void) {
        self.handler = handler
    }
}

/// Where grabbed keys go while a grab is on. Only touched on the main actor.
@MainActor
final class GrabbedKeyRelay {
    var forward: (@MainActor (Int, Bool) -> Void)?
}

private func hotkeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    let signature = hotKeyID.signature
    guard status == noErr, signature == HotkeyCenter.signature || signature == HotkeyCenter.grabSignature else {
        return OSStatus(eventNotHandledErr)
    }
    let eventTime = GetEventTime(event)
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let box = Unmanaged<HotkeyHandlerBox>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated { box.handler(signature, id, pressed, eventTime) }
    return noErr
}
