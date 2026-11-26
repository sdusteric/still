import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

/// The M2 menu bar item (the red timer and its menu, Pinned Captures) and the Recording and
/// Shortcuts settings (design 20.6, 20.10). Menus are built without a status item, settings
/// without a window.
@MainActor
@Suite struct MenuSettingsM2Tests {
    @Test func anUnsetShortcutReadsNotSetAndHoverInvitesRecording() {
        #expect(ShortcutRecorder.label(shortcut: nil, isRecording: false, isHovering: false) == "Not set")
        #expect(ShortcutRecorder.label(shortcut: nil, isRecording: false, isHovering: true) == "Record Shortcut")
        #expect(ShortcutRecorder.label(shortcut: nil, isRecording: true, isHovering: true) == "Type Shortcut")
        #expect(ShortcutRecorder.label(shortcut: .commandShift4, isRecording: false, isHovering: true) == HotkeyCombo(.commandShift4).chipText)
    }

    @Test func theMenuReportsWhenItOpensAndCloses() {
        var tracking: [Bool] = []
        let controller = StatusMenuController(modelProvider: { MenuM2Demo.makeModel() })
        controller.onTrackingChanged = { tracking.append($0) }
        controller.menuWillOpen(controller.menu)
        controller.menuDidClose(controller.menu)
        #expect(tracking == [true, false])
        // A submenu opening is not the menu opening.
        controller.menuWillOpen(NSMenu(title: "Sub"))
        #expect(tracking == [true, false])
    }

    @Test func timerClickStopsAndOptionClickOpensTheRecordingMenu() throws {
        var chosen: [MenuItemID] = []
        let controller = StatusMenuController(
            modelProvider: { MenuM2Demo.makeModel() },
            recordingMenuProvider: { RecordingMenuModel(HUDDemo.recordingMenuInput) },
            onSelect: { chosen.append($0) },
            now: { 142 }
        )
        // Not recording: a click on the status item is the normal menu's job.
        #expect(controller.timerClicked(showsMenu: false) == nil)
        #expect(chosen.isEmpty)

        controller.setRecording(.recording(since: 100))
        #expect(controller.timerText == "0:42")
        #expect(controller.timerClicked(showsMenu: false) == nil)
        #expect(chosen == [.stopRecording])

        let menu = try #require(controller.timerClicked(showsMenu: true))
        #expect(menu.items.map(\.title).prefix(2) == ["Stop Recording", "Cancel Recording"])
        #expect(menu.items[0].keyEquivalent == "5")
        #expect(menu.items[0].keyEquivalentModifierMask == [.command, .shift])
        let info = menu.items.suffix(3)
        #expect(info.allSatisfy { !$0.isEnabled })
        #expect(info.map(\.title) == ["Area 640 \u{00D7} 400, 30 fps, H.264", "MacBook Pro Microphone", "System audio off"])
        let cancel = menu.items[1]
        _ = cancel.target?.perform(cancel.action, with: cancel)
        #expect(chosen == [.stopRecording, .cancelRecording])

        controller.setRecording(.saving)
        #expect(controller.timerText == "Saving")
        controller.setRecording(nil)
        #expect(controller.timerText == nil)
    }

    @Test func pinnedCapturesBecomeASubmenuWhoseRowsReportTheirPin() throws {
        var chosen: [MenuItemID] = []
        let controller = StatusMenuController(
            modelProvider: { MenuM2Demo.makeModel() }, thumbnail: { MenuM2Demo.makeThumbnails()[$0] },
            onSelect: { chosen.append($0) }
        )
        let pinned = try #require(controller.menu.items.first { $0.title == "Pinned Captures (3)" })
        let submenu = try #require(pinned.submenu)
        let unlock = try #require(submenu.items.first { $0.title == "Unlock" && $0.isEnabled })
        #expect(unlock.indentationLevel == 1)
        _ = unlock.target?.perform(unlock.action, with: unlock)
        let closeAll = try #require(submenu.items.last)
        #expect(closeAll.title == "Close All Pins")
        _ = closeAll.target?.perform(closeAll.action, with: closeAll)
        #expect(chosen == [.unlockPin(3), .closeAllPins])
        let row = try #require(submenu.items.first { $0.title.hasPrefix("Pinned ") })
        #expect(row.image?.size == CGSize(width: 32, height: 32))
        let recording = try #require(controller.menu.items.first { $0.title.hasPrefix("Recording 11.48.09") })
        #expect(recording.attributedTitle?.string.hasPrefix("Recording 11.48.09 \u{00B7} 0:42\nToday, 11:48") == true)
    }

    @Test func menuM2SceneRendersAtTheShotSize() throws {
        let light = try #require(MenuM2Demo.renderScene(dark: false))
        let dark = try #require(MenuM2Demo.renderScene(dark: true))
        #expect(light.width == 840 && light.height == 1400)
        #expect(try #require(ImageStats.luminance(light)).standardDeviation >= 4)
        let region = CGRect(x: 240, y: 80, width: 520, height: 1000)
        let lightMean = try #require(ImageStats.luminance(light, region: region)).mean
        let darkMean = try #require(ImageStats.luminance(dark, region: region)).mean
        #expect(lightMean - darkMean >= 40)
    }

    @Test func recordingSceneShowsTheRedTimer() throws {
        let recording = try #require(HUDDemo.renderRecording(dark: false))
        #expect(recording.width == 2560 && recording.height == 1600)
        // The red timer in the menu bar (mockup region 1138 4 52 16).
        let timer = try #require(SyntheticImages.pixel(of: recording, x: 1188 * 2, y: 12 * 2))
        #expect(timer.r > timer.g + 100)
    }

    @Test func recordingTabFollowsTheMicrophoneAccess() async throws {
        var requests = 0
        let actions = SettingsActions(requestMicrophoneAccess: {
            requests += 1
            return .denied
        })
        let model = SettingsModel(
            tab: .recording, microphoneAccess: .notDetermined,
            microphones: [MicrophoneDevice(id: "m", name: "Studio Mic")], actions: actions
        )
        #expect(!model.showsMicrophoneWarning)
        #expect(!model.showsMicrophoneDevices)
        model.recordsMicrophone = true
        for _ in 0..<1000 where model.microphoneAccess == .notDetermined { await Task.yield() }
        #expect(requests == 1)
        #expect(model.microphoneAccess == .denied)
        // Denied keeps the switch on as the user's intent and shows the warning row (D65).
        #expect(model.settings.recording.microphone)
        #expect(model.showsMicrophoneWarning)
        #expect(!model.showsMicrophoneDevices)
        // Turning it off and on again does not ask twice: the status is no longer undetermined.
        model.recordsMicrophone = false
        model.recordsMicrophone = true
        for _ in 0..<100 { await Task.yield() }
        #expect(requests == 1)

        model.microphoneAccess = .authorized
        #expect(model.showsMicrophoneDevices)
        #expect(model.microphoneDeviceID == "m")
        #expect(SettingsTab.allCases == [.general, .capture, .quickAccess, .recording, .shortcuts])
    }

    @Test func settingsRecordingDemoShowsTheWarningAndRenders() throws {
        let model = SettingsDemo.makeModel(tab: .recording)
        #expect(model.showsMicrophoneWarning)
        let view = SettingsDemo.makeView(tab: .recording, dark: false)
        #expect(view.frame.size == Theme.SettingsM2.recordingTabSize)
        let image = try #require(OffscreenRender.cacheDisplay(view, scale: 2))
        #expect(image.width == 960 && image.height == 1380)
        #expect(try #require(ImageStats.luminance(image)).standardDeviation >= 4)
    }
}

private extension SyntheticImages.Pixel {
    /// The channels as Int, so arithmetic on them cannot overflow UInt8.
    var r: Int { Int(red) }
    var g: Int { Int(green) }
    var b: Int { Int(blue) }
}

@MainActor
@Suite struct OnboardingMotionTests {
    @Test func theGrantedRowsTransitionAnimatesTheCheckScaleFromPointSix() {
        var active = GrantedCheckScale(scale: Theme.Motion.checkStartScale)
        #expect(active.animatableData == 0.6)
        active.animatableData = 0.8
        #expect(active.scale == 0.8)
        #expect(EnvironmentValues().grantedCheckScale == 1)
    }
}
