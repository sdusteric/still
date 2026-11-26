import AppKit
import Observation
import SnapCore
import SwiftUI

/// One capture handed to the Quick Access stack: a screenshot, or a finished recording whose
/// thumbnail is its poster (design 20.6).
public struct QuickAccessItem: Sendable {
    public var id: String
    public var thumbnail: CGImage
    /// Size in points, shown in the dimension pill. For a recording, the poster's size.
    public var pointSize: CGSize
    /// The clipboard already holds it (the image, or a recording's file URL), so the card shows
    /// "Copied" for 2 s.
    public var copied: Bool
    public var savedURL: URL?
    public var kind: QuickAccessStack.CardKind
    /// A recording's length, shown in the duration pill in place of the dimension pill.
    public var durationSeconds: Double?
    /// A short note shown on the card for 4 s, such as "Stopped: the window closed" or
    /// "No microphone" (design 20.6, D69).
    public var note: String?
    /// A recording whose file does not play: the card offers Reveal in Finder and Close only.
    public var revealOnly: Bool
    /// Whether the asked-for audio is in a recording (design 20.6); nil when none was asked for.
    public var audioCheck: AudioCheck?

    public init(
        id: String,
        thumbnail: CGImage,
        pointSize: CGSize,
        copied: Bool = true,
        savedURL: URL? = nil,
        kind: QuickAccessStack.CardKind = .screenshot,
        durationSeconds: Double? = nil,
        note: String? = nil,
        revealOnly: Bool = false,
        audioCheck: AudioCheck? = nil
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        self.copied = copied
        self.savedURL = savedURL
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.note = note
        self.revealOnly = revealOnly
        self.audioCheck = audioCheck
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
    case copy, copyFile, save, background, backgroundEditor, annotate, reveal, close
    /// Pin to Screen (design 20.2): screenshot cards only.
    case pin
    /// Open the recording in the default player (design 20.6): video cards only.
    case open
    /// Copy the text in the screenshot (key T): screenshot cards only.
    case copyText
    /// Move the capture to the Trash and close the card (Command-Delete).
    case trash

    /// Whether the action exists on a card of `kind`. Reveal also needs a file to show, which the
    /// controller checks when it runs.
    public func isAvailable(on kind: QuickAccessStack.CardKind) -> Bool {
        switch self {
        case .background, .backgroundEditor, .annotate: kind.canEdit
        case .pin, .copyText: kind.canPin
        case .open: kind.canOpen
        case .copy, .copyFile, .save, .reveal, .close, .trash: true
        }
    }
}

/// What the app does for each card action. Supplied by the app wiring, so this UI does not depend
/// on the pasteboard, the renderer or the editors.
public struct QuickAccessActions {
    /// Copies the item's current PNG; true on success.
    public var copy: @MainActor (String) async -> Bool
    /// "Copy file" (Option on Copy): copies the URL of the item's current PNG; true on success.
    public var copyFile: @MainActor (String) async -> Bool
    /// Saves to the save folder; the saved file on success.
    public var save: @MainActor (String) async -> URL?
    /// Applies the default preset, or removes it when applied.
    public var toggleBackground: @MainActor (String) async -> QuickAccessThumbnail?
    public var openBackgroundEditor: @MainActor (String) -> Void
    public var annotate: @MainActor (String) -> Void
    public var reveal: @MainActor (URL) -> Void
    /// The item's current PNG in `SNAP_HOME/history/<id>/`, or a recording's mp4, for drag-out
    /// and for Reveal on a video card that was not saved.
    public var dragURL: @MainActor (String) -> URL?
    /// Pins the card's screenshot (design 20.2); true when a pin opened, which closes the card.
    public var pin: @MainActor (String) async -> Bool
    /// Opens a recording in the default player.
    public var open: @MainActor (String) -> Void
    /// Reads the screenshot's text and copies it.
    public var copyText: @MainActor (String) async -> CaptureText.Outcome
    /// Moves the capture's history folder to the Trash; true when it moved.
    public var trash: @MainActor (String) async -> Bool
    /// A card left the stack.
    public var closed: @MainActor (String, QuickAccessStack.CloseReason) -> Void

    public init(
        copy: @escaping @MainActor (String) async -> Bool = { _ in false },
        copyFile: @escaping @MainActor (String) async -> Bool = { _ in false },
        save: @escaping @MainActor (String) async -> URL? = { _ in nil },
        toggleBackground: @escaping @MainActor (String) async -> QuickAccessThumbnail? = { _ in nil },
        openBackgroundEditor: @escaping @MainActor (String) -> Void = { _ in },
        annotate: @escaping @MainActor (String) -> Void = { _ in },
        reveal: @escaping @MainActor (URL) -> Void = { _ in },
        dragURL: @escaping @MainActor (String) -> URL? = { _ in nil },
        pin: @escaping @MainActor (String) async -> Bool = { _ in false },
        open: @escaping @MainActor (String) -> Void = { _ in },
        copyText: @escaping @MainActor (String) async -> CaptureText.Outcome = { _ in .failed },
        trash: @escaping @MainActor (String) async -> Bool = { _ in false },
        closed: @escaping @MainActor (String, QuickAccessStack.CloseReason) -> Void = { _, _ in }
    ) {
        self.copy = copy
        self.copyFile = copyFile
        self.save = save
        self.toggleBackground = toggleBackground
        self.openBackgroundEditor = openBackgroundEditor
        self.annotate = annotate
        self.reveal = reveal
        self.dragURL = dragURL
        self.pin = pin
        self.open = open
        self.copyText = copyText
        self.trash = trash
        self.closed = closed
    }
}

/// Keys on a hovered card (design 8, 20.2, 20.6): C, S, A, B, P, Delete or Esc, and Option-C for
/// Copy File on a screenshot card; O, S, R, C, Delete or Esc on a video card. A key whose action
/// the hovered card lacks does nothing.
public enum QuickAccessKey: Sendable, Hashable {
    case copy, copyFile, save, annotate, background, close, pin, open, reveal, copyText, trash

    /// `characters` is `charactersIgnoringModifiers`, so Option-C still reads as "c".
    public init?(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        // Command-Delete moves the capture to the Trash, as in Finder and History.
        if modifiers.contains(.command), !modifiers.contains(.control), keyCode == 51 || keyCode == 117 {
            self = .trash
            return
        }
        let blocking: NSEvent.ModifierFlags = [.command, .control]
        guard modifiers.intersection(blocking).isEmpty else { return nil }
        if modifiers.contains(.option) {
            guard characters?.lowercased() == "c" else { return nil }
            self = .copyFile
            return
        }
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
        case "p": self = .pin
        case "o": self = .open
        case "r": self = .reveal
        case "t": self = .copyText
        default: return nil
        }
    }

    public var action: QuickAccessCardAction {
        switch self {
        case .copy: .copy
        case .copyFile: .copyFile
        case .save: .save
        case .annotate: .annotate
        case .background: .background
        case .close: .close
        case .pin: .pin
        case .open: .open
        case .copyText: .copyText
        case .trash: .trash
        case .reveal: .reveal
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
    @ObservationIgnored private let optionHeld: @MainActor () -> Bool
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var copiedUntil: [String: TimeInterval] = [:]
    @ObservationIgnored private var noteUntil: [String: TimeInterval] = [:]
    @ObservationIgnored private var confirmedUntil: [String: TimeInterval] = [:]
    @ObservationIgnored private var hidePanelAt: TimeInterval?
    @ObservationIgnored public private(set) var isPanelVisible = false
    /// The visible frame the panel was last placed in, for `thumbnailFrame(for:)`.
    @ObservationIgnored private var lastVisibleFrame: CGRect?

    /// - Parameters:
    ///   - visibleFrame: `visibleFrame` of the screen under the pointer, `NSScreen` coordinates.
    ///   - makeSurface: builds the panel on the first card; nil (tests, shot mode) means no panel.
    public init(
        clock: any Clock,
        settings: QuickAccessSettings = QuickAccessSettings(),
        actions: QuickAccessActions = QuickAccessActions(),
        visibleFrame: @escaping @MainActor () -> CGRect? = { nil },
        reduceMotion: @escaping @MainActor () -> Bool = { false },
        optionHeld: @escaping @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) },
        makeSurface: SurfaceFactory? = nil
    ) {
        self.clock = clock
        self.settings = settings
        self.actions = actions
        self.visibleFrame = visibleFrame
        self.reduceMotion = reduceMotion
        self.optionHeld = optionHeld
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
        let closed = stack.push(id: item.id, height: height, kind: item.kind)
        cards.removeAll { $0.id == item.id }
        removeModels(for: closed)
        if let frame { lastVisibleFrame = frame }

        let model = QuickAccessCardModel(
            id: item.id, thumbnail: item.thumbnail, pointSize: item.pointSize,
            size: settings.size, corner: settings.corner, kind: item.kind, durationSeconds: item.durationSeconds
        )
        model.showsCopied = item.copied
        model.savedURL = item.savedURL
        model.note = item.note
        model.revealOnly = item.revealOnly
        model.audioCheck = item.audioCheck
        if item.copied { copiedUntil[item.id] = clock.now() + Theme.QuickAccess.copiedChipSeconds }
        if item.note != nil { noteUntil[item.id] = clock.now() + Theme.QuickAccessM2.noteSeconds }
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
        // M2: the card's height and the cards around it move on the spring; B again retargets it.
        withAnimation(QuickAccessMotion.reflow(reduceMotion: reduceMotion())) {
            card.pointSize = thumbnail.pointSize
        }
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
        // The closing cards carry their own exit curve in the removal transition (M6); the ones
        // that stay close the gap on the spring (M2).
        withAnimation(QuickAccessMotion.reflow(reduceMotion: reduceMotion())) {
            cards.removeAll { ids.contains($0.id) }
        }
        for closure in closures {
            copiedUntil[closure.id] = nil
            noteUntil[closure.id] = nil
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
        updateKeyGrab()
        processTimers()
    }

    // MARK: Hover, drag, swipe

    public func setHovered(_ hovered: Bool, for id: String) {
        guard let card = card(id), card.isHovered != hovered else { return }
        stack.setHovered(hovered, for: id)
        let animation = hovered ? Theme.Motion.enter(Theme.Motion.hoverIn) : Theme.Motion.exit(Theme.Motion.hoverOut)
        if hovered { card.copiesFile = optionHeld() }
        withAnimation(animation) {
            card.isHovered = hovered
        }
        updateKeyGrab()
        processTimers()
    }

    public var hoveredCard: QuickAccessCardModel? { cards.first { $0.isHovered } }

    /// True while a card is hovered, false when none is: the app grabs `grabbedKeys` as global
    /// hotkeys meanwhile. The panel belongs to a background app, so it never gets key events itself.
    @ObservationIgnored public var onKeyGrabChanged: ((Bool) -> Void)?
    @ObservationIgnored private var keysGrabbed = false

    private func updateKeyGrab() {
        let hovered = cards.contains { $0.isHovered }
        surface?.setAcceptsKeys(hovered)
        guard hovered != keysGrabbed else { return }
        keysGrabbed = hovered
        onKeyGrabChanged?(hovered)
    }

    /// The keys of a hovered card as Carbon key codes and modifiers (design 8, 20.2, 20.6).
    public static let grabbedKeys: [(shortcut: KeyShortcut, key: QuickAccessKey)] = {
        let command = KeyShortcut.Modifier.command
        let option = KeyShortcut.Modifier.option
        let plain: [(UInt32, QuickAccessKey)] = [
            (8, .copy), (1, .save), (0, .annotate), (11, .background), (35, .pin), (31, .open), (15, .reveal),
            (17, .copyText), (51, .close), (117, .close), (53, .close),
        ]
        return plain.map { (KeyShortcut(keyCode: $0.0, modifiers: 0), $0.1) } + [
            (KeyShortcut(keyCode: 8, modifiers: option), .copyFile),
            (KeyShortcut(keyCode: 51, modifiers: command), .trash),
            (KeyShortcut(keyCode: 117, modifiers: command), .trash),
        ]
    }()

    /// A grabbed key went down: acts on the hovered card like the panel's own key event.
    public func grabbedKey(at index: Int) {
        guard Self.grabbedKeys.indices.contains(index) else { return }
        _ = handleKey(Self.grabbedKeys[index].key)
    }

    /// Option went down or up while the panel had the keys: the Copy button reads Copy File.
    public func setOptionHeld(_ held: Bool) {
        for card in cards where card.copiesFile != held { card.copiesFile = held }
    }

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
            // M7: the release velocity carries the card on toward the edge while it fades.
            if !reduceMotion() {
                let edge = swipeRule.edgeSign
                card.swipeDismissed = true
                withAnimation(QuickAccessMotion.swipeRelease(velocity: velocity * edge)) {
                    card.swipeOffset += abs(Theme.Motion.cardDismissOffsetX) * edge
                }
            }
            close(id, reason: .dismissed)
            return true
        }
        withAnimation(reduceMotion() ? nil : Theme.Motion.momentumSpring) {
            card.swipeOffset = 0
        }
        return false
    }

    // MARK: Actions

    /// The action a key performs on the hovered card, if any card is hovered and has that action.
    public func handleKey(_ key: QuickAccessKey) -> Bool {
        guard let card = hoveredCard, card.allows(key.action) else { return false }
        let id = card.id
        // Reveal needs a saved file (or a recording's mp4); otherwise the key is not ours.
        if key.action == .reveal, revealURL(for: id) == nil { return false }
        Task { await self.perform(key.action, on: id) }
        return true
    }

    public func perform(_ action: QuickAccessCardAction, on id: String) async {
        guard let model = card(id), model.allows(action) else { return }
        switch action {
        case .copy, .copyFile:
            // A recording is copied as its file URL (design D67), with or without Option.
            let asFile = action == .copyFile || model.kind.copiesFileURL
            let copied = asFile ? await actions.copyFile(id) : await actions.copy(id)
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
            if let url = revealURL(for: id) { actions.reveal(url) }
        case .close:
            close(id, reason: .dismissed)
        case .pin:
            // The pin opens from the card thumbnail's frame (M17) while the card leaves with M6.
            guard await actions.pin(id), let closure = stack.pinned(id) else { return }
            removeModels(for: [closure])
        case .open:
            actions.open(id)
        case .copyText:
            let outcome = await actions.copyText(id)
            showNote(outcome.message, on: id)
        case .trash:
            guard await actions.trash(id) else {
                showNote("Could not move to the Trash", on: id)
                return
            }
            close(id, reason: .trashed)
        }
    }

    /// A short line on the card, such as "Text copied" or "Not saved to History", for 4 s.
    public func showNote(_ note: String, on id: String) {
        guard let card = card(id) else { return }
        withAnimation(.easeOut(duration: Theme.Motion.copiedChip)) { card.note = note }
        noteUntil[id] = clock.now() + Theme.QuickAccessM2.noteSeconds
        processTimers()
    }

    /// The clipboard write failed after the card showed "Copied".
    public func markNotCopied(_ id: String) {
        guard let card = card(id) else { return }
        copiedUntil[id] = nil
        withAnimation(.easeOut(duration: Theme.Motion.copiedChip)) { card.showsCopied = false }
        showNote("Not copied", on: id)
    }

    /// The saved copy when there is one; a video card also reveals its mp4 in history.
    public func revealURL(for id: String) -> URL? {
        guard let model = card(id) else { return nil }
        if let saved = model.savedURL { return saved }
        return model.kind == .video ? actions.dragURL(id) : nil
    }

    /// Where a card's thumbnail is on screen, in `NSScreen` coordinates, while the panel is up:
    /// the start frame of the pin's grow animation (20.12 M17).
    public func thumbnailFrame(for id: String) -> CGRect? {
        guard let visible = lastVisibleFrame, let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
        let panel = QuickAccessLayout.panelFrame(visibleFrame: visible, corner: settings.corner, size: settings.size)
        let margin = QuickAccessLayout.shadowMargin
        let gap = Theme.QuickAccess.cardGap
        let before = cards[..<index].reduce(0) { $0 + $1.cardSize.height + gap }
        let card = cards[index].cardSize
        let left = settings.corner == .bottomLeft || settings.corner == .topLeft
        let bottom = settings.corner == .bottomLeft || settings.corner == .bottomRight
        let x = left ? panel.minX + margin : panel.maxX - margin - card.width
        let y = bottom ? panel.minY + margin + before : panel.maxY - margin - before - card.height
        let padding = Theme.QuickAccess.cardPadding
        return CGRect(x: x, y: y, width: card.width, height: card.height).insetBy(dx: padding, dy: padding)
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
            perform: { [weak self] action in
                guard let self else { return }
                // Option-click on Copy is Copy File (design 9).
                let resolved = action == .copy && optionHeld() ? QuickAccessCardAction.copyFile : action
                Task { await self.perform(resolved, on: id) }
            },
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

        for (id, until) in noteUntil where until <= now {
            noteUntil[id] = nil
            if let card = card(id) {
                withAnimation(.easeOut(duration: Theme.Motion.copiedChip)) { card.note = nil }
            }
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
        deadlines.append(contentsOf: noteUntil.values)
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
