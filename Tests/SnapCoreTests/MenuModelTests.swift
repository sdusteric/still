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
            originalURL: URL(filePath: "/tmp/history/\(name)/Snap \(name).png")
        )
    }

    let now = MenuModelTests.date(hour: 14, minute: 5)

    private func model(
        recent: [CaptureItem] = [], permissionNeeded: Bool = false, plan: HotkeyPlan? = nil,
        shortcuts: ShortcutSettings = ShortcutSettings()
    ) -> MenuModel {
        MenuModel(MenuInput(
            shortcuts: shortcuts, recentCaptures: recent, permissionNeeded: permissionNeeded, plan: plan,
            now: now, timeZone: Self.zone
        ))
    }

    @Test func itemsFollowTheDesignOrder() {
        let ids = model().items.map(\.id)
        #expect(ids == [
            .captureArea, .captureWindow, .captureFullscreen, .separator(1),
            .applyBackground, .openInAnnotate, .separator(2),
            .recentCapturesHeader, .noRecentCaptures, .openHistoryFolder, .separator(3),
            .settings, .quit,
        ])
    }

    @Test func titlesAndKeyEquivalents() {
        let menu = model()
        #expect(menu.item(.captureArea)?.title == "Capture Area")
        #expect(menu.item(.captureArea)?.keyEquivalent == MenuKeyEquivalent(key: "4", command: true, shift: true))
        #expect(menu.item(.captureWindow)?.shortcutText == "\u{21E7}\u{2318}5")
        #expect(menu.item(.captureFullscreen)?.shortcutText == "\u{21E7}\u{2318}3")
        #expect(menu.item(.applyBackground)?.title == "Apply Background to Last Capture")
        #expect(menu.item(.applyBackground)?.keyEquivalent == nil)
        #expect(menu.item(.openInAnnotate)?.title == "Open Last Capture in Annotate")
        #expect(menu.item(.settings)?.keyEquivalent == MenuKeyEquivalent(key: ",", command: true))
        #expect(menu.item(.quit)?.title == "Quit Snap")
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
        #expect(recents[0].title == "Snap c0")
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
        #expect(menu.item(.openHistoryFolder)?.isEnabled == true)
    }

    @Test func statusLineAppearsOnlyWhenSomethingNeedsAttention() {
        #expect(model().item(.status) == nil)

        let permission = model(permissionNeeded: true)
        #expect(permission.item(.status)?.title == "Screen Recording permission needed")
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
        let history = ids.firstIndex(of: .openHistoryFolder)
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
