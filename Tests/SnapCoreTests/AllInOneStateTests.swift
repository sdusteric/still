import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct AllInOneStateTests {
    let displays = DisplayInfo.fakeSideBySide
    let stored = CGRect(x: 330, y: 150, width: 640, height: 400)

    @Test func theLastAreaIsRestoredExactlyOnTheSameDisplayLayout() throws {
        let area = try #require(LastArea.store(stored, displays: displays))
        #expect(area.displayID == 1)
        #expect(area.displayFrame == DisplayInfo.fake5K.frameTopLeft)
        let state = AllInOneState(lastArea: area, displays: displays)
        #expect(state.area == stored)
        #expect(state.restoredArea)

        let onUltrawide = try #require(LastArea.store(CGRect(x: 3000, y: 100, width: 500, height: 300), displays: displays))
        #expect(onUltrawide.displayID == 2)
    }

    @Test func aChangedDisplayFingerprintDropsTheLastArea() throws {
        let area = try #require(LastArea.store(stored, displays: displays))
        var resized = displays
        resized[0].frameTopLeft = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(AllInOneState(lastArea: area, displays: resized).area == nil)

        var renumbered = displays
        renumbered[0].id = 9
        #expect(AllInOneState(lastArea: area, displays: renumbered).area == nil)
        #expect(AllInOneState(lastArea: area, displays: []).area == nil)
        #expect(AllInOneState(lastArea: nil, displays: displays).restoredArea == false)
    }

    @Test func numberKeysPickTheTargetAndTabTogglesAreaAndWindow() {
        var state = AllInOneState()
        #expect(state.target == .area)
        #expect(state.handle(.two) == .changed)
        #expect(state.target == .window)
        #expect(state.handle(.two) == .none)
        #expect(state.handle(.three) == .changed)
        #expect(state.target == .fullscreen)
        #expect(state.handle(.one) == .changed)
        #expect(state.target == .area)
        #expect(state.handle(.tab) == .changed)
        #expect(state.target == .window)
        #expect(state.handle(.tab) == .changed)
        #expect(state.target == .area)
        _ = state.handle(.three)
        _ = state.handle(.tab)
        #expect(state.target == .window, "Tab from Fullscreen goes to Window")
    }

    @Test func rTogglesTheModeAndTheFrozenLayerFollowsIt() {
        var state = AllInOneState()
        #expect(state.mode == .screenshot)
        #expect(state.showsFrozenLayer)
        #expect(state.needsFrozenCapture)
        #expect(state.primaryTitle == "Capture")
        #expect(state.handle(.r) == .changed)
        #expect(state.mode == .record)
        #expect(state.showsFrozenLayer == false)
        #expect(state.needsFrozenCapture == false)
        #expect(state.primaryTitle == "Record")
        #expect(state.handle(.r) == .changed)
        #expect(state.showsFrozenLayer)
        #expect(HUDKey(character: "R") == .r)
        #expect(HUDKey(character: "1") == .one)
        #expect(HUDKey(character: "\u{1B}") == .escape)
        #expect(HUDKey(character: "x") == nil)
    }

    @Test func returnConfirmsOnlyWithAnAreaAndEscCancels() {
        var state = AllInOneState()
        #expect(state.handle(.returnKey) == .none, "no area yet")
        state.setArea(stored)
        #expect(state.handle(.returnKey) == .confirm)
        #expect(state.handle(.escape) == .cancel)
        var window = AllInOneState(target: .window)
        #expect(window.handle(.returnKey) == .confirm)
    }

    @Test func arrowsNudgeTheAreaAndEditingClearsTheRestoredFlag() throws {
        let area = try #require(LastArea.store(stored, displays: displays))
        var state = AllInOneState(lastArea: area, displays: displays)
        #expect(state.handle(.arrow(dx: 1, dy: 0)) == .changed)
        #expect(state.handle(.arrow(dx: 0, dy: -10)) == .changed)
        #expect(state.area == stored.offsetBy(dx: 1, dy: -10))
        state.setArea(CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(state.restoredArea == false)
        var window = AllInOneState(target: .window)
        #expect(window.handle(.arrow(dx: 1, dy: 0)) == .none)
    }

    @Test func theToolbarSitsAtTheBottomUnlessTheAreaWouldBeUnderIt() {
        let display = VisibleDisplay(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 0, y: 24, width: 1280, height: 776)
        )
        let size = CGSize(width: 560, height: 44)
        let bottom = AllInOneState.toolbarFrame(size: size, display: display, area: stored)
        #expect(bottom.edge == .bottom)
        #expect(bottom.frame == CGRect(x: 360, y: 800 - 28 - 44, width: 560, height: 44))

        let low = CGRect(x: 300, y: 500, width: 700, height: 260)
        let top = AllInOneState.toolbarFrame(size: size, display: display, area: low)
        #expect(top.edge == .top)
        #expect(top.frame == CGRect(x: 360, y: 24 + 28, width: 560, height: 44))
        #expect(AllInOneState.toolbarFrame(size: size, display: display, area: nil).edge == .bottom)
    }

    @Test func settingsMigrationMovesTheDefaultCommandShift5ToAllInOne() throws {
        let json = #"{"version": 1, "shortcuts": {"captureArea": {"keyCode": 21, "modifiers": 768}}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.shortcuts.allInOne == .commandShift5)
        #expect(settings.shortcuts.captureWindow == nil)
    }
}
