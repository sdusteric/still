import Foundation

/// Order, limits and timers of the Quick Access card stack (design section 8). Pure: time comes
/// from an injected `Clock`, and the UI calls `expire()` when `nextExpiry` has passed.
///
/// Cards are newest first, so index 0 sits at the corner edge. A card's auto close timer runs
/// only while the pointer is off it and no drag is in progress; leaving restarts the full interval.
public struct QuickAccessStack: Sendable {
    public struct Configuration: Sendable, Hashable {
        public static let maxCards = 5
        public static let cardSpacing = 8.0
        /// The countdown line shows during this many last seconds.
        public static let countdownWindow = 5.0

        public var maxCards: Int
        public var autoClose: Bool
        public var autoCloseSeconds: Double
        public var closeAfterDragOut: Bool
        public var closeAfterCopyOrSave: Bool
        /// 70% of the screen's `visibleFrame` height; nil for no height limit.
        public var maxStackHeight: Double?

        public init(
            maxCards: Int = Configuration.maxCards,
            autoClose: Bool = true,
            autoCloseSeconds: Double = 15,
            closeAfterDragOut: Bool = true,
            closeAfterCopyOrSave: Bool = true,
            maxStackHeight: Double? = nil
        ) {
            self.maxCards = max(maxCards, 1)
            self.autoClose = autoClose
            self.autoCloseSeconds = autoCloseSeconds
            self.closeAfterDragOut = closeAfterDragOut
            self.closeAfterCopyOrSave = closeAfterCopyOrSave
            self.maxStackHeight = maxStackHeight
        }

        public init(settings: QuickAccessSettings, maxStackHeight: Double? = nil) {
            self.init(
                autoClose: settings.autoClose,
                autoCloseSeconds: Double(settings.autoCloseSeconds),
                closeAfterDragOut: settings.closeAfterDragOut,
                closeAfterCopyOrSave: settings.closeAfterCopyOrSave,
                maxStackHeight: maxStackHeight
            )
        }
    }

    /// What a card shows (design 20.6): a screenshot, or a finished recording whose card offers
    /// Open, Save, Reveal and Copy instead of Background, Annotate and Pin.
    public enum CardKind: String, Sendable, Hashable, CaseIterable {
        case screenshot
        case video

        /// Background, Annotate and Pin apply to screenshots only (design D46, D67).
        public var canEdit: Bool { self == .screenshot }
        public var canPin: Bool { self == .screenshot }
        /// A video card's Open button plays the file in the default player.
        public var canOpen: Bool { self == .video }
        /// Copy on a video card puts the mp4's file URL on the pasteboard, not an image.
        public var copiesFileURL: Bool { self == .video }
    }

    public struct Card: Sendable, Hashable, Identifiable {
        public let id: String
        public var kind: CardKind = .screenshot
        public var height: Double
        public var isHovered = false
        public var isDragging = false
        /// Monotonic time the card closes at; nil while paused or with auto close off.
        public var deadline: TimeInterval?

        public var isPaused: Bool { isHovered || isDragging }
    }

    public enum CloseReason: Sendable, Hashable {
        case autoClose
        /// A sixth card arrived.
        case overflow
        /// The stack grew past 70% of the screen height.
        case tooTall
        /// Close button, Esc, swipe or code.
        case dismissed
        case draggedOut
        case copied
        case saved
        /// The screenshot was pinned to the screen; the same image is now on screen (design D46).
        case pinned
    }

    public struct Closure: Sendable, Hashable {
        public let id: String
        public let reason: CloseReason

        public init(id: String, reason: CloseReason) {
            self.id = id
            self.reason = reason
        }
    }

    /// What the user did with a card that may close it afterwards.
    public enum CardAction: Sendable, Hashable {
        case copy, save
    }

    public private(set) var cards: [Card] = []
    public var configuration: Configuration
    private let clock: any Clock

    public init(clock: any Clock, configuration: Configuration = Configuration()) {
        self.clock = clock
        self.configuration = configuration
    }

    public var ids: [String] { cards.map(\.id) }
    public var count: Int { cards.count }
    public func contains(_ id: String) -> Bool { cards.contains { $0.id == id } }
    public func kind(of id: String) -> CardKind? { cards.first { $0.id == id }?.kind }

    /// Total height of the cards and the gaps between them.
    public var stackHeight: Double {
        cards.reduce(0) { $0 + $1.height } + Configuration.cardSpacing * Double(max(cards.count - 1, 0))
    }

    // MARK: Adding and closing

    /// Adds a card at the corner edge and returns the cards that had to close to make room.
    @discardableResult
    public mutating func push(id: String, height: Double, kind: CardKind = .screenshot) -> [Closure] {
        cards.removeAll { $0.id == id }
        var card = Card(id: id, kind: kind, height: height)
        card.deadline = newDeadline()
        cards.insert(card, at: 0)

        var closed: [Closure] = []
        while cards.count > configuration.maxCards {
            closed.append(Closure(id: cards.removeLast().id, reason: .overflow))
        }
        if let limit = configuration.maxStackHeight {
            while cards.count > 1 && stackHeight > limit {
                closed.append(Closure(id: cards.removeLast().id, reason: .tooTall))
            }
        }
        return closed
    }

    /// Changes a card's height, for example when the thumbnail aspect is known. Returns the cards
    /// closed by the height limit.
    @discardableResult
    public mutating func setHeight(_ height: Double, for id: String) -> [Closure] {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return [] }
        cards[index].height = height
        var closed: [Closure] = []
        if let limit = configuration.maxStackHeight {
            while cards.count > 1 && stackHeight > limit {
                closed.append(Closure(id: cards.removeLast().id, reason: .tooTall))
            }
        }
        return closed
    }

    @discardableResult
    public mutating func close(_ id: String, reason: CloseReason = .dismissed) -> Closure? {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
        cards.remove(at: index)
        return Closure(id: id, reason: reason)
    }

    public mutating func closeAll(reason: CloseReason = .dismissed) -> [Closure] {
        let closed = cards.map { Closure(id: $0.id, reason: reason) }
        cards.removeAll()
        return closed
    }

    // MARK: Hover and drag

    public mutating func setHovered(_ hovered: Bool, for id: String) {
        update(id) { $0.isHovered = hovered }
    }

    public mutating func dragBegan(_ id: String) {
        update(id) { $0.isDragging = true }
    }

    /// The drag ended. A drop that was accepted closes the card when the setting is on; a cancelled
    /// drag keeps it, and the timer restarts unless the pointer is still over it.
    @discardableResult
    public mutating func dragEnded(_ id: String, dropAccepted: Bool) -> Closure? {
        update(id) { $0.isDragging = false }
        if dropAccepted && configuration.closeAfterDragOut {
            return close(id, reason: .draggedOut)
        }
        return nil
    }

    // MARK: Pin

    /// Pinning a screenshot closes its card (design D46). A video card cannot be pinned and stays.
    @discardableResult
    public mutating func pinned(_ id: String) -> Closure? {
        guard kind(of: id)?.canPin == true else { return nil }
        return close(id, reason: .pinned)
    }

    // MARK: Copy and save

    /// Whether the card closes once `action` has succeeded (the setting "close after Copy or Save").
    /// The UI calls `close` after its own 900 ms confirmation.
    public func closesAfter(_ action: CardAction) -> Bool {
        configuration.closeAfterCopyOrSave
    }

    @discardableResult
    public mutating func actionSucceeded(_ action: CardAction, on id: String) -> Closure? {
        guard closesAfter(action) else { return nil }
        return close(id, reason: action == .copy ? .copied : .saved)
    }

    // MARK: Timers

    /// Closes every card whose timer has run out.
    public mutating func expire() -> [Closure] {
        let now = clock.now()
        var closed: [Closure] = []
        cards.removeAll { card in
            guard let deadline = card.deadline, deadline <= now else { return false }
            closed.append(Closure(id: card.id, reason: .autoClose))
            return true
        }
        return closed
    }

    /// Seconds until the earliest timer fires, for scheduling the UI's next `expire()` call.
    public var nextExpiry: TimeInterval? {
        let now = clock.now()
        return cards.compactMap(\.deadline).min().map { max($0 - now, 0) }
    }

    /// Seconds left on a card's timer; nil when it is paused or auto close is off.
    public func secondsRemaining(for id: String) -> TimeInterval? {
        guard let deadline = cards.first(where: { $0.id == id })?.deadline else { return nil }
        return max(deadline - clock.now(), 0)
    }

    /// Whether the 2 pt countdown line shows: the last 5 seconds, and not while hovered or dragged.
    public func showsCountdown(for id: String) -> Bool {
        guard let remaining = secondsRemaining(for: id) else { return false }
        return remaining <= Configuration.countdownWindow
    }

    /// Applies new settings. Running timers keep their deadlines; paused cards get one when released.
    /// Turning auto close off clears every deadline, turning it on starts timers on free cards that
    /// have none. A new interval keeps the time a running timer has already used.
    public mutating func apply(_ configuration: Configuration) {
        let old = self.configuration
        self.configuration = configuration
        guard configuration.autoClose else {
            for index in cards.indices { cards[index].deadline = nil }
            return
        }
        let change = old.autoClose ? configuration.autoCloseSeconds - old.autoCloseSeconds : 0
        for index in cards.indices where !cards[index].isPaused {
            if let deadline = cards[index].deadline {
                cards[index].deadline = deadline + change
            } else {
                cards[index].deadline = newDeadline()
            }
        }
    }

    private mutating func update(_ id: String, _ change: (inout Card) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let wasPaused = cards[index].isPaused
        change(&cards[index])
        let paused = cards[index].isPaused
        if paused {
            cards[index].deadline = nil
        } else if wasPaused {
            cards[index].deadline = newDeadline()
        }
    }

    private func newDeadline() -> TimeInterval? {
        configuration.autoClose ? clock.now() + configuration.autoCloseSeconds : nil
    }
}
