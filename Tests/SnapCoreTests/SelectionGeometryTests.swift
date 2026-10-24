import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct SelectionGeometryTests {
    /// 2560x1440 points at 2x (the 5K panel).
    static let twoX = SelectionGeometry(display: DisplayInfo.fake5K)
    /// 3440x1440 points at 1x (the ultrawide), placed at the origin.
    static let oneX = SelectionGeometry(display: DisplayInfo(
        id: 2, frameTopLeft: CGRect(x: 0, y: 0, width: 3440, height: 1440), scale: 1
    ))
    /// A 1x display to the right of the 5K panel, so its origin is not zero.
    static let secondary = SelectionGeometry(display: DisplayInfo(
        id: 3, frameTopLeft: CGRect(x: 2560, y: 0, width: 1920, height: 1080), scale: 1
    ))

    // MARK: Normalize

    @Test func normalizeOrdersCornersInEveryDirection() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(SelectionGeometry.normalize(CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)) == expected)
        #expect(SelectionGeometry.normalize(CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20)) == expected)
        #expect(SelectionGeometry.normalize(CGPoint(x: 40, y: 20), CGPoint(x: 10, y: 60)) == expected)
        #expect(SelectionGeometry.normalize(CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 20)) == expected)
    }

    @Test func normalizeFlipsANegativeSizeRect() {
        let flipped = CGRect(x: 40, y: 60, width: -30, height: -40)
        #expect(SelectionGeometry.normalize(flipped) == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    // MARK: Clamp

    @Test func clampKeepsPointsInsideTheDisplay() {
        let geometry = Self.twoX
        #expect(geometry.clamp(CGPoint(x: -20, y: 5000)) == CGPoint(x: 0, y: 1440))
        #expect(geometry.clamp(CGPoint(x: 3000, y: -1)) == CGPoint(x: 2560, y: 0))
        #expect(geometry.clamp(CGPoint(x: 100, y: 100)) == CGPoint(x: 100, y: 100))
    }

    @Test func clampShiftsARectBackInsideWithoutResizingIt() {
        let geometry = Self.oneX
        let rect = CGRect(x: 3400, y: -30, width: 100, height: 80)
        #expect(geometry.clamp(rect) == CGRect(x: 3340, y: 0, width: 100, height: 80))
    }

    @Test func clampShrinksARectLargerThanTheDisplay() {
        let rect = CGRect(x: -50, y: -50, width: 5000, height: 5000)
        #expect(Self.twoX.clamp(rect) == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    @Test func clampUsesTheDisplayOriginOnASecondDisplay() {
        let geometry = Self.secondary
        #expect(geometry.clamp(CGPoint(x: 100, y: 500)) == CGPoint(x: 2560, y: 500))
        #expect(geometry.clamp(CGPoint(x: 9000, y: 500)) == CGPoint(x: 4480, y: 500))
    }

    // MARK: Snap

    @Test func snapRoundsToHalfPointsAtTwoXAndWholePointsAtOneX() {
        #expect(Self.twoX.snapX(10.3) == 10.5)
        #expect(Self.twoX.snapX(10.2) == 10)
        #expect(Self.twoX.snapY(99.76) == 100)
        #expect(Self.oneX.snapX(10.3) == 10)
        #expect(Self.oneX.snapX(10.6) == 11)
    }

    @Test func snapIsRelativeToTheDisplayCorner() {
        // 1.5x: the grid is every 2/3 point from the display's own corner.
        let fractional = SelectionGeometry(display: DisplayInfo(
            id: 4, frameTopLeft: CGRect(x: 1001, y: 0, width: 1500, height: 900), scale: 1.5
        ))
        let snapped = fractional.snapX(1001 + 1.0)
        #expect(abs(snapped - (1001 + 2.0 / 3.0)) < 1e-9 || abs(snapped - (1001 + 4.0 / 3.0)) < 1e-9)
    }

    @Test func snapRectSnapsEdgesNotSize() {
        let snapped = Self.twoX.snap(CGRect(x: 10.3, y: 20.3, width: 100.4, height: 50.1))
        #expect(snapped == CGRect(x: 10.5, y: 20.5, width: 100, height: 50))
    }

    // MARK: Dragging

    @Test func dragRectNormalizesAndSnaps() {
        let rect = Self.twoX.dragRect(anchor: CGPoint(x: 300.3, y: 200.3), pointer: CGPoint(x: 100.1, y: 100.1))
        #expect(rect == CGRect(x: 100, y: 100, width: 200.5, height: 100.5))
        let oneX = Self.oneX.dragRect(anchor: CGPoint(x: 300.3, y: 200.3), pointer: CGPoint(x: 100.1, y: 100.1))
        #expect(oneX == CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test func dragRectIsClampedToTheDisplayWhereItStarted() {
        // The secondary display spans x 2560 to 4480. Dragging left past its edge stops at 2560.
        let rect = Self.secondary.dragRect(anchor: CGPoint(x: 2700, y: 400), pointer: CGPoint(x: 2000, y: 2000))
        #expect(rect == CGRect(x: 2560, y: 400, width: 140, height: 680))
        let other = Self.twoX.dragRect(anchor: CGPoint(x: 2500, y: 100), pointer: CGPoint(x: 3500, y: 300))
        #expect(other.maxX == 2560)
    }

    @Test func shiftMakesASquareAtOneXAndTwoX() {
        let at2 = Self.twoX.dragRect(
            anchor: CGPoint(x: 100, y: 100), pointer: CGPoint(x: 160, y: 130), modifiers: .square
        )
        #expect(at2 == CGRect(x: 100, y: 100, width: 60, height: 60))
        let at1 = Self.oneX.dragRect(
            anchor: CGPoint(x: 400, y: 400), pointer: CGPoint(x: 380, y: 300), modifiers: .square
        )
        #expect(at1 == CGRect(x: 300, y: 300, width: 100, height: 100))
    }

    @Test func squareStopsAtTheDisplayEdge() {
        let rect = Self.oneX.dragRect(
            anchor: CGPoint(x: 100, y: 1400), pointer: CGPoint(x: 600, y: 1440), modifiers: .square
        )
        #expect(rect.width == rect.height)
        #expect(rect.height == 40)
    }

    @Test func optionResizesFromTheCentre() {
        let rect = Self.twoX.dragRect(
            anchor: CGPoint(x: 500, y: 500), pointer: CGPoint(x: 540, y: 520), modifiers: .fromCenter
        )
        #expect(rect == CGRect(x: 460, y: 480, width: 80, height: 40))
        let behind = Self.twoX.dragRect(
            anchor: CGPoint(x: 500, y: 500), pointer: CGPoint(x: 460, y: 480), modifiers: .fromCenter
        )
        #expect(behind == rect)
    }

    @Test func optionAndShiftTogetherGiveACentredSquare() {
        let rect = Self.oneX.dragRect(
            anchor: CGPoint(x: 500, y: 500), pointer: CGPoint(x: 540, y: 520), modifiers: [.fromCenter, .square]
        )
        #expect(rect == CGRect(x: 460, y: 460, width: 80, height: 80))
    }

    @Test func centredSelectionStaysCentredNearAnEdge() {
        let rect = Self.oneX.dragRect(
            anchor: CGPoint(x: 30, y: 700), pointer: CGPoint(x: 200, y: 710), modifiers: .fromCenter
        )
        #expect(rect.minX == 0)
        #expect(rect.maxX == 60)
        #expect(rect.height == 20)
    }

    // MARK: Nudge and resize

    @Test func arrowKeysNudgeOnePointAndShiftArrowTen() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        for geometry in [Self.oneX, Self.twoX] {
            #expect(geometry.nudged(rect, .right) == CGRect(x: 101, y: 100, width: 200, height: 100))
            #expect(geometry.nudged(rect, .left) == CGRect(x: 99, y: 100, width: 200, height: 100))
            #expect(geometry.nudged(rect, .up, large: true) == CGRect(x: 100, y: 90, width: 200, height: 100))
            #expect(geometry.nudged(rect, .down, large: true) == CGRect(x: 100, y: 110, width: 200, height: 100))
        }
    }

    @Test func nudgeStopsAtTheDisplayEdgeAndKeepsItsSize() {
        let rect = CGRect(x: 2, y: 2, width: 200, height: 100)
        let moved = Self.twoX.nudged(rect, .left, large: true)
        #expect(moved == CGRect(x: 0, y: 2, width: 200, height: 100))
        let atRight = CGRect(x: 2360, y: 500, width: 200, height: 100)
        #expect(Self.twoX.nudged(atRight, .right) == atRight)
    }

    @Test func commandArrowResizesByOnePointFromTheTopLeftCorner() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        for geometry in [Self.oneX, Self.twoX] {
            #expect(geometry.resized(rect, .right) == CGRect(x: 100, y: 100, width: 201, height: 100))
            #expect(geometry.resized(rect, .left) == CGRect(x: 100, y: 100, width: 199, height: 100))
            #expect(geometry.resized(rect, .down, large: true) == CGRect(x: 100, y: 100, width: 200, height: 110))
            #expect(geometry.resized(rect, .up, large: true) == CGRect(x: 100, y: 100, width: 200, height: 90))
        }
    }

    @Test func commandArrowNeverShrinksBelowOnePixelOrGrowsPastTheDisplay() {
        let tiny = CGRect(x: 10, y: 10, width: 3, height: 3)
        #expect(Self.twoX.resized(tiny, .left, large: true).width == 0.5)
        #expect(Self.oneX.resized(tiny, .up, large: true).height == 1)
        let nearEdge = CGRect(x: 3400, y: 100, width: 30, height: 30)
        #expect(Self.oneX.resized(nearEdge, .right, large: true).maxX == 3440)
    }

    // MARK: Click rule

    @Test func selectionsUnderFourPointsCountAsAClick() {
        let geometry = Self.twoX
        #expect(geometry.isClick(CGRect(x: 10, y: 10, width: 0, height: 0)))
        #expect(geometry.isClick(CGRect(x: 10, y: 10, width: 3.5, height: 3.5)))
        #expect(geometry.isClick(CGRect(x: 10, y: 10, width: 3, height: 200)))
        #expect(geometry.isClick(CGRect(x: 10, y: 10, width: 200, height: 2)))
        #expect(geometry.isClick(CGRect(x: 10, y: 10, width: 4, height: 4)) == false)
        #expect(Self.oneX.isClick(CGRect(x: 10, y: 10, width: 4, height: 400)) == false)
    }

    // MARK: Crop

    @Test func cropRectConvertsPointsToDisplayLocalPixelsAtTwoX() {
        let crop = Self.twoX.cropRect(for: CGRect(x: 10.5, y: 20, width: 100, height: 50))
        #expect(crop == CGRect(x: 21, y: 40, width: 200, height: 100))
    }

    @Test func cropRectEqualsPointsAtOneX() {
        let crop = Self.oneX.cropRect(for: CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(crop == CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    @Test func cropRectIsRelativeToTheDisplayOnASecondDisplay() {
        let crop = Self.secondary.cropRect(for: CGRect(x: 2560 + 10, y: 20, width: 100, height: 50))
        #expect(crop == CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    @Test func cropRectOfTheWholeDisplayIsTheWholeImage() {
        #expect(Self.twoX.cropRect(for: Self.twoX.bounds) == CGRect(x: 0, y: 0, width: 5120, height: 2880))
        #expect(Self.oneX.cropRect(for: Self.oneX.bounds) == CGRect(x: 0, y: 0, width: 3440, height: 1440))
    }

    @Test func cropRectIsClampedToTheImage() {
        let crop = Self.twoX.cropRect(for: CGRect(x: 2500, y: 1400, width: 200, height: 200))
        #expect(crop == CGRect(x: 5000, y: 2800, width: 120, height: 80))
    }

    @Test func cropRectRoundsEachEdgeSoNeighboursTile() {
        let geometry = Self.oneX
        let left = geometry.cropRect(for: CGRect(x: 0, y: 0, width: 10.5, height: 10))
        let right = geometry.cropRect(for: CGRect(x: 10.5, y: 0, width: 10, height: 10))
        #expect(left.maxX == right.minX)
    }

    @Test func dragThenCropGivesTheExpectedPixelSize() {
        let drag = Self.twoX.dragRect(anchor: CGPoint(x: 100, y: 100), pointer: CGPoint(x: 400.4, y: 250.2))
        let crop = Self.twoX.cropRect(for: drag)
        #expect(crop.width == drag.width * 2)
        #expect(crop.height == drag.height * 2)
        #expect(crop.width == crop.width.rounded())
    }

    // MARK: Space move

    @Test func spaceMovesTheSelectionAndTheAnchorFollows() {
        var drag = SelectionDrag(start: CGPoint(x: 100, y: 100), geometry: Self.oneX)
        drag.update(pointer: CGPoint(x: 200, y: 150))
        #expect(drag.rect == CGRect(x: 100, y: 100, width: 100, height: 50))

        drag.update(pointer: CGPoint(x: 300, y: 300), moving: true)
        #expect(drag.rect == CGRect(x: 200, y: 250, width: 100, height: 50))
        #expect(drag.anchor == CGPoint(x: 200, y: 250))

        // Space released: the drag resizes from the moved anchor.
        drag.update(pointer: CGPoint(x: 320, y: 310))
        #expect(drag.rect == CGRect(x: 200, y: 250, width: 120, height: 60))
    }

    @Test func spaceMoveStopsAtTheEdgeAndKeepsTheSize() {
        var drag = SelectionDrag(start: CGPoint(x: 2400, y: 100), geometry: Self.twoX)
        drag.update(pointer: CGPoint(x: 2500, y: 200))
        drag.update(pointer: CGPoint(x: 2900, y: 200), moving: true)
        #expect(drag.rect == CGRect(x: 2460, y: 100, width: 100, height: 100))
        #expect(drag.rect.size == CGSize(width: 100, height: 100))
    }

    @Test func spaceMoveAtTwoXKeepsTheRectOnThePixelGrid() {
        var drag = SelectionDrag(start: CGPoint(x: 100, y: 100), geometry: Self.twoX)
        drag.update(pointer: CGPoint(x: 150.5, y: 150.5))
        drag.update(pointer: CGPoint(x: 160.3, y: 160.3), moving: true)
        #expect(drag.rect.minX * 2 == (drag.rect.minX * 2).rounded())
        #expect(drag.rect.width == 50.5)
    }

    @Test func slowSpaceMoveAddsUpSubPixelSteps() {
        for geometry in [Self.oneX, Self.twoX] {
            var drag = SelectionDrag(start: CGPoint(x: 100, y: 100), geometry: geometry)
            drag.update(pointer: CGPoint(x: 200, y: 200))
            let start = drag.rect
            var pointer = CGPoint(x: 200, y: 200)
            for _ in 0..<20 {
                pointer.x += 0.3
                drag.update(pointer: pointer, moving: true)
            }
            // 20 x 0.3 pt is 6 pt; the rect stays on the pixel grid, so within one pixel of it.
            #expect(abs(drag.rect.minX - start.minX - 6) <= geometry.pixel)
            #expect(drag.rect.size == start.size)
        }
    }

    @Test func movedCarriesTheRemainderPastAnEdge() {
        let rect = CGRect(x: 3300, y: 100, width: 100, height: 100)
        let move = Self.oneX.moved(rect, from: CGPoint(x: 3350, y: 150), to: CGPoint(x: 3450, y: 150))
        #expect(move.rect.minX == 3340)
        // The 60 pt the edge swallowed stay with the pointer, so coming back starts from there.
        #expect(move.last == CGPoint(x: 3390, y: 150))
    }

    @Test func dragStateAppliesModifiersEachUpdate() {
        var drag = SelectionDrag(start: CGPoint(x: 100, y: 100), geometry: Self.oneX)
        drag.update(pointer: CGPoint(x: 180, y: 140), modifiers: .square)
        #expect(drag.rect == CGRect(x: 100, y: 100, width: 80, height: 80))
        drag.update(pointer: CGPoint(x: 180, y: 140))
        #expect(drag.rect == CGRect(x: 100, y: 100, width: 80, height: 40))
    }
}
