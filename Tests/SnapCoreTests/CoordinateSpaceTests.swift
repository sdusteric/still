import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct CoordinateSpaceTests {
    /// The 5K panel (2560x1440 points, scale 2) as primary and a shorter 1920x1080 scale 1 display
    /// to its right, top-aligned in top-left space. Its NSScreen frame sits 360 points up from the
    /// bottom edge: 1440 - 1080.
    static let primary = DisplayInfo(id: 1, frameTopLeft: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2)
    static let rightOfPrimary = DisplayInfo(
        id: 2, frameTopLeft: CGRect(x: 2560, y: 0, width: 1920, height: 1080), scale: 1
    )
    /// A display above the primary one: negative y in top-left space.
    static let abovePrimary = DisplayInfo(
        id: 3, frameTopLeft: CGRect(x: 0, y: -1080, width: 1920, height: 1080), scale: 1
    )

    @Test func primaryHeightComesFromTheDisplayAtTheOrigin() {
        let reordered = [Self.rightOfPrimary, Self.primary]
        #expect(CoordinateSpace(displays: reordered).primaryHeight == 1440)
        #expect(CoordinateSpace(displays: DisplayInfo.fakeSideBySide).primaryHeight == 1440)
        #expect(CoordinateSpace(displays: [DisplayInfo.fakeUltrawide]).primaryHeight == 1440)
        #expect(CoordinateSpace(displays: []).primaryHeight == 0)
    }

    @Test func primaryDisplayFlipsWithItsOwnHeight() {
        let space = CoordinateSpace(displays: [Self.primary])
        let screenFrame = space.screenFrame(of: Self.primary)
        #expect(screenFrame == CGRect(x: 0, y: 0, width: 2560, height: 1440))

        let bottomLeft = CGRect(x: 100, y: 200, width: 300, height: 400)
        // y_cg = 1440 - (200 + 400)
        #expect(space.topLeft(fromBottomLeft: bottomLeft) == CGRect(x: 100, y: 840, width: 300, height: 400))
    }

    @Test func shorterSecondDisplayIsFlippedAgainstThePrimaryHeight() {
        let space = CoordinateSpace(displays: [Self.primary, Self.rightOfPrimary])
        let screenFrame = space.screenFrame(of: Self.rightOfPrimary)
        #expect(screenFrame == CGRect(x: 2560, y: 360, width: 1920, height: 1080))
        #expect(space.topLeft(fromBottomLeft: screenFrame) == Self.rightOfPrimary.frameTopLeft)
    }

    @Test func displayAbovePrimaryHasNegativeTopLeftYAndPositiveScreenY() {
        let space = CoordinateSpace(displays: [Self.primary, Self.abovePrimary])
        let screenFrame = space.screenFrame(of: Self.abovePrimary)
        #expect(screenFrame == CGRect(x: 0, y: 1440, width: 1920, height: 1080))
        #expect(space.topLeft(fromBottomLeft: screenFrame).minY == -1080)
    }

    @Test func rectFlipRoundTripsOnEveryDisplay() {
        let displays = [Self.primary, Self.rightOfPrimary, Self.abovePrimary]
        let space = CoordinateSpace(displays: displays)
        for display in displays {
            let rect = display.frameTopLeft.insetBy(dx: 13.5, dy: 7.25)
            #expect(space.topLeft(fromBottomLeft: space.bottomLeft(fromTopLeft: rect)) == rect)
        }
    }

    @Test func pointFlipUsesThePrimaryHeight() {
        let space = CoordinateSpace(primaryHeight: 1440)
        #expect(space.topLeft(fromBottomLeft: CGPoint(x: 10, y: 1440)) == CGPoint(x: 10, y: 0))
        #expect(space.bottomLeft(fromTopLeft: CGPoint(x: 10, y: 0)) == CGPoint(x: 10, y: 1440))
        #expect(space.bottomLeft(fromTopLeft: CGPoint(x: 5, y: -100)) == CGPoint(x: 5, y: 1540))
    }

    @Test func displayContainingPointUsesHalfOpenFrames() {
        let displays = [Self.primary, Self.rightOfPrimary]
        #expect(CoordinateSpace.display(containing: CGPoint(x: 100, y: 100), in: displays)?.id == 1)
        #expect(CoordinateSpace.display(containing: CGPoint(x: 2559.5, y: 100), in: displays)?.id == 1)
        #expect(CoordinateSpace.display(containing: CGPoint(x: 2560, y: 100), in: displays)?.id == 2)
        // Below the shorter display, past its bottom edge: on no display.
        #expect(CoordinateSpace.display(containing: CGPoint(x: 3000, y: 1200), in: displays) == nil)
    }

    @Test func nearestDisplayFallsBackToTheClosestEdge() {
        let displays = [Self.primary, Self.rightOfPrimary]
        #expect(CoordinateSpace.nearestDisplay(to: CGPoint(x: 3000, y: 1200), in: displays)?.id == 2)
        #expect(CoordinateSpace.nearestDisplay(to: CGPoint(x: -50, y: 700), in: displays)?.id == 1)
        #expect(CoordinateSpace.nearestDisplay(to: .zero, in: []) == nil)
    }

    @Test func displayMostlyContainingARectPicksTheLargerOverlap() {
        let displays = [Self.primary, Self.rightOfPrimary]
        let straddling = CGRect(x: 2500, y: 100, width: 300, height: 200)
        #expect(CoordinateSpace.display(mostlyContaining: straddling, in: displays)?.id == 2)
        let mostlyLeft = CGRect(x: 2300, y: 100, width: 300, height: 200)
        #expect(CoordinateSpace.display(mostlyContaining: mostlyLeft, in: displays)?.id == 1)
        #expect(CoordinateSpace.display(mostlyContaining: CGRect(x: 9000, y: 0, width: 10, height: 10), in: displays) == nil)
    }

    @Test func localRectIsRelativeToTheDisplayCorner() {
        let rect = CGRect(x: 2600, y: 40, width: 100, height: 50)
        let local = CoordinateSpace.localRect(rect, in: Self.rightOfPrimary)
        #expect(local == CGRect(x: 40, y: 40, width: 100, height: 50))
        #expect(CoordinateSpace.globalRect(fromLocal: local, in: Self.rightOfPrimary) == rect)
    }

    @Test func viewRectFlipsWithinTheDisplayHeightAtOneAndTwoTimes() {
        // 2x primary: a rect 100 from the top, 300 high, in a 1440-high view.
        let atTwo = CGRect(x: 20, y: 100, width: 400, height: 300)
        let viewTwo = CoordinateSpace.viewRect(fromGlobal: atTwo, in: Self.primary)
        #expect(viewTwo == CGRect(x: 20, y: 1040, width: 400, height: 300))
        #expect(CoordinateSpace.globalRect(fromView: viewTwo, in: Self.primary) == atTwo)

        // 1x secondary at x 2560: view height 1080.
        let atOne = CGRect(x: 2560 + 20, y: 100, width: 400, height: 300)
        let viewOne = CoordinateSpace.viewRect(fromGlobal: atOne, in: Self.rightOfPrimary)
        #expect(viewOne == CGRect(x: 20, y: 680, width: 400, height: 300))
        #expect(CoordinateSpace.globalRect(fromView: viewOne, in: Self.rightOfPrimary) == atOne)
    }

    @Test func viewPointRoundTripsOnADisplayAboveThePrimary() {
        let point = CGPoint(x: 300, y: -1000)
        let view = CoordinateSpace.viewPoint(fromGlobal: point, in: Self.abovePrimary)
        #expect(view == CGPoint(x: 300, y: 1000))
        #expect(CoordinateSpace.globalPoint(fromView: view, in: Self.abovePrimary) == point)
    }

    @Test func ultrawideAndFiveKSideBySideShareTheTopLeftSpace() {
        let displays = DisplayInfo.fakeSideBySide
        let space = CoordinateSpace(displays: displays)
        // Both are 1440 points tall, so their screen frames are top-aligned with the same y.
        #expect(space.screenFrame(of: displays[1]) == CGRect(x: 2560, y: 0, width: 3440, height: 1440))
    }
}
