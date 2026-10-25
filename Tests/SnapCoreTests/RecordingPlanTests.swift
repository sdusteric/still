import CoreGraphics
import Foundation
import SnapCore
import Testing

@Suite struct RecordingPlanTests {
    private let retina = DisplayInfo(spec: "2560x1440@2")!
    private let oneX = DisplayInfo(spec: "2560x1440@1")!

    private func settings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
        var settings = Settings()
        change(&settings)
        return settings
    }

    @Test func anAreaOnARetinaDisplayRecordsAtTwiceItsPointSize() throws {
        let plan = try RecordingPlan.make(
            target: .area(CGRect(x: 330, y: 150, width: 640, height: 400)), displays: [retina], settings: settings(),
            excludedWindowIDs: [9, 3]
        )
        #expect(plan.filterKind == .displayExcludingWindows)
        #expect(plan.displayID == retina.id)
        #expect(plan.sourceRect == CGRect(x: 330, y: 150, width: 640, height: 400))
        #expect(plan.screenRect == CGRect(x: 330, y: 150, width: 640, height: 400))
        #expect(plan.scale == 2)
        #expect(plan.pixelSize == PixelSize(width: 1280, height: 800))
        #expect(plan.excludedWindowIDs == [3, 9])
        #expect(plan.windowID == nil)
        #expect(plan.outputURL == nil)
    }

    @Test func oddAreaSizesRoundDownToEvenPixelsAtOneX() throws {
        let plan = try RecordingPlan.make(
            target: .area(CGRect(x: 330, y: 150, width: 641, height: 401)), displays: [oneX], settings: settings()
        )
        #expect(plan.pixelSize == PixelSize(width: 640, height: 400))
        #expect(plan.sourceRect == CGRect(x: 330, y: 150, width: 640, height: 400))
        #expect(plan.scale == 1)
    }

    @Test func theOneXSettingRecordsARetinaAreaAtOnePixelPerPoint() throws {
        let plan = try RecordingPlan.make(
            target: .area(CGRect(x: 10.5, y: 20.25, width: 301, height: 203)), displays: [retina],
            settings: settings { $0.recording.scale = .oneX }
        )
        #expect(plan.scale == 1)
        #expect(plan.pixelSize == PixelSize(width: 300, height: 202))
        // The origin snaps to the output pixel grid and the size matches the pixels exactly.
        #expect(plan.sourceRect == CGRect(x: 10, y: 20, width: 300, height: 202))
    }

    @Test func aRetinaAreaWithHalfPointEdgesKeepsPixelsOneToOne() throws {
        let plan = try RecordingPlan.make(
            target: .area(CGRect(x: 100.5, y: 50.5, width: 200.5, height: 100.5)), displays: [retina], settings: settings()
        )
        #expect(plan.pixelSize == PixelSize(width: 400, height: 200))
        #expect(plan.sourceRect.origin == CGPoint(x: 100.5, y: 50.5))
        #expect(plan.sourceRect.width * plan.scale == 400)
        #expect(plan.sourceRect.height * plan.scale == 200)
    }

    @Test func anAreaOnTheSecondDisplayIsInThatDisplaysLocalPoints() throws {
        let plan = try RecordingPlan.make(
            target: .area(CGRect(x: 2600, y: 100, width: 800, height: 600)), displays: DisplayInfo.fakeSideBySide,
            settings: settings()
        )
        #expect(plan.displayID == 2)
        #expect(plan.scale == 1)
        #expect(plan.sourceRect == CGRect(x: 40, y: 100, width: 800, height: 600))
        #expect(plan.screenRect == CGRect(x: 2600, y: 100, width: 800, height: 600))
        #expect(plan.pixelSize == PixelSize(width: 800, height: 600))
    }

    @Test func aWindowUsesTheDesktopIndependentFilterWithoutShadowOrExclusions() throws {
        let window = WindowInfo(id: 77, ownerPID: 12, ownerName: "Notes", frame: CGRect(x: 100, y: 80, width: 801, height: 503), order: 0)
        let plan = try RecordingPlan.make(
            target: .window(window), displays: [DisplayInfo.fake5K], settings: settings(), excludedWindowIDs: [5]
        )
        #expect(plan.filterKind == .desktopIndependentWindow)
        #expect(plan.windowID == 77)
        #expect(plan.excludedWindowIDs.isEmpty)
        #expect(plan.ignoresShadowsSingleWindow)
        #expect(plan.pixelSize == PixelSize(width: 1602, height: 1006))
        #expect(plan.sourceRect == CGRect(x: 0, y: 0, width: 801, height: 503))
        #expect(plan.screenRect?.origin == CGPoint(x: 100, y: 80))
        #expect(plan.target.sourceApp == "Notes")
        #expect(plan.target.mode == .window)
    }

    @Test func fullscreenRecordsTheWholeDisplay() throws {
        let plan = try RecordingPlan.make(
            target: .fullscreen(displayID: 1), displays: DisplayInfo.fakeSideBySide, settings: settings(),
            excludedWindowIDs: [5]
        )
        #expect(plan.filterKind == .wholeDisplay)
        #expect(plan.pixelSize == PixelSize(width: 5120, height: 2880))
        #expect(plan.sourceRect == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(plan.screenRect == nil)
        #expect(plan.excludedWindowIDs == [5])
        let ultrawide = try RecordingPlan.make(target: .fullscreen(displayID: 2), displays: DisplayInfo.fakeSideBySide, settings: settings())
        #expect(ultrawide.pixelSize == PixelSize(width: 3440, height: 1440))
    }

    @Test func outputsUnder64PixelsAreRefused() throws {
        #expect(throws: RecordingPlanError.tooSmall(PixelSize(width: 62, height: 200))) {
            try RecordingPlan.make(target: .area(CGRect(x: 0, y: 0, width: 63, height: 200)), displays: [oneX], settings: settings())
        }
        let smallest = try RecordingPlan.make(
            target: .area(CGRect(x: 0, y: 0, width: 65, height: 64)), displays: [oneX], settings: settings()
        )
        #expect(smallest.pixelSize == PixelSize(width: 64, height: 64))
        // 32 points is 64 pixels on a Retina display.
        let retinaSmallest = try RecordingPlan.make(
            target: .area(CGRect(x: 0, y: 0, width: 32, height: 32)), displays: [retina], settings: settings()
        )
        #expect(retinaSmallest.pixelSize == PixelSize(width: 64, height: 64))
        #expect(RecordingPlanError.tooSmall(PixelSize(width: 2, height: 2)).description == "Too small to record")
    }

    @Test func frameRateCodecCursorAndColourComeFromSettings() throws {
        let plan = try RecordingPlan.make(
            target: .fullscreen(displayID: 1), displays: [retina],
            settings: settings {
                $0.recording.fps = 60
                $0.recording.format = .hevc
                $0.recording.showCursor = false
                $0.recording.highlightClicks = false
            }
        )
        #expect(plan.fps == 60)
        #expect(abs(plan.minimumFrameInterval - 1.0 / 60) < 1e-12)
        #expect(plan.codec == .hevc)
        #expect(plan.queueDepth == 6)
        #expect(!plan.showsCursor)
        #expect(!plan.showsMouseClicks)
        #expect(plan.colorSpaceName == CGColorSpace.sRGB as String)
        #expect(plan.colorMatrix == "ITU_R_709_2")
        let defaults = try RecordingPlan.make(target: .fullscreen(displayID: 1), displays: [retina], settings: settings())
        #expect(defaults.fps == 30)
        #expect(defaults.codec == .h264)
        #expect(defaults.showsCursor)
        #expect(defaults.showsMouseClicks)
        #expect(defaults.logSummary == "target=fullscreen size=2560x1440 fps=30 codec=avc1 audio=none")
    }

    @Test func audioFlagsFollowSystemAudioAndMicrophoneSettings() throws {
        let silent = try RecordingPlan.make(target: .fullscreen(displayID: 1), displays: [retina], settings: settings())
        #expect(!silent.capturesAudio)
        #expect(!silent.capturesMicrophone)
        #expect(silent.audioSources.isEmpty)
        #expect(silent.excludesCurrentProcessAudio)

        let both = try RecordingPlan.make(
            target: .fullscreen(displayID: 1), displays: [retina],
            settings: settings {
                $0.recording.systemAudio = true
                $0.recording.microphone = true
                $0.recording.microphoneDeviceID = "BuiltInMicrophoneDevice"
            }
        )
        #expect(both.capturesAudio)
        #expect(both.excludesCurrentProcessAudio)
        #expect(both.audioSampleRate == 48_000)
        #expect(both.audioChannelCount == 2)
        #expect(both.capturesMicrophone)
        #expect(both.microphoneDeviceID == "BuiltInMicrophoneDevice")
        #expect(both.audioSources == [.system, .microphone])

        let deviceWithoutMicrophone = try RecordingPlan.make(
            target: .fullscreen(displayID: 1), displays: [retina],
            settings: settings { $0.recording.microphoneDeviceID = "BuiltInMicrophoneDevice" }
        )
        #expect(deviceWithoutMicrophone.microphoneDeviceID == nil)
    }

    @Test func desktopIconsAreExcludedOnlyWhenHideDesktopIconsIsOn() throws {
        let area = RecordingTarget.area(CGRect(x: 0, y: 0, width: 400, height: 300))
        let hidden = try RecordingPlan.make(
            target: area, displays: [retina], settings: settings(), excludedWindowIDs: [40, 41], desktopIconWindowIDs: [7]
        )
        #expect(hidden.excludedWindowIDs == [7, 40, 41])
        let shown = try RecordingPlan.make(
            target: area, displays: [retina], settings: settings { $0.capture.hideDesktopIcons = false },
            excludedWindowIDs: [40, 41], desktopIconWindowIDs: [7]
        )
        #expect(shown.excludedWindowIDs == [40, 41])
    }

    @Test func targetsWithoutADisplayOrAreaAreRefused() {
        #expect(throws: RecordingPlanError.noDisplay) {
            try RecordingPlan.make(target: .fullscreen(displayID: 99), displays: [retina], settings: Settings())
        }
        #expect(throws: RecordingPlanError.noDisplay) {
            try RecordingPlan.make(target: .area(CGRect(x: -900, y: -900, width: 300, height: 300)), displays: [retina], settings: Settings())
        }
        #expect(throws: RecordingPlanError.emptyTarget) {
            try RecordingPlan.make(target: .area(CGRect(x: 10, y: 10, width: 0, height: 300)), displays: [retina], settings: Settings())
        }
    }
}
