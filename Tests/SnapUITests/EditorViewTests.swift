import AppKit
import Foundation
import SnapCore
import SwiftUI
import Testing
@testable import SnapUI

/// Renders `view` with `cacheDisplay` at 2x: no window, no run loop, nothing on screen.
@MainActor
private func render(_ view: NSView) throws -> CGImage {
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    return try #require(rep.cgImage)
}

private struct Luminance {
    var mean: Double
    var deviation: Double
}

/// Mean and standard deviation of luminance (0 to 255) over `rect` in pixels, top-left origin.
private func luminance(_ image: CGImage, in rect: CGRect? = nil) throws -> Luminance {
    let bytes = try #require(SyntheticImages.rgbaBytes(of: image))
    let region = (rect ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
    var sum = 0.0
    var squares = 0.0
    var count = 0.0
    for y in Int(region.minY)..<Int(region.maxY) {
        for x in Int(region.minX)..<Int(region.maxX) {
            let base = (y * image.width + x) * 4
            let alpha = Double(bytes[base + 3]) / 255
            let value = SyntheticImages.Pixel(red: bytes[base], green: bytes[base + 1], blue: bytes[base + 2]).luminance * alpha
            sum += value
            squares += value * value
            count += 1
        }
    }
    let mean = sum / count
    return Luminance(mean: mean, deviation: max(squares / count - mean * mean, 0).squareRoot())
}

@MainActor
@Suite struct EditorViewTests {
    // MARK: Demos render without a window, in both appearances

    private func checkDemo(_ name: String, size: CGSize, make: (Bool) -> NSView) throws {
        let light = try render(make(false))
        let dark = try render(make(true))
        #expect(light.width == Int(size.width * 2) && light.height == Int(size.height * 2), "\(name) light size")
        #expect(dark.width == Int(size.width * 2) && dark.height == Int(size.height * 2), "\(name) dark size")
        let lightStats = try luminance(light)
        let darkStats = try luminance(dark)
        #expect(lightStats.deviation >= 4, "\(name) light looks blank: \(lightStats)")
        #expect(darkStats.deviation >= 4, "\(name) dark looks blank: \(darkStats)")
        #expect(lightStats.mean - darkStats.mean >= 40, "\(name): light \(lightStats.mean), dark \(darkStats.mean)")
        #expect(NSApplication.shared.windows.isEmpty, "rendering must not create a window")
    }

    @Test func backgroundEditorDemoRendersInLightAndDark() throws {
        try checkDemo("background-editor", size: BackgroundEditorDemo.size) { BackgroundEditorDemo.makeView(dark: $0) }
    }

    @Test func annotateDemoRendersInLightAndDark() throws {
        try checkDemo("annotate", size: AnnotateDemo.size) { AnnotateDemo.makeView(dark: $0) }
    }

    @Test func annotateToolsDemoRendersInLightAndDark() throws {
        try checkDemo("annotate-tools", size: AnnotateDemo.size) { AnnotateDemo.makeToolsView(dark: $0) }
        // The style menu hangs under the toolbar: its black-out row is the accent color.
        let light = try render(AnnotateDemo.makeToolsView(dark: false))
        let menu = try luminance(light, in: CGRect(x: 450 * 2, y: 100 * 2, width: 200 * 2, height: 22 * 2))
        let canvas = try luminance(light, in: CGRect(x: 300 * 2, y: 400 * 2, width: 200 * 2, height: 22 * 2))
        #expect(menu.mean < canvas.mean, "the highlighted row is darker than the page: \(menu.mean) vs \(canvas.mean)")
    }

    @Test func settingsDemoRendersEveryTabInLightAndDark() throws {
        for tab in SettingsTab.allCases {
            try checkDemo("settings-\(tab.rawValue)", size: SettingsDemo.size) { SettingsDemo.makeView(tab: tab, dark: $0) }
        }
    }

    @Test func menuDemoRendersInLightAndDark() throws {
        try checkDemo("menu", size: MenuDemo.size) { MenuDemo.makeView(dark: $0) }
    }

    @Test func onboardingDemoRendersBothStepsInLightAndDark() throws {
        for granted in [false, true] {
            try checkDemo("onboarding-\(granted)", size: OnboardingDemo.size(granted: granted)) {
                OnboardingDemo.makeView(granted: granted, dark: $0)
            }
        }
    }

    @Test func backgroundEditorChromeFollowsTheAppearance() throws {
        // The sidebar, right of the preview: 300 pt wide at x 620.
        let sidebar = CGRect(x: 640 * 2, y: 300 * 2, width: 260 * 2, height: 200 * 2)
        let light = try luminance(try render(BackgroundEditorDemo.makeView(dark: false)), in: sidebar)
        let dark = try luminance(try render(BackgroundEditorDemo.makeView(dark: true)), in: sidebar)
        #expect(light.mean - dark.mean >= 40, "light \(light.mean), dark \(dark.mean)")
    }

    /// Mockups 3 and 13: the sample capture gets the inset card, so the caption matches the
    /// mockup's, and the mesh shot's window frame carries the 52 pt title bar above the editor.
    /// The gradient stands in for the mesh here: same geometry and frame, and a mesh render takes
    /// about 20 s in a debug build.
    @Test func editorDemoMatchesTheMockupGeometryAndTitleBar() throws {
        let model = try #require(BackgroundEditorDemo.makeModel())
        #expect(model.caption == "914 \u{00D7} 588 pt  \u{2022}  1828 \u{00D7} 1176 px")
        for dark in [false, true] {
            let image = try render(BackgroundEditorDemo.makeWindowView(dark: dark))
            #expect(image.width == 1840 && image.height == 1280)
            // The title bar is the window color, opaque, and its hairline sits at 51 pt.
            let bar = try luminance(image, in: CGRect(x: 400 * 2, y: 10 * 2, width: 200 * 2, height: 8 * 2))
            let line = try luminance(image, in: CGRect(x: 400 * 2, y: 51 * 2, width: 200 * 2, height: 2))
            #expect(bar.deviation < 1, "flat title bar")
            #expect(abs(line.mean - bar.mean) < 40, "hairline is subtle, not white: \(line.mean) vs \(bar.mean)")
            #expect(dark ? bar.mean < 60 : bar.mean > 200)
            let bytes = try #require(SyntheticImages.rgbaBytes(of: image))
            let lineAlpha = bytes[(51 * 2 * image.width + 800) * 4 + 3]
            #expect(lineAlpha == 255, "the hairline sits on the opaque bar")
        }
    }

    // MARK: Background editor model

    @Test func backgroundPreviewMatchesTheFullGeometry() throws {
        let model = try #require(BackgroundEditorDemo.makeModel())
        let geometry = try #require(model.geometry)
        let preview = try #require(model.preview)
        // The preview keeps the canvas aspect at a smaller scale.
        let previewAspect = Double(preview.width) / Double(preview.height)
        let fullAspect = Double(geometry.canvasSize.width) / Double(geometry.canvasSize.height)
        #expect(abs(previewAspect - fullAspect) < 0.01)
        #expect(preview.width < geometry.canvasSize.width)
        #expect(model.previewDisplaySize.width <= BackgroundEditorModel.previewArea.width + 0.5)
        #expect(model.caption.contains("\(geometry.canvasSize.width) \u{00D7} \(geometry.canvasSize.height) px"))
        let full = try #require(model.renderFull())
        #expect(full.image.width == geometry.canvasSize.width)
    }

    @Test func backgroundEditingSchedulesOneRenderAndResets() throws {
        let model = try #require(BackgroundEditorDemo.makeModel())
        let before = try #require(model.geometry)
        model.preset.padding = 60
        model.preset.shadow = 0
        model.renderPreview()
        let after = try #require(model.geometry)
        #expect(after.canvasPoints.width > before.canvasPoints.width)
        #expect(model.isModified)
        model.reset()
        #expect(model.preset == BackgroundPreset.factoryDefault)
        #expect(!model.isModified)
    }

    @Test func backgroundTabsAndRatio() throws {
        let model = try #require(BackgroundEditorDemo.makeModel())
        model.selectTab(.color)
        guard case .solid = model.preset.background else {
            Issue.record("Color tab applies a solid")
            return
        }
        model.select(.gradient(.ember))
        #expect(model.tab == .gradient)
        model.selectTab(.none)
        #expect(model.preset.background == .none)
        model.selectTab(.gradient)
        #expect(model.preset.background == .gradient(.ember), "the tab remembers its last swatch")
        model.selectTab(.image)
        #expect(model.preset.background == .gradient(.ember), "Image waits for a file")
        model.setRatio(AspectRatio(width: 16, height: 9))
        model.renderPreview()
        let geometry = try #require(model.geometry)
        #expect(abs(geometry.canvasPoints.width / geometry.canvasPoints.height - 16.0 / 9.0) < 0.001)
    }

    @Test func backgroundActionsGetTheFullRender() throws {
        let model = try #require(BackgroundEditorDemo.makeModel())
        var copied: CGImage?
        var closed = false
        var stored: [BackgroundPreset] = []
        var starred: String?
        model.actions = BackgroundEditorActions(
            copy: { output, _ in copied = output.image },
            close: { closed = true },
            savePreset: { stored.append($0) },
            setDefault: { starred = $0 }
        )
        model.copy()
        #expect(copied?.width == model.geometry?.canvasSize.width)
        #expect(closed, "Copy closes the editor")

        model.preset.padding = 40
        model.saveAsPreset(named: "Wide")
        #expect(stored.last?.name == "Wide")
        #expect(model.presets.count == 2)
        model.setAsDefault()
        #expect(starred == stored.last?.id)
        #expect(model.isDefault)
        model.deletePreset()
        #expect(model.presets.count == 1)
    }

    // MARK: Annotate canvas

    @Test func annotateCanvasUndoRestoresDocumentSnapshots() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        #expect(!canvas.model.canUndo)
        canvas.addItem(.rectangle(CGRect(x: 10, y: 10, width: 50, height: 40)))
        #expect(canvas.document.items.count == 5)
        #expect(canvas.model.canUndo)
        canvas.nudgeSelection(dx: 1, dy: 0, large: true)
        #expect(canvas.document.items.last?.box.minX == 20)
        canvas.undo()
        #expect(canvas.document.items.last?.box.minX == 10)
        canvas.undo()
        #expect(canvas.document.items.count == 4)
        #expect(canvas.model.canRedo)
        canvas.redo()
        #expect(canvas.document.items.count == 5)
        canvas.setSelection(canvas.document.items.last?.id)
        canvas.deleteSelection()
        #expect(canvas.document.items.count == 4)
        canvas.undo()
        #expect(canvas.document.items.count == 5)
    }

    @Test func annotateToolKeysAndStyle() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        #expect(AnnotateTool(key: "V") == .select)
        #expect(AnnotateTool(key: "p") == .redact)
        #expect(AnnotateTool.allCases.map(\.key).joined() == "vcrathpnf")
        #expect(AnnotateTool.allCases.map(\.title) == [
            "Select", "Crop", "Rectangle", "Arrow", "Text", "Highlight", "Redact", "Steps", "Freehand",
        ])
        let rectangle = try #require(canvas.document.items.first)
        canvas.setSelection(rectangle.id)
        canvas.model.strokeWidth = 7
        canvas.model.color = .black
        #expect(canvas.document.item(rectangle.id)?.width == 7)
        #expect(canvas.document.item(rectangle.id)?.color == .black)
    }

    @Test func pressingPAgainCyclesThePixelateBlurBlackoutStyles() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        var saved: [AnnotateSettings] = []
        canvas.model.actions = AnnotateActions(settingsChanged: { saved.append($0) })
        #expect(canvas.model.redactStyle == .pixelate)
        canvas.model.pick(.redact)
        #expect(canvas.model.tool == .redact && canvas.model.redactStyle == .pixelate)
        canvas.model.pick(.redact)
        #expect(canvas.model.redactStyle == .blur)
        canvas.model.pick(.redact)
        #expect(canvas.model.redactStyle == .blackout)
        canvas.model.pick(.redact)
        #expect(canvas.model.redactStyle == .pixelate)
        #expect(saved.map(\.redactStyle) == [.blur, .blackout, .pixelate])
        canvas.model.pick(.rectangle)
        canvas.model.pick(.redact)
        #expect(canvas.model.redactStyle == .pixelate, "switching tools does not cycle")
    }

    @Test func highlightColorAndRedactStyleStartFromTheSavedSettings() {
        let settings = AnnotateSettings(highlightColor: RGBAColor(hex: "#30D158") ?? .black, redactStyle: .blur)
        let model = AnnotateEditorModel(actions: AnnotateActions(settings: settings))
        #expect(model.redactStyle == .blur)
        #expect(model.highlightColor.hex == "#30D158")
        #expect(AnnotateEditorModel().highlightColor.hex == "#FFD60A")
    }

    @Test func styleControlsChangeOnlyTheMatchingSelectedItem() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        canvas.addItem(.highlight(CGRect(x: 10, y: 10, width: 80, height: 20)))
        let highlight = try #require(canvas.document.items.last)
        canvas.model.color = .black
        #expect(canvas.document.item(highlight.id)?.color.hex == "#FFD60A", "the stroke color leaves a highlight alone")
        canvas.model.highlightColor = RGBAColor(hex: "#30D158") ?? .black
        #expect(canvas.document.item(highlight.id)?.color.hex == "#30D158")

        canvas.addItem(.redact(CGRect(x: 100, y: 100, width: 60, height: 30), style: .pixelate))
        let region = try #require(canvas.document.items.last)
        canvas.model.redactStyle = .blackout
        #expect(canvas.document.item(region.id)?.kind == .blackout)
        #expect(canvas.document.item(region.id)?.box == region.box)
        canvas.undo()
        #expect(canvas.document.item(region.id)?.kind == .pixelate)
    }

    @Test func stepToolPlacesNumberedCirclesAndFreehandKeepsItsPoints() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        canvas.addItem(.step(at: CGPoint(x: 40, y: 400)))
        canvas.addItem(.step(at: CGPoint(x: 80, y: 400)))
        #expect(canvas.document.stepNumbers.values.sorted() == [1, 2])
        canvas.setSelection(canvas.document.items[canvas.document.items.count - 2].id)
        canvas.deleteSelection()
        #expect(canvas.document.stepNumbers.values.sorted() == [1])
        canvas.addItem(.freehand([CGPoint(x: 5, y: 5), CGPoint(x: 30, y: 20), CGPoint(x: 60, y: 8)]))
        canvas.nudgeSelection(dx: 1, dy: 0, large: true)
        #expect(canvas.document.items.last?.points.first == CGPoint(x: 15, y: 5))
        #expect(try Flattener.flatten(canvas.document).width == document.image.width)
    }

    @Test func annotateCropAndExport() throws {
        let document = try #require(AnnotateDemo.makeDocument())
        let canvas = AnnotateCanvasView(document: document)
        var copied: (CGImage, Double)?
        canvas.model.actions = AnnotateActions(copy: { copied = ($0, $1) })
        canvas.model.tool = .crop
        #expect(canvas.cropDraft == document.imageBounds)
        canvas.model.tool = .select
        var cropped = document
        cropped.crop(to: CGRect(x: 100, y: 100, width: 300, height: 200))
        let flat = try Flattener.flatten(cropped)
        #expect(flat.width == 600 && flat.height == 400)
        canvas.copyImage()
        #expect(copied?.0.width == document.image.width)
        #expect(copied?.1 == 2)
    }

    @Test func annotateWindowFitsTheImage() {
        let visible = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let small = AnnotateWindowController.windowSize(forImage: CGSize(width: 300, height: 200), visibleFrame: visible)
        #expect(small == Theme.Annotate.minimumSize)
        let large = AnnotateWindowController.windowSize(forImage: CGSize(width: 2560, height: 1440), visibleFrame: visible)
        #expect(large.width == 2048 && abs(large.height - 1132) < 0.001)
    }

    // MARK: Settings and shortcuts

    @Test func shortcutRecorderAcceptsOnlyGlobalCombos() {
        let commandShift = UInt(HotkeyCombo.EventFlag.command | HotkeyCombo.EventFlag.shift)
        #expect(ShortcutRecordingOutcome.interpret(keyCode: 21, modifierFlags: commandShift) == .record(.commandShift4))
        #expect(ShortcutRecordingOutcome.interpret(keyCode: 21, modifierFlags: 0) == .ignore)
        #expect(ShortcutRecordingOutcome.interpret(keyCode: 21, modifierFlags: UInt(HotkeyCombo.EventFlag.shift)) == .ignore)
        #expect(ShortcutRecordingOutcome.interpret(keyCode: 53, modifierFlags: 0) == .cancel)
        #expect(ShortcutRecordingOutcome.interpret(keyCode: 51, modifierFlags: 0) == .clear)
        #expect(ShortcutRecordingOutcome.interpret(keyCode: 122, modifierFlags: 0) == .record(KeyShortcut(keyCode: 122, modifiers: 0)))
        #expect(HotkeyCombo(.commandShift4).chipText == "\u{21E7} \u{2318} 4")
    }

    @Test func settingsModelShowsConflictsAndCallsInjectedClosures() {
        var saved: [SnapCore.Settings] = []
        var loginRequests: [Bool] = []
        let model = SettingsModel(actions: SettingsActions(
            settingsChanged: { saved.append($0) },
            setLaunchAtLogin: { loginRequests.append($0); return true },
            evaluateShortcuts: { shortcuts in
                HotkeyConflicts.evaluate(
                    shortcuts: shortcuts,
                    systemEntries: [SymbolicHotkeyEntry(id: 30, keyCode: 21, modifiers: KeyShortcut.commandShift4.modifiers, enabled: true)],
                    runningBundleIDs: []
                )
            }
        ))
        #expect(model.messages(for: .captureArea).count == 1)
        #expect(model.messages(for: .captureArea).first?.contains("System Settings") == true)
        #expect(model.hasSystemShortcutOverlap)
        #expect(!model.isWaitingForCleanShot)

        model.settings.shortcuts.captureArea = KeyShortcut(keyCode: 21, modifiers: KeyShortcut.Modifier.control | KeyShortcut.Modifier.shift)
        #expect(model.messages(for: .captureArea).isEmpty)
        #expect(saved.count == 1)

        model.setLaunchAtLogin(true)
        #expect(loginRequests == [true])
        #expect(model.settings.general.launchAtLogin)

        model.settings.shortcuts.applyBackground = model.settings.shortcuts.captureFullscreen
        #expect(model.messages(for: .applyBackground).first?.contains("already used") == true)
    }

    @Test func settingsLaunchAtLoginFailureKeepsTheOldValue() {
        let model = SettingsModel(actions: SettingsActions(setLaunchAtLogin: { _ in false }))
        model.setLaunchAtLogin(true)
        #expect(!model.settings.general.launchAtLogin)
        #expect(model.launchAtLoginError != nil)
    }

    @Test func settingsFileNamePreviewUsesThePattern() {
        let model = SettingsDemo.makeModel(tab: .general)
        #expect(model.fileNamePreview.hasPrefix("Still 2026-10-2"))
        #expect(model.fileNamePreview.hasSuffix(".png"))
        #expect(!model.fileNamePreview.contains(":"))
        #expect(model.saveFolderName == "Downloads")
    }

    // MARK: Menu

    @Test func statusMenuIsBuiltFromTheModelWithoutAStatusItem() throws {
        var chosen: [MenuItemID] = []
        let model = MenuDemo.makeModel()
        let controller = StatusMenuController(
            modelProvider: { model }, thumbnail: { MenuDemo.makeThumbnails()[$0] }, onSelect: { chosen.append($0) }
        )
        let items = controller.menu.items
        #expect(items.count == model.items.count)
        let area = try #require(items.first)
        #expect(area.title == "Capture Area")
        #expect(area.keyEquivalent == "4")
        #expect(area.keyEquivalentModifierMask == [.command, .shift])
        #expect(items.contains { $0.isSeparatorItem })
        let status = try #require(items.first { $0.title == MenuStatus.waitingForCleanShot.title })
        #expect(!status.isEnabled)
        let recent = try #require(items.first { $0.title.hasPrefix("Screenshot 14.03.22") })
        #expect(recent.image?.size == CGSize(width: 32, height: 32))
        let quit = try #require(items.last)
        #expect(quit.title == "Quit Still" && quit.keyEquivalent == "q")
        _ = quit.target?.perform(quit.action, with: quit)
        #expect(chosen == [.quit])
    }
}
