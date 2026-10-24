import AppKit
import SnapCore
import SwiftUI

/// The card thumbnail as an AppKit drag source (design 8, D12). A drag drags a file URL to the
/// item's current PNG in history and offers `.copy`, so Finder never moves Snap's copy. A
/// horizontal drag toward the anchored screen edge, or a two-finger swipe, is a swipe dismiss
/// instead (17.7 M7).
struct ThumbnailDragView: NSViewRepresentable {
    var image: CGImage
    /// The thumbnail's size on the card, which the drag image scales from.
    var displaySize: CGSize
    var handler: QuickAccessCardHandler

    func makeNSView(context: Context) -> ThumbnailDragSourceView {
        let view = ThumbnailDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ThumbnailDragSourceView, context: Context) {
        view.image = image
        view.displaySize = displaySize
        view.handler = handler
    }
}

final class ThumbnailDragSourceView: NSView, NSDraggingSource {
    private enum Gesture {
        case undecided(start: CGPoint)
        case swiping(start: CGPoint)
        case dragging
    }

    /// Movement before a press becomes a drag or a swipe.
    static let decisionDistance = 4.0

    var image: CGImage?
    var displaySize = CGSize(width: 240, height: 150)
    var handler: QuickAccessCardHandler = .inert
    private var gesture: Gesture?
    private var velocity = VelocityTracker()
    private var scrollTranslation = 0.0
    private var isScrolling = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        gesture = .undecided(start: convert(event.locationInWindow, from: nil))
        velocity.reset()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .undecided(let start):
            let dx = point.x - start.x
            let dy = point.y - start.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.decisionDistance else { return }
            if Self.isSwipe(dx: dx, dy: dy, edgeSign: handler.edgeSign) {
                gesture = .swiping(start: start)
                velocity.add(dx, at: event.timestamp)
                handler.swipeChanged(dx)
            } else {
                gesture = .dragging
                beginFileDrag(with: event)
            }
        case .swiping(let start):
            let dx = point.x - start.x
            velocity.add(dx, at: event.timestamp)
            handler.swipeChanged(dx)
        case .dragging, .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .swiping(let start) = gesture {
            let dx = convert(event.locationInWindow, from: nil).x - start.x
            velocity.add(dx, at: event.timestamp)
            handler.swipeEnded(dx, velocity.velocity)
        }
        gesture = nil
    }

    /// Mostly horizontal and toward the edge the stack is anchored to.
    static func isSwipe(dx: Double, dy: Double, edgeSign: Double) -> Bool {
        abs(dx) > abs(dy) * 1.5 && dx * edgeSign > 0
    }

    // MARK: Trackpad swipe

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else {
            super.scrollWheel(with: event)
            return
        }
        // Natural scrolling reports finger travel inverted; turn it back into finger direction.
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if event.phase.contains(.began) {
            isScrolling = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            scrollTranslation = 0
            velocity.reset()
        }
        guard isScrolling else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.changed) || event.phase.contains(.began) {
            scrollTranslation += delta
            velocity.add(scrollTranslation, at: event.timestamp)
            handler.swipeChanged(scrollTranslation)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            isScrolling = false
            handler.swipeEnded(scrollTranslation, velocity.velocity)
        }
    }

    // MARK: Drag out

    private func beginFileDrag(with event: NSEvent) {
        guard let url = handler.dragURL() else { return }
        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardWriter(for: url))
        let dragImage = Self.dragImage(from: image, displaySize: displaySize)
        let location = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            CGRect(
                x: location.x - dragImage.size.width / 2,
                y: location.y - dragImage.size.height / 2,
                width: dragImage.size.width,
                height: dragImage.size.height
            ),
            contents: dragImage
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        handler.dragBegan()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        Self.operationMask(for: context)
    }

    /// Only a copy is offered, inside or outside the app, so a Finder drop never moves the history
    /// file. Split out so the tests can check it without a live drag session.
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation { .copy }

    /// What the drag puts on the dragging pasteboard: the PNG's file URL and nothing else.
    static func pasteboardWriter(for url: URL) -> any NSPasteboardWriting { url as NSURL }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        gesture = nil
        handler.dragEnded(operation != [])
    }

    /// The thumbnail at 0.45 scale, radius 6, rotated -2 degrees, with a lifted shadow (17.6).
    static func dragImage(from image: CGImage?, displaySize: CGSize) -> NSImage {
        let scale = Theme.QuickAccess.dragImageScale
        let content = CGSize(width: max(displaySize.width * scale, 40), height: max(displaySize.height * scale, 30))
        let margin = 24.0
        let canvas = CGSize(width: content.width + 2 * margin, height: content.height + 2 * margin)
        return NSImage(size: canvas, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            context.rotate(by: -Theme.QuickAccess.dragImageRotationDegrees * .pi / 180)
            let rect = CGRect(x: -content.width / 2, y: -content.height / 2, width: content.width, height: content.height)
            let radius = Theme.QuickAccess.dragImageRadius
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addPath(path)
            context.clip()
            if let image { context.draw(image, in: rect) }
            context.resetClip()
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.3))
            context.setLineWidth(0.5)
            context.strokePath()
            return true
        }
    }
}

/// Velocity in points per second from the last 100 ms of samples.
struct VelocityTracker {
    private var samples: [(value: Double, time: TimeInterval)] = []

    mutating func reset() { samples.removeAll() }

    mutating func add(_ value: Double, at time: TimeInterval) {
        samples.append((value, time))
        samples.removeAll { time - $0.time > 0.1 }
    }

    var velocity: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.value - first.value) / (last.time - first.time)
    }
}
