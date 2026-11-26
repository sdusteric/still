import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct MenuModelTests {
    static let zone = TimeZone(identifier: "Europe/Paris") ?? .gmt
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func date(day: Int = 24, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static func capture(_ name: String, at date: Date, mode: CaptureMode = .area) -> CaptureItem {
        CaptureItem(
            id: name, createdAt: date, mode: mode, scale: 2,
            originalURL: URL(filePath: "/tmp/history/\(name)/Still \(name).png")
        )
    }

    let now = MenuModelTests.date(hour: 14, minute: 5)

    static func recording(_ name: String, at date: Date, duration: Double?) -> CaptureItem {
        CaptureItem(
            id: name, createdAt: date, mode: .area, scale: 2,
            originalURL: URL(filePath: "/tmp/history/\(name)/Still \(name).mp4"), kind: .video, durationSeconds: duration
        )
    }

    private func model(
        recent: [CaptureItem] = [], permissionNeeded: Bool = false, plan: HotkeyPlan? = nil,
        shortcuts: ShortcutSettings = ShortcutSettings(), pins: [PinnedCaptureEntry] = [], isRecording: Bool = false
    ) -> MenuModel {
        MenuModel(MenuInput(
            shortcuts: shortcuts, recentCaptures: recent, permissionNeeded: permissionNeeded, plan: plan,
            pins: pins, isRecording: isRecording, now: now, timeZone: Self.zone
        ))
    }

    @Test func aStaleGrantOffersRelaunchUnderTheStatusLine() {
        let menu = MenuModel(MenuInput(permissionNeeded: true, offersRelaunch: true, now: now, timeZone: Self.zone))
        let ids = menu.items.map(\.id)
        let status = try? #require(ids.firstIndex(of: .status))
        #expect(status.map { ids[$0 + 1] } == .relaunch)
        #expect(menu.item(.relaunch)?.title == "Relaunch Still")
        #expect(model(permissionNeeded: true).item(.relaunch) == nil)
    }

    @Test func scrollingCaptureIsInTheCaptureGroupWithItsShortcut() {
        var shortcuts = ShortcutSettings()
        shortcuts.captureScrolling = KeyShortcut(keyCode: 1, modifiers: KeyShortcut.Modifier.command | KeyShortcut.Modifier.shift)
        let item = model(shortcuts: shortcuts).item(.captureScrolling)
        #expect(item?.title == "Capture Scrolling Area")
        #expect(item?.isEnabled == true)
        #expect(item?.shortcutText != nil)
        #expect(MenuItemID.captureScrolling.shortcutAction == .captureScrolling)
        #expect(ShortcutAction.allCases.last == .captureScrolling, "new actions go last so hotkey ids keep their numbers")
    }

    @Test func capturePreviousAreaNeedsAStoredArea() {
        let without = model()
        #expect(without.item(.capturePreviousArea)?.isEnabled == false)
        let with = MenuModel(MenuInput(hasPreviousArea: true, now: now, timeZone: Self.zone))
        #expect(with.item(.capturePreviousArea)?.isEnabled == true)
        #expect(with.item(.capturePreviousArea)?.title == "Capture Previous Area")
        #expect(MenuItemID.capturePreviousArea.shortcutAction == .capturePreviousArea)
    }

    @Test func openClipboardImageIsTheOptionAlternateOfOpenImage() {
        #expect(model().item(.openClipboardImage) == nil, "no image: Option keeps Open Image")
        let menu = MenuModel(MenuInput(hasClipboardImage: true, now: now, timeZone: Self.zone))
        let ids = menu.items.map(\.id)
        #expect(ids.firstIndex(of: .openClipboardImage) == ids.firstIndex(of: .openImage).map { $0 + 1 })
        #expect(menu.item(.openClipboardImage)?.isAlternate == true)
        #expect(menu.item(.openClipboardImage)?.isEnabled == true)
        #expect(menu.item(.openImage)?.title == "Open Image\u{2026}")
        #expect(menu.item(.openClipboardImage)?.title == "Open Clipboard Image")
    }

    @Test func lastCaptureActionsLiveInOneSubmenu() throws {
        let menu = model(recent: [Self.capture("a", at: now)])
        let parent = try #require(menu.items.first { $0.id == .lastCapture })
        #expect(parent.title == "Last Capture")
        #expect(parent.isEnabled)
        #expect(parent.children.map(\.id) == [.applyBackground, .openInAnnotate, .pinLastCapture, .copyLastCaptureText])
        #expect(parent.children.map(\.title) == ["Apply Background", "Open in Annotate", "Pin to Screen", "Copy Text"])
        #expect(menu.item(.pinLastCapture)?.isEnabled == true, "item(_:) finds submenu rows")
        #expect(model().items.first { $0.id == .lastCapture }?.isEnabled == false, "no capture yet")
    }

    @Test func actionRowsCarryASymbol() {
        let menu = model()
        for id in [MenuItemID.captureArea, .captureWindow, .captureFullscreen, .captureScrolling, .capturePreviousArea,
                   .allInOne, .recordScreen, .lastCapture, .captureHistory, .openImage, .settings, .quit] {
            #expect(menu.item(id)?.symbolName != nil, "\(id)")
        }
    }

    @Test func itemsFollowTheDesignOrder() {
        // Design 20.10: the capture group with All-in-One and Record Screen, the last-capture group
        // with Pin, then Recent Captures and Capture History.
        let ids = model().items.map(\.id)
        #expect(ids == [
            .captureArea, .captureWindow, .captureFullscreen, .captureScrolling, .capturePreviousArea, .allInOne, .recordScreen,
            .separator(1), .lastCapture, .separator(2),
            .recentCapturesHeader, .noRecentCaptures, .captureHistory, .openImage, .separator(3),
            .settings, .quit,
        ])
        #expect(model().item(.openHistoryFolder) == nil)
    }

    @Test func m2TitlesAndShortcuts() {
        let menu = model()
        #expect(menu.item(.allInOne)?.title == "All-in-One\u{2026}")
        #expect(menu.item(.allInOne)?.shortcutText == "\u{21E7}\u{2318}5")
        #expect(menu.item(.allInOne)?.keyEquivalent == MenuKeyEquivalent(key: "5", command: true, shift: true))
        #expect(menu.item(.recordScreen)?.title == "Record Screen\u{2026}")
        #expect(menu.item(.recordScreen)?.keyEquivalent == nil)
        #expect(menu.item(.pinLastCapture)?.title == "Pin to Screen")
        #expect(menu.item(.captureHistory)?.title == "Capture History\u{2026}")
        #expect(menu.item(.captureHistory)?.isEnabled == true)
    }

    @Test func recordScreenReadsStopRecordingWhileRecording() {
        let menu = model(isRecording: true)
        #expect(menu.item(.recordScreen)?.title == "Stop Recording")
        #expect(menu.item(.recordScreen)?.shortcutText == "\u{21E7}\u{2318}5")
        var shortcuts = ShortcutSettings()
        shortcuts.stopRecording = KeyShortcut(keyCode: 1, modifiers: KeyShortcut.Modifier.control | KeyShortcut.Modifier.option)
        #expect(model(shortcuts: shortcuts, isRecording: true).item(.recordScreen)?.shortcutText == "\u{2303}\u{2325}S")
    }

    @Test func recordingsInRecentCapturesShowTheirDuration() {
        let captures = [
            Self.capture("a", at: Self.date(hour: 14, minute: 3).addingTimeInterval(22)),
            Self.recording("b", at: Self.date(hour: 11, minute: 48).addingTimeInterval(9), duration: 42.4),
            Self.recording("c", at: Self.date(hour: 9, minute: 15).addingTimeInterval(40), duration: nil),
        ]
        let menu = model(recent: captures)
        #expect(menu.item(.recentCapture("a"))?.title == "Screenshot 14.03.22")
        #expect(menu.item(.recentCapture("b"))?.title == "Recording 11.48.09 \u{00B7} 0:42")
        #expect(menu.item(.recentCapture("b"))?.subtitle == "Today, 11:48")
        #expect(menu.item(.recentCapture("c"))?.title == "Recording 09.15.40")
        let long = Self.recording("d", at: now, duration: 3725)
        #expect(MenuModel.recentTitle(long, timeZone: Self.zone).hasSuffix("\u{00B7} 1:02:05"))
    }

    @Test func pinLastCaptureNeedsAScreenshot() {
        #expect(model().item(.pinLastCapture)?.isEnabled == false)
        #expect(model(recent: [Self.capture("a", at: now)]).item(.pinLastCapture)?.isEnabled == true)
        // Recordings cannot be pinned in M2 (design 20.2).
        #expect(model(recent: [Self.recording("v", at: now, duration: 4)]).item(.pinLastCapture)?.isEnabled == false)
    }

    @Test func pinnedCapturesSubmenuListsEachPinWithUnlockAndClose() throws {
        #expect(model().item(.pinnedCaptures) == nil)
        let pins = [
            PinnedCaptureEntry(id: 1, itemID: "a", createdAt: Self.date(hour: 13, minute: 0), clickThrough: false),
            PinnedCaptureEntry(id: 2, itemID: "b", createdAt: Self.date(hour: 13, minute: 30), clickThrough: true),
        ]
        let menu = model(pins: pins)
        let ids = menu.items.map(\.id)
        let history = try #require(ids.firstIndex(of: .captureHistory))
        #expect(ids[history + 1] == .pinnedCaptures)
        let pinned = try #require(menu.item(.pinnedCaptures))
        #expect(pinned.title == "Pinned Captures (2)")
        let children = pinned.children.filter { $0.kind != .separator }
        #expect(children.map(\.id) == [
            .pinnedCapture(1), .unlockPin(1), .closePin(1), .pinnedCapture(2), .unlockPin(2), .closePin(2), .closeAllPins,
        ])
        #expect(children[0].captureID == "a")
        #expect(children[0].title == "Pinned 13.00.00")
        // Unlock applies only to a click-through pin.
        #expect(children[1].isEnabled == false)
        #expect(children[4].isEnabled == true)
        #expect(children[1].indented && children[2].indented)
        #expect(children.last?.title == "Close All Pins")
    }

    @Test func recordingMenuHasStopCancelAndThreeInformationRows() {
        let menu = RecordingMenuModel(RecordingMenuInput(
            target: .area, size: CGSize(width: 640, height: 400), fps: 30, format: .h264,
            microphoneName: "MacBook Pro Microphone", systemAudio: false, stopShortcut: .commandShift5
        ))
        #expect(menu.items.map(\.id) == [
            .stopRecording, .cancelRecording, .separator(1), .recordingInfo(0), .recordingInfo(1), .recordingInfo(2),
        ])
        #expect(menu.item(.stopRecording)?.shortcutText == "\u{21E7}\u{2318}5")
        #expect(menu.item(.recordingInfo(0))?.title == "Area 640 \u{00D7} 400, 30 fps, H.264")
        #expect(menu.item(.recordingInfo(1))?.title == "MacBook Pro Microphone")
        #expect(menu.item(.recordingInfo(2))?.title == "System audio off")
        #expect(menu.items.filter { $0.kind == .info }.allSatisfy { !$0.isEnabled && $0.symbolName != nil })

        let quiet = RecordingMenuModel(RecordingMenuInput(
            target: .window, size: CGSize(width: 842, height: 516), fps: 60, format: .hevc, systemAudio: true
        ))
        #expect(quiet.item(.recordingInfo(0))?.title == "Window 842 \u{00D7} 516, 60 fps, HEVC")
        #expect(quiet.item(.recordingInfo(1))?.title == "Microphone off")
        #expect(quiet.item(.recordingInfo(2))?.title == "System audio on")
        #expect(quiet.item(.stopRecording)?.shortcutText == nil, "no stop key is shown when none is set")
    }

    @Test func checkForUpdatesSitsAboveSettingsOnlyWithAnUpdater() {
        #expect(model().item(.checkForUpdates) == nil)
        let menu = MenuModel(MenuInput(offersUpdates: true, now: now, timeZone: Self.zone))
        let ids = menu.items.map(\.id)
        #expect(Array(ids.suffix(3)) == [.checkForUpdates, .settings, .quit])
        #expect(menu.item(.checkForUpdates)?.title == "Check for Updates\u{2026}")
        #expect(menu.item(.checkForUpdates)?.keyEquivalent == nil)
    }

    @Test func titlesAndKeyEquivalents() {
        let menu = model()
        #expect(menu.item(.captureArea)?.title == "Capture Area")
        #expect(menu.item(.captureArea)?.keyEquivalent == MenuKeyEquivalent(key: "4", command: true, shift: true))
        // M2: Cmd+Shift+5 belongs to All-in-One and Capture Window is unset by default (design D56).
        #expect(menu.item(.captureWindow)?.shortcutText == nil)
        #expect(menu.item(.captureFullscreen)?.shortcutText == "\u{21E7}\u{2318}3")
        #expect(menu.item(.applyBackground)?.title == "Apply Background")
        #expect(menu.item(.applyBackground)?.keyEquivalent == nil)
        #expect(menu.item(.openInAnnotate)?.title == "Open in Annotate")
        #expect(menu.item(.settings)?.keyEquivalent == MenuKeyEquivalent(key: ",", command: true))
        #expect(menu.item(.quit)?.title == "Quit Still")
        #expect(menu.item(.quit)?.keyEquivalent == MenuKeyEquivalent(key: "q", command: true))
    }

    @Test func menuShowsTheUsersOwnShortcuts() {
        var shortcuts = ShortcutSettings()
        shortcuts.captureArea = KeyShortcut(keyCode: 0, modifiers: KeyShortcut.Modifier.control)
        shortcuts.applyBackground = KeyShortcut(keyCode: 11, modifiers: KeyShortcut.Modifier.option)
        shortcuts.captureWindow = nil
        let menu = model(shortcuts: shortcuts)
        #expect(menu.item(.captureArea)?.shortcutText == "\u{2303}A")
        #expect(menu.item(.applyBackground)?.shortcutText == "\u{2325}B")
        #expect(menu.item(.captureWindow)?.keyEquivalent == nil)
        #expect(menu.item(.captureWindow)?.shortcutText == nil)
    }

    @Test func editingItemsNeedALastCapture() {
        #expect(model().item(.applyBackground)?.isEnabled == false)
        #expect(model().item(.openInAnnotate)?.isEnabled == false)
        let withCapture = model(recent: [Self.capture("a", at: now)])
        #expect(withCapture.item(.applyBackground)?.isEnabled == true)
        #expect(withCapture.item(.openInAnnotate)?.isEnabled == true)
        #expect(withCapture.item(.captureArea)?.isEnabled == true)
    }

    @Test func recentCapturesShowTheLastThreeNewestFirst() {
        let captures = (0..<5).map { index in
            Self.capture("c\(index)", at: now.addingTimeInterval(Double(-index) * 600))
        }
        let menu = model(recent: captures)
        let recents = menu.items.filter { if case .recentCapture = $0.id { true } else { false } }
        #expect(recents.map(\.captureID) == ["c0", "c1", "c2"])
        #expect(menu.item(.noRecentCaptures) == nil)
        #expect(recents[0].title == "Screenshot 14.05.00")
    }

    @Test func recentCapturesHaveRelativeSubtitles() {
        let captures = [
            Self.capture("a", at: now.addingTimeInterval(-120)),
            Self.capture("b", at: Self.date(hour: 11, minute: 48)),
            Self.capture("c", at: Self.date(day: 23, hour: 9, minute: 15)),
            Self.capture("d", at: Self.date(day: 20, hour: 16, minute: 30)),
        ]
        let menu = model(recent: captures)
        #expect(menu.item(.recentCapture("a"))?.subtitle == "2 minutes ago")
        #expect(menu.item(.recentCapture("b"))?.subtitle == "Today, 11:48")
        #expect(menu.item(.recentCapture("c"))?.subtitle == "Yesterday, 09:15")
        #expect(menu.item(.recentCapture("d")) == nil)
        #expect(MenuModel.relativeTime(captures[3].createdAt, now: now, timeZone: Self.zone) == "Oct 20, 16:30")
        #expect(MenuModel.relativeTime(now.addingTimeInterval(-10), now: now, timeZone: Self.zone) == "Just now")
        #expect(MenuModel.relativeTime(now.addingTimeInterval(-61), now: now, timeZone: Self.zone) == "1 minute ago")
    }

    @Test func emptyHistoryShowsADisabledPlaceholder() {
        let menu = model()
        #expect(menu.item(.noRecentCaptures)?.isEnabled == false)
        #expect(menu.item(.captureHistory)?.isEnabled == true)
    }

    @Test func statusLineAppearsOnlyWhenSomethingNeedsAttention() {
        #expect(model().item(.status) == nil)

        let permission = model(permissionNeeded: true)
        #expect(permission.item(.status)?.title == "Screen Recording needs your OK")
        #expect(permission.item(.status)?.isEnabled == true)
        #expect(permission.item(.status)?.kind == .status)

        let waitingPlan = HotkeyConflicts.evaluate(
            shortcuts: ShortcutSettings(), systemEntries: [],
            runningBundleIDs: [HotkeyConflicts.cleanShotBundleIDs.first ?? ""]
        )
        let waiting = model(plan: waitingPlan)
        #expect(waiting.item(.status)?.title == "Waiting for CleanShot X to quit")
        #expect(waiting.item(.status)?.isEnabled == false)
    }

    @Test func statusLineSitsBetweenHistoryAndSettings() {
        let ids = model(permissionNeeded: true).items.map(\.id)
        let history = ids.firstIndex(of: .captureHistory)
        let status = ids.firstIndex(of: .status)
        let settings = ids.firstIndex(of: .settings)
        #expect(history != nil && status != nil && settings != nil)
        #expect((history ?? 0) < (status ?? 0))
        #expect((status ?? 0) < (settings ?? 0))
    }

    @Test func separatorIDsAreUnique() {
        let ids = model(permissionNeeded: true).items.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
