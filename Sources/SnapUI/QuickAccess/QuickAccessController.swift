import AppKit
import Observation
import SnapCore
import SwiftUI

/// One capture handed to the Quick Access stack.
public struct QuickAccessItem: Sendable {
    public var id: String
    public var thumbnail: CGImage
    /// Size in points, shown in the dimension pill.
    public var pointSize: CGSize
    /// The clipboard already holds it, so the card shows "Copied" for 2 s.
    public var copied: Bool
    public var savedURL: URL?

    public init(id: String, thumbnail: CGImage, pointSize: CGSize, copied: Bool = true, savedURL: URL? = nil) {
        self.id = id
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        self.copied = copied
        self.savedURL = savedURL
    }
}

/// A new thumbnail after Background was applied or removed.
public struct QuickAccessThumbnail: Sendable {
    public var image: CGImage
    public var pointSize: CGSize
    public var backgroundApplied: Bool

    public init(image: CGImage, pointSize: CGSize, backgroundApplied: Bool) {
        self.image = image
        self.pointSize = pointSize
        self.backgroundApplied = backgroundApplied
    }
}

/// What a card button or key does.
public enum QuickAccessCardAction: Sendable, Hashable, CaseIterable {
    case copy, save, background, backgroundEditor, annotate, reveal, close
}

/// What the app does for each card action. Supplied by the app wiring, so this UI does not depend
/// on the pasteboard, the renderer or the editors.
public struct QuickAccessActions {
    /// Copies the item's current PNG; true on success.
    public var copy: @MainActor (String) async -> Bool
    /// Saves to the save folder; the saved file on success.
    public var save: @MainActor (String) async -> URL?
    /// Applies the default preset, or removes it when applied.
    public var toggleBackground: @MainActor (String) async -> QuickAccessThumbnail?
    public var openBackgroundEditor: @MainActor (String) -> Void
    public var annotate: @MainActor (String) -> Void
    public var reveal: @MainActor (URL) -> Void
    /// The item's current PNG in `SNAP_HOME/history/<id>/`, for drag-out.
    public var dragURL: @MainActor (String) -> URL?
    /// A card left the stack.
    public var closed: @MainActor (String, QuickAccessStack.CloseReason) -> Void

    public init(
        copy: @escaping @MainActor (String) async -> Bool = { _ in false },
        save: @escaping @MainActor (String) async -> URL? = { _ in nil },
        toggleBackground: @escaping @MainActor (String) async -> QuickAccessThumbnail? = { _ in nil },
        openBackgroundEditor: @escaping @MainActor (String) -> Void = { _ in },
        annotate: @escaping @MainActor (String) -> Void = { _ in },
        reveal: @escaping @MainActor (URL) -> Void = { _ in },
        dragURL: @escaping @MainActor (String) -> URL? = { _ in nil },
        closed: @escaping @MainActor (String, QuickAccessStack.CloseReason) -> Void = { _, _ in }
    ) {
        self.copy = copy
        self.save = save
        self.toggleBackground = toggleBackground
        self.openBackgroundEditor = openBackgroundEditor
        self.annotate = annotate
        self.reveal = reveal
        self.dragURL = dragURL
        self.closed = closed
    }
}

/// Keys on a hovered card (design 8): C, S, A, B, Delete or Esc.
public enum QuickAccessKey: Sendable, Hashable {
    case copy, save, annotate, background, close

    public init?(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifiers.intersection(blocking).isEmpty else { return nil }
        switch keyCode {
        case 51, 117, 53:
            self = .close
            return
        default:
            break
        }
        switch characters?.lowercased() {
        case "c": self = .copy
        case "s": self = .save
        case "a": self = .annotate
        case "b": self = .background
        default: return nil
        }
    }

    public var action: QuickAccessCardAction {
        switch self {
        case .copy: .copy
        case .save: .save
        case .annotate: .annotate
        case .background: .background
        case .close: .close
        }
    }
}

/// Swipe dismiss (17.7 M7): 1:1 toward the anchored edge, rubber band away from it, dismiss past
/// 80 pt or faster than 400 pt/s toward the edge.
public struct SwipeDismissRule: Sendable, Hashable {
    /// -1 when the stack is on the left, +1 on the right.
    public let edgeSign: Double

    public init(corner: QuickAccessCorner) {
        edgeSign = corner == .bottomLeft || corner == .topLeft ? -1 : 1
    }

    public func displayOffset(for translation: Double) -> Double {
        translation * edgeSign >= 0 ? translation : translation * Theme.QuickAccess.rubberBand
    }

    public func shouldDismiss(translation: Double, velocity: Double) -> Bool {
        translation * edgeSign > Theme.QuickAccess.swipeDismissDistance
            || velocity * edgeSign > Theme.QuickAccess.swipeDismissVelocity
    }
}

/// Card and panel geometry (design 8, 17.4).
public enum QuickAccessLayout {
    /// Room around the stack inside the panel for the card shadow.
    public static let shadowMargin = 40.0

    public static func thumbnailWidth(_ size: QuickAccessSize) -> Double { size.thumbnailWidth }

    /// The 220 pt maximum is Medium's; Small and Large scale it with the width.
    public static func maxThumbnailHeight(_ size: QuickAccessSize) -> Double {
        Theme.QuickAccess.thumbnailMaxHeight * size.thumbnailWidth / QuickAccessSize.medium.thumbnailWidth
    }

    /// Aspect-fit height of the thumbnail box, between 96 pt and the maximum.
    public static func thumbnailHeight(pointSize: CGSize, size: QuickAccessSize) -> Double {
        let width = size.thumbnailWidth
        guard pointSize.width > 0, pointSize.height > 0 else { return Theme.QuickAccess.thumbnailMinHeight }
        let fitted = width * pointSize.height / pointSize.width
        return min(max(fitted, Theme.QuickAccess.thumbnailMinHeight), maxThumbnailHeight(size)).rounded()
    }

    public static func cardWidth(_ size: QuickAccessSize) -> Double {
        size.thumbnailWidth + 2 * Theme.QuickAccess.cardPadding
    }

    public static func cardHeight(pointSize: CGSize, size: QuickAccessSize) -> Double {
        thumbnailHeight(pointSize: pointSize, size: size) + 2 * Theme.QuickAccess.cardPadding
    }

    /// The panel frame in `NSScreen` coordinates: a column 16 pt inside `visibleFrame` at the corner,
    /// as tall as 70% of it, with the shadow margin around.
    public static func panelFrame(visibleFrame: CGRect, corner: QuickAccessCorner, size: QuickAccessSize) -> CGRect {
        let inset = Theme.QuickAccess.edgeInset
        let width = cardWidth(size) + 2 * shadowMargin
        let height = visibleFrame.height * Theme.QuickAccess.maxStackHeightFraction + 2 * shadowMargin
        let left = corner == .bottomLeft || corner == .topLeft
        let bottom = corner == .bottomLeft || corner == .bottomRight
        let x = left ? visibleFrame.minX + inset - shadowMargin : visibleFrame.maxX - inset - cardWidth(size) - shadowMargin
        let y = bottom ? visibleFrame.minY + inset - shadowMargin : visibleFrame.maxY - inset + shadowMargin - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The stack never grows past 70% of `visibleFrame` height.
    public static func maxStackHeight(visibleFrame: CGRect) -> Double {
        visibleFrame.height * Theme.QuickAccess.maxStackHeightFraction
    }
}

/// What the Quick Access panel needs. The live one is `QuickAccessPanel`; tests use none.
@MainActor
public protocol QuickAccessSurface: AnyObject {
    /// The window number while the panel is on screen, so display captures can exclude it.
    /// Nil while it is ordered out.
    var windowID: WindowID? { get }
    func show(frame: CGRect)
    func hide()
    /// The panel may be key only while the pointer is over a card (design 8).
    func setAcceptsKeys(_ accepts: Bool)
}

/// The Quick Access Overlay (design 8): owns the `QuickAccessStack`, the card models and their
/// timers, and one lazily made, non-activating panel. Time comes from the injected clock; the app
/// passes `SystemClock`, tests drive `FakeClock` and call `processTimers()`.
@Observable
public final class QuickAccessController {
    public typealias SurfaceFactory = @MainActor (QuickAccessController) -> (any QuickAccessSurface)?

    /// Newest first, as the stack orders them.
    public private(set) var cards: [QuickAccessCardModel] = []
    public private(set) var settings: QuickAccessSettings

    @ObservationIgnored public var actions: QuickAccessActions
    @ObservationIgnored public private(set) var stack: QuickAccessStack
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let makeSurface: SurfaceFactory?
    @ObservationIgnored private var surface: (any QuickAccessSurface)?
    @ObservationIgnored private let visibleFrame: @MainActor () -> CGRect?
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var copiedUntil: [String: TimeInterval] = [:]
    @ObservationIgnored private var confirmedUntil: [String: TimeInterval] = [:]
    @ObservationIgnored private var hidePanelAt: TimeInterval?
    @ObservationIgnored public private(set) var isPanelVisible = false

    /// - Parameters:
    ///   - visibleFrame: `visibleFrame` of the screen under the pointer, `NSScreen` coordinates.
    ///   - makeSurface: builds the panel on the first card; nil (tests, shot mode) means no panel.
    public init(
        clock: any Clock,
        settings: QuickAccessSettings = QuickAccessSettings(),
        actions: QuickAccessActions = QuickAccessActions(),
        visibleFrame: @escaping @MainActor () -> CGRect? = { nil },
        reduceMotion: @escaping @MainActor () -> Bool = { false },
        makeSurface: SurfaceFactory? = nil
    ) {
        self.clock = clock
        self.settings = settings
        self.actions = actions
        self.visibleFrame = visibleFrame
        self.reduceMotion = reduceMotion
        self.makeSurface = makeSurface
        self.stack = QuickAccessStack(clock: clock, configuration: QuickAccessStack.Configuration(settings: settings))
    }

    public func card(_ id: String) -> QuickAccessCardModel? { cards.first { $0.id == id } }

    /// The panel's window while it is on screen, for the capture to exclude (design 6.2 step 3):
    /// a card left from an earlier capture must not end up in the next frozen image.
    public var surfaceWindowIDs: [WindowID] {
        guard isPanelVisible, let id = surface?.windowID else { return [] }
        return [id]
    }

    public var swipeRule: SwipeDismissRule { SwipeDismissRule(corner: settings.corner) }

    // MARK: Settings

    public func apply(settings: QuickAccessSettings) {
        self.settings = settings
        let limit = visibleFrame().map(QuickAccessLayout.maxStackHeight(visibleFrame:))
        stack.apply(QuickAccessStack.Configuration(settings: settings, maxStackHeight: limit))
        for card in cards {
            card.size = settings.size
            card.corner = settings.corner
        }
        processTimers()
    }

    // MARK: Showing

    /// Shows a card for a new capture at the corner of the screen under the pointer. Called before
    /// encoding and history writes (design 6.6).
    public func show(_ item: QuickAccessItem) {
        let frame = visibleFrame()
        stack.configuration.maxStackHeight = frame.map(QuickAccessLayout.maxStackHeight(visibleFrame:))
        let height = QuickAccessLayout.cardHeight(pointSize: item.pointSize, size: settings.size)
        let closed = stack.push(id: item.id, height: height)
        cards.removeAll { $0.id == item.id }
        removeModels(for: closed)

        let model = QuickAccessCardModel(
            id: item.id, thumbnail: item.thumbnail, pointSize: item.pointSize,
            size: settings.size, corner: settings.corner
        )
        model.showsCopied = item.copied
        model.savedURL = item.savedURL
        if item.copied { copiedUntil[item.id] = clock.now() + Theme.QuickAccess.copiedChipSeconds }
        withAnimation(reduceMotion() ? .easeOut(duration: Theme.Motion.reducedMotionFade) : Theme.Motion.spring) {
            cards.insert(model, at: 0)
        }
        hidePanelAt = nil
        showPanel(visibleFrame: frame)
        processTimers()
    }

    /// Replaces a card's thumbnail (Background applied or removed) with a 160 ms cross-fade.
    public func updateThumbnail(_ id: String, with thumbnail: QuickAccessThumbnail) {
        guard let card = card(id) else { return }
        withAnimation(Theme.Motion.enter(Theme.Motion.backgroundCrossFade)) {
            card.thumbnail = thumbnail.image
            card.thumbnailVersion += 1
        }
        card.pointSize = thumbnail.pointSize
        card.backgroundApplied = thumbnail.backgroundApplied
        let height = QuickAccessLayout.cardHeight(pointSize: thumbnail.pointSize, size: settings.size)
        let closed = stack.setHeight(height, for: id)
        removeModels(for: closed)
    }

    public func markSaved(_ id: String, url: URL) {
        card(id)?.savedURL = url
    }

    // MARK: Closing

    public func close(_ id: String, reason: QuickAccessStack.CloseReason = .dismissed) {
        guard let closure = stack.close(id, reason: reason) else { return }
        removeModels(for: [closure])
    }

    public func closeAll() {
        removeModels(for: stack.closeAll())
    }

    private func removeModels(for closures: [QuickAccessStack.Closure]) {
        guard !closures.isEmpty else { return }
        let ids = Set(closures.map(\.id))
        let animation: Animation = reduceMotion()
            ? .easeOut(duration: Theme.Motion.reducedMotionFade)
            : Theme.Motion.exit(Theme.Motion.dismiss)
        withAnimation(animation) {
            cards.removeAll { ids.contains($0.id) }
        }
        for closure in closures {
            copiedUntil[closure.id] = nil
            confirmedUntil[closure.id] = nil
            actions.closed(closure.id, closure.reason)
        }
        if cards.isEmpty {
            // Order the panel out once the dismiss animation is done.
            hidePanelAt = clock.now() + Theme.Motion.dismiss + 0.05
        }
        // A closed card never reports the pointer leaving it, so closing the hovered card (Esc,
        // close button, Copy or Save, drag-out, swipe) must hand the keys back here while other
        // cards stay, or the panel keeps the keys with nothing hovered (design 8).
        surface?.setAcceptsKeys(cards.contains { $0.isHovered })
        processTimers()
    }

    // MARK: Hover, drag, swipe

    public func setHovered(_ hovered: Bool, for id: String) {
        guard let card = card(id), card.isHovered != hovered else { return }
        stack.setHovered(hovered, for: id)
        let animation = hovered ? Theme.Motion.enter(Theme.Motion.hoverIn) : Theme.Motion.exit(Theme.Motion.hoverOut)
        withAnimation(animation) {
            card.isHovered = hovered
        }
        surface?.setAcceptsKeys(cards.contains { $0.isHovered })
        processTimers()
    }

    public var hoveredCard: QuickAccessCardModel? { cards.first { $0.isHovered } }

    public func dragBegan(_ id: String) {
        guard let card = card(id) else { return }
        stack.dragBegan(id)
        withAnimation(reduceMotion() ? nil : Theme.Motion.enter(Theme.Motion.dragLift)) {
            card.isDragging = true
        }
        processTimers()
    }

    /// A drop that was accepted closes the card (setting on); a cancelled drag springs back.
    public func dragEnded(_ id: String, accepted: Bool) {
        guard let card = card(id) else { return }
        withAnimation(reduceMotion() ? nil : Theme.Motion.momentumSpring) {
            card.isDragging = false
        }
        if let closure = stack.dragEnded(id, dropAccepted: accepted) {
            removeModels(for: [closure])
        } else {
            processTimers()
        }
    }

    public func swipeChanged(_ id: String, translation: Double) {
        guard let card = card(id) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            card.swipeOffset = swipeRule.displayOffset(for: translation)
        }
    }

    /// Returns true when the swipe dismissed the card.
    @discardableResult
    public func swipeEnded(_ id: String, translation: Double, velocity: Double) -> Bool {
        guard let card = card(id) else { return false }
        if swipeRule.shouldDismiss(translation: translation, velocity: velocity) {
            close(id, reason: .dismissed)
            return true
        }
        withAnimation(reduceMotion() ? nil : Theme.Motion.momentumSpring) {
            card.swipeOffset = 0
        }
        return false
    }

    // MARK: Actions

    /// The action a key performs on the hovered card, if any card is hovered.
    public func handleKey(_ key: QuickAccessKey) -> Bool {
        guard let card = hoveredCard else { return false }
        let id = card.id
        Task { await self.perform(key.action, on: id) }
        return true
    }

    public func perform(_ action: QuickAccessCardAction, on id: String) async {
        guard card(id) != nil else { return }
        switch action {
        case .copy:
            let copied = await actions.copy(id)
            guard copied else { return }
            confirm(id, closeAfter: .copy)
        case .save:
            guard let url = await actions.save(id) else { return }
            card(id)?.savedURL = url
            confirm(id, closeAfter: .save)
        case .background:
            guard let thumbnail = await actions.toggleBackground(id) else { return }
            updateThumbnail(id, with: thumbnail)
        case .backgroundEditor:
            actions.openBackgroundEditor(id)
        case .annotate:
            actions.annotate(id)
        case .reveal:
            if let url = card(id)?.savedURL { actions.reveal(url) }
        case .close:
            close(id, reason: .dismissed)
        }
    }

    /// The pressed button shows a check for 900 ms (17.7 M5b); then the card closes when the
    /// setting "close after Copy or Save" is on.
    private func confirm(_ id: String, closeAfter action: QuickAccessStack.CardAction) {
        guard let card = card(id) else { return }
        withAnimation(reduceMotion() ? .easeOut(duration: Theme.Motion.copyDone) : Theme.Motion.enter(Theme.Motion.copyDone)) {
            card.confirmedAction = action == .copy ? .copy : .save
        }
        card.pendingCloseAction = action
        confirmedUntil[id] = clock.now() + Theme.Motion.copyCheckHold
        processTimers()
    }

    /// The handler a card view uses.
    public func handler(for id: String) -> QuickAccessCardHandler {
        QuickAccessCardHandler(
            edgeSign: swipeRule.edgeSign,
            perform: { [weak self] action in Task { await self?.perform(action, on: id) } },
            hover: { [weak self] hovered in self?.setHovered(hovered, for: id) },
            dragBegan: { [weak self] in self?.dragBegan(id) },
            dragEnded: { [weak self] accepted in self?.dragEnded(id, accepted: accepted) },
            swipeChanged: { [weak self] translation in self?.swipeChanged(id, translation: translation) },
            swipeEnded: { [weak self] translation, velocity in
                self?.swipeEnded(id, translation: translation, velocity: velocity)
            },
            dragURL: { [weak self] in self?.actions.dragURL(id) }
        )
    }

    // MARK: Timers

    /// Applies every timer that has run out: auto close, the Copied chip, the copy or save check,
    /// the countdown line, ordering the empty panel out. Then schedules the next wake-up.
    public func processTimers() {
        let now = clock.now()
        let expired = stack.expire()
        if !expired.isEmpty {
            removeModels(for: expired)
            return
        }

        for (id, until) in copiedUntil where until <= now {
            copiedUntil[id] = nil
            if let card = card(id) {
                withAnimation(.easeOut(duration: Theme.Motion.copiedChip)) { card.showsCopied = false }
            }
        }

        for (id, until) in confirmedUntil where until <= now {
            confirmedUntil[id] = nil
            guard let card = card(id) else { continue }
            if let action = card.pendingCloseAction, stack.closesAfter(action) {
                card.pendingCloseAction = nil
                if let closure = stack.actionSucceeded(action, on: id) {
                    removeModels(for: [closure])
                    return
                }
            }
            card.pendingCloseAction = nil
            withAnimation(Theme.Motion.enter(Theme.Motion.copyDone)) { card.confirmedAction = nil }
        }

        for card in cards {
            let showing = stack.showsCountdown(for: card.id) && !card.isHovered
            if showing, card.countdown == nil, let remaining = stack.secondsRemaining(for: card.id) {
                let window = QuickAccessStack.Configuration.countdownWindow
                withAnimation(.easeOut(duration: Theme.Motion.countdownFade)) {
                    card.countdown = QuickAccessCountdown(
                        startFraction: min(remaining / window, 1), startDate: Date(), duration: remaining
                    )
                }
            } else if !showing, card.countdown != nil {
                withAnimation(.easeOut(duration: Theme.Motion.countdownFade)) { card.countdown = nil }
            }
        }

        if let hideAt = hidePanelAt, hideAt <= now {
            hidePanelAt = nil
            if cards.isEmpty {
                surface?.hide()
                isPanelVisible = false
            }
        }
        scheduleNextWake()
    }

    /// Seconds until `processTimers` has something to do.
    public var nextWake: TimeInterval? {
        let now = clock.now()
        var deadlines: [TimeInterval] = []
        if let expiry = stack.nextExpiry { deadlines.append(now + expiry) }
        for card in cards where card.countdown == nil && !card.isHovered {
            if let remaining = stack.secondsRemaining(for: card.id) {
                deadlines.append(now + max(remaining - QuickAccessStack.Configuration.countdownWindow, 0))
            }
        }
        deadlines.append(contentsOf: copiedUntil.values)
        deadlines.append(contentsOf: confirmedUntil.values)
        if let hidePanelAt { deadlines.append(hidePanelAt) }
        return deadlines.min().map { max($0 - now, 0) }
    }

    private func scheduleNextWake() {
        timerTask?.cancel()
        timerTask = nil
        guard let delay = nextWake else { return }
        let clock = clock
        timerTask = Task { [weak self] in
            do {
                // A 1 ms floor keeps a deadline that is due now from spinning.
                try await clock.sleep(seconds: max(delay, 0.001))
            } catch {
                return
            }
            self?.processTimers()
        }
    }

    // MARK: Panel

    private func showPanel(visibleFrame frame: CGRect?) {
        if surface == nil, let makeSurface { surface = makeSurface(self) }
        guard let surface, let frame else { return }
        surface.show(frame: QuickAccessLayout.panelFrame(visibleFrame: frame, corner: settings.corner, size: settings.size))
        isPanelVisible = true
    }
}
