import AppKit
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

/// The surfaces of design 20.16 without a window or a status item: the stalled timer, the
/// permission badge, the audio check on the video card and the annotate editor reopened from
/// History with its annotations editable.
@MainActor
@Suite struct ReliabilitySurfaceTests {
    /// Mean RGB of a region, composited on black.
    private func meanColor(_ image: CGImage, _ region: CGRect) -> (red: Double, green: Double, blue: Double)? {
        guard let crop = image.cropping(to: region), let bytes = SyntheticImages.rgbaBytes(of: crop), !bytes.isEmpty else { return nil }
        var sums = (0.0, 0.0, 0.0)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            sums.0 += Double(bytes[index])
            sums.1 += Double(bytes[index + 1])
            sums.2 += Double(bytes[index + 2])
        }
        let count = Double(bytes.count / 4)
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }

    private func render(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    // MARK: Stalled timer

    @Test func aStalledTimerIsAmberWithTheWarningGlyphAndStillStops() throws {
        let stall = RecordingStall(track: .video, seconds: 5, lastSampleElapsed: 37)
        let calm = RecordingStatusItemView(text: "0:42")
        let stalled = RecordingStatusItemView(text: "0:42", stall: stall)
        #expect(stalled.intrinsicContentSize.width > calm.intrinsicContentSize.width, "room for the glyph")
        #expect(stalled.toolTip?.contains("Recording stalled: no new frames for 5 s") == true)
        #expect(stalled.toolTip?.contains("Stop Recording") == true)
        stalled.appearance = NSAppearance(named: .aqua)
        calm.appearance = NSAppearance(named: .aqua)
        let amber = try #require(render(stalled))
        let red = try #require(render(calm))
        // A strip of the capsule left of the stop square: amber is much greener than record red.
        let strip = CGRect(x: 4, y: 14, width: 6, height: 8)
        let amberColor = try #require(meanColor(amber, strip))
        let redColor = try #require(meanColor(red, strip))
        #expect(amberColor.red > 200 && amberColor.green > 110 && amberColor.blue < 60)
        #expect(redColor.green < 90)
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }

    @Test func theStatusControllerKeepsTheStallAndTheBadgeAsPlainState() {
        let controller = StatusMenuController(modelProvider: { MenuModel(MenuInput(permissionNeeded: true)) })
        #expect(!controller.showsBadge)
        controller.setBadge(true)
        #expect(controller.showsBadge)
        controller.setRecording(.recording(since: 0))
        let stall = RecordingStall(track: .microphone, seconds: 4, lastSampleElapsed: 10)
        controller.setStall(stall)
        #expect(controller.stall == stall)
        controller.setStall(nil)
        #expect(controller.stall == nil)
        controller.setBadge(false)
        #expect(!controller.showsBadge)
        // The menu row is a plain clickable item; nothing opens until it is chosen.
        let row = controller.menu.items.first { $0.title == "Screen Recording needs your OK" }
        #expect(row?.isEnabled == true)
    }

    @Test func theBadgeSitsInAHoleAtTheSymbolsTopRight() throws {
        let symbol = try #require(NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil))
        let holed = StatusBadgeView.symbolWithHole(symbol)
        #expect(holed.size == symbol.size)
        let button = CGRect(x: 0, y: 0, width: 24, height: 22)
        let frame = StatusBadgeView.frame(in: button, symbolSize: symbol.size)
        #expect(button.contains(frame))
        #expect(frame.midX > button.midX && frame.midY < button.midY, "top-right in a flipped button")
        let badge = StatusBadgeView()
        badge.appearance = NSAppearance(named: .aqua)
        let image = try #require(render(badge))
        let center = try #require(meanColor(image, CGRect(x: image.width / 2 - 2, y: image.height / 2 - 2, width: 4, height: 4)))
        #expect(center.red > 200 && center.blue < 60, "the warning dot")
        #expect(badge.hitTest(CGPoint(x: 2, y: 2)) == nil, "clicks reach the status item")
    }

    @Test func thePermissionSceneRendersWithTheBadgedSymbol() throws {
        let light = try #require(MenuPermissionDemo.renderScene(dark: false))
        let dark = try #require(MenuPermissionDemo.renderScene(dark: true))
        #expect(light.width == 840 && light.height == 1200)
        #expect(dark.width == 840 && dark.height == 1200)
        #expect(MenuPermissionDemo.makeModel().item(.status)?.title == "Screen Recording needs your OK")
        // The badge: an orange disc near the symbol's top-right in the menu bar.
        let symbolX = MenuM2Demo.statusItemX
        let center = StatusBadgeView.center(inSymbolOf: CGSize(width: 15, height: 15))
        let point = CGRect(x: (symbolX + center.x) * 2 - 2, y: (4.5 + center.y) * 2 - 2, width: 4, height: 4)
        let badge = try #require(meanColor(light, point))
        #expect(badge.red > 200 && badge.blue < 80)
    }

    // MARK: Audio check on the video card

    private func cardImage(_ check: AudioCheck?, size: QuickAccessSize = .medium) throws -> CGImage {
        let poster = try #require(SyntheticImages.solid(width: 480, height: 300, color: .black))
        let card = QuickAccessCardModel(
            id: "audio", thumbnail: poster, pointSize: CGSize(width: 1280, height: 800), size: size, kind: .video, durationSeconds: 42
        )
        card.audioCheck = check
        let renderer = ImageRenderer(content: QuickAccessCardView(card: card, interactive: false).environment(\.colorScheme, .light))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    @Test func aMissingOrSilentTrackShowsAWarningPillBesideTheDuration() throws {
        let none = try cardImage(nil)
        let missing = try cardImage(.noTrack)
        let captured = try cardImage(.captured)
        // The strip right of the duration pill, along the bottom of the thumbnail.
        let strip = CGRect(x: 140, y: none.height - 64, width: 120, height: 30)
        let plain = try #require(ImageStats.luminance(none, region: strip))
        let warned = try #require(ImageStats.luminance(missing, region: strip))
        #expect(warned.standardDeviation > plain.standardDeviation + 4, "text and glyph appear in the strip")
        // Where the speaker glyph sits: right of `0:42` inside the duration pill.
        let pill = CGRect(x: 96, y: none.height - 58, width: 40, height: 32)
        let withSpeaker = try #require(ImageStats.luminance(captured, region: pill))
        let withoutSpeaker = try #require(ImageStats.luminance(none, region: pill))
        #expect(withSpeaker.mean > withoutSpeaker.mean + 2, "the speaker glyph in the duration pill")
        #expect(NSApplication.shared.windows.isEmpty)
    }

    @Test func theControllerCarriesTheAudioCheckToTheCard() {
        let log = ActionLog()
        let controller = QuickAccessController(
            clock: FakeClock(), actions: log.actions(), visibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 875) },
            optionHeld: { false }, makeSurface: nil
        )
        let poster = SyntheticImages.solid(width: 128, height: 80, color: .black) ?? FakeImages.fallback
        controller.show(QuickAccessItem(
            id: "v", thumbnail: poster, pointSize: CGSize(width: 1280, height: 800), kind: .video, durationSeconds: 3,
            audioCheck: .microphoneSilent
        ))
        #expect(controller.card("v")?.audioCheck == .microphoneSilent)
        #expect(controller.card("v")?.audioCheck?.warning == "Microphone silent")
    }

    @Test func theAudioSceneRendersAtTwiceItsPointSize() throws {
        let light = try #require(QuickAccessDemo.renderAudioScene(dark: false))
        let dark = try #require(QuickAccessDemo.renderAudioScene(dark: true))
        #expect(light.width == 1200 && light.height == 1520)
        #expect(dark.width == 1200 && dark.height == 1520)
        #expect(QuickAccessDemo.audioCards().compactMap(\.audioCheck) == [.captured, .noTrack, .microphoneSilent])
    }

    // MARK: Reopened annotations

    @Test func theReopenedEditorHasEveryAnnotationEditable() throws {
        let (document, file) = try #require(AnnotateDemo.makeReopenedDocument())
        let sample = try #require(AnnotateDemo.makeDocument())
        // The ids differ (each sample build makes new ones); kind and geometry come back from the file.
        #expect(document.items.map(\.kind) == sample.items.map(\.kind), "the items come back from the file, not as pixels")
        #expect(document.items.map(\.start) == sample.items.map(\.start))
        #expect(document.items.map(\.end) == sample.items.map(\.end))
        #expect(file.background != nil)
        let canvas = AnnotateCanvasView(document: document)
        let arrow = try #require(document.items.first { $0.kind == .arrow })
        canvas.setSelection(arrow.id)
        canvas.nudgeSelection(dx: 1, dy: 0, large: true)
        #expect(canvas.document.item(arrow.id)?.start == CGPoint(x: arrow.start.x + 10, y: arrow.start.y))
        let view = AnnotateDemo.makeReopenedView()
        #expect(view.frame.size == AnnotateDemo.size)
    }

    @Test func exportsHandTheDocumentToTheAppToKeep() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        var kept: [AnnotationDocument] = []
        var copied = 0
        canvas.model.actions = AnnotateActions(copy: { _, _ in copied += 1 }, keep: { kept.append($0) })
        canvas.copyImage()
        #expect(copied == 1)
        #expect(kept.count == 1)
        #expect(kept.first?.items == document.items)
        let file = AnnotationFile(document: try #require(kept.first))
        #expect(file.items.count == 4)
    }

    @Test func theToolbarSaysWhenTheBackgroundIsOn() {
        let on = AnnotateEditorModel(actions: AnnotateActions(backgroundApplied: true))
        let off = AnnotateEditorModel(actions: AnnotateActions())
        #expect(on.backgroundApplied)
        #expect(!off.backgroundApplied)
    }
}
