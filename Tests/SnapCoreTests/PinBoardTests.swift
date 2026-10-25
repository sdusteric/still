import CoreGraphics
import Foundation
import SnapCore
import Testing

/// `#require` cannot wrap a mutating call, so the result is passed in.
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

@Suite struct PinBoardTests {
    /// The 5K panel with a 24 pt menu bar and the ultrawide to its right.
    static let main = VisibleDisplay(
        id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 24, width: 2560, height: 1416)
    )
    static let side = VisibleDisplay(
        id: 2, frame: CGRect(x: 2560, y: 0, width: 3440, height: 1440),
        visibleFrame: CGRect(x: 2560, y: 0, width: 3440, height: 1440)
    )
    let displays = [main, side]
    let size = CGSize(width: 460, height: 268)

    @Test func aPinOpensAtItsCaptureRectAt100Percent() {
        var board = PinBoard(displays: displays)
        let rect = CGRect(x: 700, y: 300, width: 460, height: 268)
        let pin = board.add(itemID: "a", pointSize: size, screenRect: rect, pointer: CGPoint(x: 4000, y: 700)).pin
        #expect(pin.frame == rect)
        #expect(pin.zoomPercent == 100)
        #expect(pin.opacity == 1)
        #expect(pin.displayID == 1)
        #expect(PinBoard.sizeChipText(pin) == "460 \u{00D7} 268 \u{00B7} 100%")

        let onSide = CGRect(x: 3000, y: 100, width: 460, height: 268)
        #expect(board.add(itemID: "b", pointSize: size, screenRect: onSide, pointer: .zero).pin.frame == onSide)
    }

    @Test func withoutAUsableRectThePinIsCenteredOnThePointerDisplayWithin60Percent() {
        let big = CGSize(width: 2560, height: 1440)
        let frame = PinBoard.placement(pointSize: big, screenRect: nil, pointer: CGPoint(x: 100, y: 100), displays: displays)
        // The height limits: 60% of the 1416 pt visible height.
        let fit = 1416 * 0.6 / 1440
        #expect(abs(frame.width - 2560 * fit) < 0.001)
        #expect(abs(frame.height - 1440 * fit) < 0.001)
        #expect(abs(frame.midX - 1280) < 0.001)
        #expect(abs(frame.midY - (24 + 708)) < 0.001)

        // A rect that spans the menu bar is not fully inside a visible frame: fallback, on the
        // display under the pointer.
        let straddling = CGRect(x: 100, y: 10, width: 460, height: 268)
        let fallback = PinBoard.placement(pointSize: size, screenRect: straddling, pointer: CGPoint(x: 5000, y: 700), displays: displays)
        #expect(fallback.size == size, "a small image is never scaled up")
        #expect(abs(fallback.midX - Self.side.visibleFrame.midX) < 0.001)
        #expect(abs(fallback.midY - Self.side.visibleFrame.midY) < 0.001)
    }

    @Test func framesAreAlwaysClampedInsideTheVisibleFrame() {
        let clamped = PinBoard.clamp(CGRect(x: -50, y: 0, width: 400, height: 300), in: Self.main.visibleFrame)
        #expect(clamped == CGRect(x: 0, y: 24, width: 400, height: 300))
        let huge = PinBoard.clamp(CGRect(x: 0, y: 0, width: 5000, height: 1416), in: Self.main.visibleFrame)
        #expect(huge.width <= 2560)
        #expect(abs(huge.width / huge.height - 5000 / 1416) < 0.001)

        var board = PinBoard(displays: displays)
        let pin = board.add(itemID: "a", pointSize: size, screenRect: CGRect(x: 700, y: 300, width: 460, height: 268), pointer: .zero).pin
        let moved = board.move(pin.id, to: CGPoint(x: 2000, y: 1300))
        #expect(moved?.frame.origin == CGPoint(x: 2000, y: 1440 - 268))
        // Once its center is on the ultrawide it is clamped there instead.
        let across = board.move(pin.id, to: CGPoint(x: 2400, y: 600))
        #expect(across?.frame.origin == CGPoint(x: 2560, y: 600))
        #expect(across?.displayID == 2)
    }

    @Test func resizeKeepsTheAspectAndTheOppositeCorner() throws {
        var board = PinBoard(displays: displays)
        let start = CGRect(x: 700, y: 300, width: 460, height: 268)
        let pin = board.add(itemID: "a", pointSize: size, screenRect: start, pointer: .zero).pin
        let corner = try unwrap(board.resize(pin.id, handle: .bottomRight, to: CGPoint(x: 700 + 920, y: 400)))
        #expect(abs(corner.frame.width - 920) < 0.001)
        #expect(abs(corner.frame.height - 536) < 0.001)
        #expect(corner.frame.origin == start.origin)
        #expect(corner.zoomPercent == 200)

        let edge = try unwrap(board.resize(pin.id, handle: .left, to: CGPoint(x: 700 + 920 - 230, y: 0)))
        #expect(abs(edge.frame.width - 230) < 0.001)
        #expect(abs(edge.frame.height - 134) < 0.001)
        #expect(abs(edge.frame.maxX - (700 + 920)) < 0.001, "the right edge stays put")
    }

    @Test func zoomStepsBy10PercentAroundThePointWithinTheLimits() throws {
        var board = PinBoard(displays: displays)
        let pin = board.add(itemID: "a", pointSize: size, screenRect: CGRect(x: 700, y: 300, width: 460, height: 268), pointer: .zero).pin
        let point = CGPoint(x: 700, y: 300)
        let grown = try unwrap(board.zoom(pin.id, by: 1, around: point))
        #expect(grown.zoomPercent == 110)
        #expect(grown.frame.origin == point, "the point under the pointer stays put")

        let max = try unwrap(board.zoom(pin.id, by: 100, around: point))
        #expect(max.zoomPercent == 400)
        // 48 pt floor: 268 * z >= 48 means at least 18%.
        let min = try unwrap(board.zoom(pin.id, by: -100, around: point))
        #expect(abs(min.frame.height - 48) < 0.001)
        #expect(abs(PinBoard.minimumZoom(for: CGSize(width: 2000, height: 1000)) - 0.1) < 0.0001)
        #expect(PinBoard.minimumZoom(for: CGSize(width: 300, height: 30)) == 1, "a tiny image may stay at 100%")

        let reset = try unwrap(board.setZoom(pin.id, 1))
        #expect(reset.zoomPercent == 100)
    }

    @Test func zoomIsCappedByTheDisplay() throws {
        var board = PinBoard(displays: displays)
        let pin = board.add(itemID: "a", pointSize: CGSize(width: 1200, height: 800), screenRect: nil, pointer: CGPoint(x: 10, y: 10)).pin
        let max = try unwrap(board.setZoom(pin.id, 4))
        #expect(max.frame.height <= Self.main.visibleFrame.height + 0.001)
        #expect(Self.main.visibleFrame.contains(max.frame))
    }

    @Test func opacityMovesIn5PercentStepsWithA20PercentFloor() throws {
        var board = PinBoard(displays: displays)
        let pin = board.add(itemID: "a", pointSize: size, screenRect: nil, pointer: .zero).pin
        #expect(try unwrap(board.stepOpacity(pin.id, by: -1)).opacity == 0.95)
        #expect(try unwrap(board.setOpacity(pin.id, 0.62)).opacityPercent == 60)
        #expect(try unwrap(board.setOpacity(pin.id, 0.01)).opacity == 0.2)
        #expect(try unwrap(board.stepOpacity(pin.id, by: -3)).opacity == 0.2)
        #expect(try unwrap(board.setOpacity(pin.id, 3)).opacity == 1)
        #expect(PinBoard.opacity(forKey: "2") == 0.2)
        #expect(PinBoard.opacity(forKey: "9") == 0.9)
        #expect(PinBoard.opacity(forKey: "0") == 1)
        #expect(PinBoard.opacity(forKey: "1") == nil)
        #expect(PinBoard.opacity(forKey: "a") == nil)
    }

    @Test func theNinthPinClosesTheOldest() {
        var board = PinBoard(displays: displays)
        var first: Pin?
        for index in 0..<8 {
            let result = board.add(itemID: "i\(index)", pointSize: size, screenRect: nil, pointer: .zero)
            if index == 0 { first = result.pin }
            #expect(result.closed == nil)
        }
        #expect(board.count == 8)
        let ninth = board.add(itemID: "i8", pointSize: size, screenRect: nil, pointer: .zero)
        #expect(ninth.closed == first)
        #expect(board.count == 8)
        #expect(board.pins.map(\.itemID) == (1...8).map { "i\($0)" })
        #expect(board.pinnedItemIDs.contains("i0") == false)
    }

    @Test func pinsOnARemovedDisplayMoveToTheCenterOfTheMainDisplay() {
        var board = PinBoard(displays: displays)
        let onSide = board.add(itemID: "s", pointSize: size, screenRect: CGRect(x: 5400, y: 1100, width: 460, height: 268), pointer: .zero).pin
        #expect(onSide.displayID == 2)
        let onMain = board.add(itemID: "m", pointSize: size, screenRect: CGRect(x: 100, y: 100, width: 460, height: 268), pointer: .zero).pin
        let moved = board.displaysChanged([Self.main])
        #expect(moved.map(\.id) == [onSide.id])
        let relocated = board.pin(onSide.id)
        #expect(relocated?.displayID == 1)
        #expect(abs((relocated?.frame.midX ?? 0) - Self.main.visibleFrame.midX) < 0.001)
        #expect(abs((relocated?.frame.midY ?? 0) - Self.main.visibleFrame.midY) < 0.001)
        #expect(board.pin(onMain.id)?.frame == onMain.frame)
    }

    @Test func clickThroughAndTheMenuList() throws {
        var board = PinBoard(displays: displays)
        let date = Date(timeIntervalSince1970: 1_792_843_200)
        let older = board.add(itemID: "a", pointSize: size, screenRect: nil, pointer: .zero, createdAt: date).pin
        let newer = board.add(itemID: "b", pointSize: size, screenRect: nil, pointer: .zero, createdAt: date.addingTimeInterval(60)).pin
        #expect(try unwrap(board.toggleClickThrough(older.id)).clickThrough)
        #expect(board.menuEntries.map(\.id) == [newer.id, older.id])
        #expect(board.menuEntries.last?.clickThrough == true)
        #expect(try unwrap(board.setClickThrough(older.id, false)).clickThrough == false)
        #expect(board.close(newer.id)?.itemID == "b")
        #expect(board.close(newer.id) == nil)
        #expect(board.closeAll().map(\.itemID) == ["a"])
        #expect(board.isEmpty)
    }
}
