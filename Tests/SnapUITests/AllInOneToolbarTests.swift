import AppKit
import SnapCore
@testable import SnapUI
import Testing

/// The all-in-one HUD toolbar (design 20.5, mockup 10), its Options menu, the countdown (20.6,
/// M22), the recording outline (D63) and the red timer (M24). Nothing here makes a window.
@MainActor
@Suite struct AllInOneToolbarTests {
    @Test func controlsFollowTheDesignOrderAndSizes() throws {
        let layout = AllInOneToolbarLayout.layout(for: .screenshot)
        #expect(layout.items == [
            .close, .mode(.screenshot), .mode(.record), .target(.area), .target(.window), .target(.fullscreen),
            .options, .primary,
        ])
        #expect(Double(layout.size.height) == Theme.HUD.barHeight)
        #expect(layout.dividers.count == 3)
        let close = try #require(layout.frame(of: .close))
        #expect(Double(close.minX) == Theme.HUD.barPadding)
        #expect(close.width == Theme.HUD.closeButtonSize && close.height == Theme.HUD.closeButtonSize)
        for target in AllInOneToolbarLayout.targets {
            let frame = try #require(layout.frame(of: .target(target)))
            #expect(frame.size == Theme.HUD.targetButtonSize)
        }
        #expect(try #require(layout.frame(of: .mode(.record))).height == Theme.HUD.segmentHeight)
        #expect(try #require(layout.frame(of: .primary)).height == Theme.HUD.primaryHeight)
        #expect(Double(layout.segmentTrack.height) == Theme.HUD.segmentHeight + 2 * Theme.HUD.segmentPadding)
        // Left to right without overlap, every control vertically centered in the bar.
        let frames = layout.slots.map(\.frame)
        for (left, right) in zip(frames, frames.dropFirst()) { #expect(left.maxX <= right.minX) }
        for frame in frames { #expect(abs(frame.midY - layout.size.height / 2) < 0.01) }
        let primary = try #require(layout.frame(of: .primary))
        #expect(Double(layout.size.width - primary.maxX) == Theme.HUD.barPadding)
        // The mockup's bar is about 567 pt wide.
        #expect(abs(layout.size.width - 567) < 24)
    }

    @Test func hitTestingFindsEachControlAndNothingBetween() throws {
        for mode in HUDMode.allCases {
            let layout = AllInOneToolbarLayout.layout(for: mode)
            for slot in layout.slots {
                #expect(layout.hit(CGPoint(x: slot.frame.midX, y: slot.frame.midY)) == slot.item)
            }
            #expect(layout.hit(CGPoint(x: 1, y: 1)) == nil)
            let divider = try #require(layout.dividers.first)
            #expect(layout.hit(CGPoint(x: divider.midX, y: divider.midY)) == nil)
        }
        // The primary button reads Capture or Record and the layouts are cached per mode.
        #expect(AllInOneState(mode: .screenshot).primaryTitle == "Capture")
        #expect(AllInOneState(mode: .record).primaryTitle == "Record")
        #expect(AllInOneToolbarLayout.layout(for: .record) == AllInOneToolbarLayout.layout(for: .record))
        #expect(AllInOneToolbarItem.target(.window).tooltip == "Window (2)")
    }

    @Test func primaryButtonUsesTheAccentOrTheRecordRed() throws {
        let screenshot = try #require(HUDDemo.renderHUD(dark: false))
        let controller = HUDDemo.makeController(mode: .record)
        let recordState = try #require(controller.states[HUDDemo.display.id])
        let record = try #require(OverlayDemo.render(recordState, dark: false))
        let frame = try #require(controller.toolbarFrame)
        let slot = try #require(AllInOneToolbarLayout.layout(for: .record).frame(of: .primary))
        let red = try #require(SyntheticImages.pixel(
            of: record, x: Int((frame.minX + slot.minX + 4) * 2), y: Int((frame.minY + slot.midY) * 2)
        ))
        #expect(red.r > red.g + 100)
        #expect(red.r > red.b + 100)
        let shotFrame = try #require(HUDDemo.makeController(mode: .screenshot).toolbarFrame)
        let shotSlot = try #require(AllInOneToolbarLayout.layout(for: .screenshot).frame(of: .primary))
        let accent = try #require(SyntheticImages.pixel(
            of: screenshot, x: Int((shotFrame.minX + shotSlot.minX + 4) * 2), y: Int((shotFrame.minY + shotSlot.midY) * 2)
        ))
        // The accent is the system's; it is never the chip gray.
        let spread = max(accent.r, accent.g, accent.b) - min(accent.r, accent.g, accent.b)
        #expect(spread > 60)
        // The chip surface is flat and dark in light mode too.
        let chip = try #require(SyntheticImages.pixel(of: screenshot, x: Int((shotFrame.minX + 4) * 2), y: Int(shotFrame.midY * 2)))
        #expect(chip.luminance < 60)
    }

    @Test func optionsMenuRowsFollowTheModeAndWriteTheSettings() throws {
        var settings = SnapCore.Settings()
        let shot = AllInOneOptions.items(mode: .screenshot, settings: settings, microphones: [])
        #expect(shot.map(\.title) == ["Hide Desktop Icons", "Include Window Shadow", "Show Magnifier"])
        #expect(shot.map(\.checked) == [true, true, false], "the magnifier is off by default")

        let mics = [MicrophoneDevice(id: "a", name: "Built-in"), MicrophoneDevice(id: "b", name: "Studio Mic")]
        let record = AllInOneOptions.items(mode: .record, settings: settings, microphones: mics)
        let titles = record.filter { $0.kind != .separator }.map(\.title)
        #expect(titles == [
            "Microphone", "None", "Built-in", "Studio Mic", "Record System Audio", "Show Cursor", "Highlight Clicks",
            "Countdown", "Off", "3 seconds", "5 seconds",
        ])
        #expect(record.first { $0.title == "None" }?.checked == true)
        #expect(record.first { $0.title == "3 seconds" }?.checked == true)

        settings = AllInOneOptions.apply(.microphone("b"), to: settings)
        #expect(settings.recording.microphone && settings.recording.microphoneDeviceID == "b")
        let withMic = AllInOneOptions.items(mode: .record, settings: settings, microphones: mics)
        #expect(withMic.first { $0.title == "Studio Mic" }?.checked == true)
        #expect(withMic.first { $0.title == "None" }?.checked == false)
        settings = AllInOneOptions.apply(.microphone(nil), to: settings)
        #expect(!settings.recording.microphone)
        settings = AllInOneOptions.apply(.countdown(5), to: settings)
        #expect(settings.recording.countdownSeconds == 5)
        settings = AllInOneOptions.apply(.systemAudio, to: settings)
        #expect(settings.recording.systemAudio)
        settings = AllInOneOptions.apply(.hideDesktopIcons, to: settings)
        #expect(!settings.capture.hideDesktopIcons)

        var picked: [AllInOneOption] = []
        let menu = AllInOneOptions.makeMenu(record) { picked.append($0) }
        let item = try #require(menu.items.first { $0.title == "Show Cursor" })
        _ = item.target?.perform(item.action, with: item)
        #expect(picked == [.showCursor])
    }

    @Test func countdownSitsOnTheTargetWithTheHintBelow() {
        let target = CGRect(x: 330, y: 150, width: 640, height: 400)
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let disc = CountdownLayout.discFrame(target: target, bounds: bounds)
        #expect(disc.size == CGSize(width: Theme.Countdown.discSize, height: Theme.Countdown.discSize))
        #expect(disc.midX == target.midX && disc.midY == target.midY)
        let hint = CountdownLayout.hintFrame(disc: disc, seconds: 3)
        #expect(Double(hint.minY) == Double(disc.maxY) + Theme.Countdown.hintGap)
        #expect(abs(hint.midX - disc.midX) <= 0.5)
        #expect(Double(hint.height) == Theme.Overlay.hintBarHeight)
        // A target at the bottom edge keeps the disc and hint on screen.
        let low = CountdownLayout.discFrame(target: CGRect(x: 0, y: 760, width: 200, height: 40), bounds: bounds)
        #expect(CountdownLayout.hintFrame(disc: low, seconds: 3).maxY <= bounds.maxY)
        #expect(CountdownLayout.digit(3) == "3")
        #expect(CountdownLayout.digit(0) == "1")
    }

    @Test func countdownViewSwapsDigitsWithoutRedrawingTheOverlay() {
        let view = CountdownView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let disc = CGRect(x: 10, y: 10, width: 88, height: 88)
        view.show(3, disc: disc)
        #expect(view.shownSeconds == 3)
        view.show(2, disc: disc)
        #expect(view.shownSeconds == 2)
        // M22 amended: the new digit only cross-fades; nothing scales it.
        for digit in view.subviews {
            #expect(digit.layer?.animation(forKey: "countdownScale") == nil)
            #expect(digit.layer.map { CATransform3DIsIdentity($0.transform) } ?? true)
        }
        view.show(nil, disc: .zero)
        #expect(view.shownSeconds == nil)
        #expect(view.hitTest(CGPoint(x: 20, y: 20)) == nil)
    }

    @Test func recordingOutlineSitsOutsideTheArea() throws {
        let area = CGRect(x: 330, y: 150, width: 640, height: 400)
        let border = RecordingOutline.borderRect(around: area)
        #expect(border == area.insetBy(dx: -Theme.Recording.outlineOutset, dy: -Theme.Recording.outlineOutset))
        let panel = RecordingOutline.panelFrame(around: area)
        #expect(panel.contains(area))
        #expect(Double(panel.minX) == Double(area.minX) - Theme.Recording.outlineOutset - RecordingOutline.strokeWidth)

        // Drawn on a white canvas, no pixel inside the area changes; the white line sits 3 pt out.
        let size = panel.size
        guard let context = SyntheticImages.makeContext(width: Int(size.width * 2), height: Int(size.height * 2)) else {
            Issue.record("no context")
            return
        }
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let local = area.offsetBy(dx: -panel.minX, dy: -panel.minY)
        RecordingOutline.draw(around: local, context: context)
        let image = try #require(context.makeImage())
        let insideEdge = try #require(SyntheticImages.pixel(of: image, x: Int(local.minX * 2) + 1, y: Int(local.midY * 2)))
        let center = try #require(SyntheticImages.pixel(of: image, x: Int(local.midX * 2), y: Int(local.midY * 2)))
        #expect(insideEdge == center)
        let white = try #require(SyntheticImages.pixel(of: image, x: Int((local.minX - 3.5) * 2), y: Int(local.midY * 2)))
        #expect(white.luminance > 240)
    }

    @Test func recordingTimerReadsElapsedTimeOrSaving() throws {
        #expect(RecordingIndicator.recording(since: 100).text(now: 142.7) == "0:42")
        #expect(RecordingIndicator.recording(since: 0).text(now: 3725) == "1:02:05")
        #expect(RecordingIndicator.saving.text(now: 0) == "Saving")
        let short = RecordingStatusItemView.capsuleSize(for: "0:07")
        #expect(Double(short.height) == Theme.Recording.timerHeight)
        #expect(RecordingStatusItemView.capsuleSize(for: "1:02:05").width > short.width)
        // The mockup's capsule is 56 pt wide for 0:42.
        #expect(abs(RecordingStatusItemView.capsuleSize(for: "0:42").width - 56) < 6)

        let view = RecordingStatusItemView(text: "0:42")
        view.appearance = NSAppearance(named: .aqua)
        let image = try #require(OffscreenRender.cacheDisplay(view, scale: 2))
        let fill = try #require(SyntheticImages.pixel(of: image, x: 6, y: image.height / 2))
        #expect(fill.r > 200 && fill.g < 120)
        let square = try #require(SyntheticImages.pixel(
            of: image, x: Int((Theme.Recording.timerLeadingPadding + 4) * 2), y: image.height / 2
        ))
        #expect(square.luminance > 240)
    }
}

private extension SyntheticImages.Pixel {
    /// The channels as Int, so arithmetic on them cannot overflow UInt8.
    var r: Int { Int(red) }
    var g: Int { Int(green) }
    var b: Int { Int(blue) }
}
