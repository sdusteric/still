import CoreGraphics
import Foundation
import SnapCore
import Synchronization
import Testing

/// Records every overlay call. `selection()` waits until the test (or a frozen image) resolves it,
/// and `dismiss()` resolves a pending selection with `.cancelled`, as the live panels do.
@MainActor
private final class RecordingOverlay: OverlayPresenter {
    enum Call: Equatable {
        case present(CaptureMode)
        case presentHUD(HUDMode, area: CGRect?)
        case frozen(DisplayID)
        case windows(Int)
        case dismiss
    }

    var calls: [Call] = []
    /// Capture source calls seen at the moment `present` ran.
    var sourceCallsAtPresent: Int?
    var onPresent: (() -> Void)?
    /// The HUD's mode switch callback, so a test can play the user pressing R.
    var hudModeChanged: (@MainActor (HUDMode) -> Void)?
    /// When set, the first frozen image resolves the selection with this value.
    var selectAfterFrozen: OverlaySelection?
    private var pending: CheckedContinuation<OverlaySelection, Never>?
    private var queued: OverlaySelection?

    func present(mode: CaptureMode, displays: [DisplayInfo]) {
        calls.append(.present(mode))
        onPresent?()
    }

    func presentHUD(_ state: AllInOneState, displays: [DisplayInfo], modeChanged: @escaping @MainActor (HUDMode) -> Void) {
        calls.append(.presentHUD(state.mode, area: state.area))
        hudModeChanged = modeChanged
        onPresent?()
    }

    func showFrozen(_ image: CapturedImage, displayID: DisplayID) {
        calls.append(.frozen(displayID))
        if let selection = selectAfterFrozen {
            selectAfterFrozen = nil
            resolve(selection)
        }
    }

    func updateWindows(_ windows: [WindowInfo]) { calls.append(.windows(windows.count)) }

    func selection() async -> OverlaySelection {
        if let queued {
            self.queued = nil
            return queued
        }
        return await withCheckedContinuation { pending = $0 }
    }

    func dismiss() {
        calls.append(.dismiss)
        resolve(.cancelled)
    }

    func resolve(_ selection: OverlaySelection) {
        if let pending {
            self.pending = nil
            pending.resume(returning: selection)
        } else {
            queued = selection
        }
    }

    var dismissCount: Int { calls.filter { $0 == .dismiss }.count }
}

@MainActor
private final class RecordingResults: CaptureResultPresenter {
    var cards: [CaptureResult] = []
    var stored: [StoredCapture] = []
    var failures: [CaptureFailure] = []
    /// Events already in the trace when `showCard` ran.
    var orderAtCard: [CaptureEvent] = []

    func showCard(for capture: CaptureResult) {
        cards.append(capture)
        orderAtCard = capture.trace.order
    }

    func captureStored(_ stored: StoredCapture) { self.stored.append(stored) }
    func captureFailed(_ failure: CaptureFailure) { failures.append(failure) }
}

private final class RecordingClipboard: ClipboardWriting {
    private let images = Mutex<[Data]>([])
    private let urls = Mutex<[URL]>([])

    func writeImage(pngData: Data, image: CGImage, scale: Double) throws {
        images.withLock { $0.append(pngData) }
    }

    func writeFileURL(_ url: URL) throws {
        urls.withLock { $0.append(url) }
    }

    var writtenImages: [Data] { images.withLock { $0 } }
}

/// Wraps a fake source and throws a stale-content error for the first `staleDisplays` display
/// captures and the first `staleWindows` window captures.
private final class StaleSource: CaptureSource {
    let base: FakeCaptureSource
    private let remainingDisplays: Mutex<Int>
    private let remainingWindows: Mutex<Int>
    private let displayCalls = Atomic<Int>(0)
    private let captureCalls = Atomic<Int>(0)
    private let windowCalls = Atomic<Int>(0)

    init(base: FakeCaptureSource, staleDisplays: Int, staleWindows: Int = 0) {
        self.base = base
        self.remainingDisplays = Mutex(staleDisplays)
        self.remainingWindows = Mutex(staleWindows)
    }

    var displaysCount: Int { displayCalls.load(ordering: .relaxed) }
    var captureCount: Int { captureCalls.load(ordering: .relaxed) }
    var windowCount: Int { windowCalls.load(ordering: .relaxed) }

    func displays() async throws -> [DisplayInfo] {
        displayCalls.add(1, ordering: .relaxed)
        return try await base.displays()
    }

    func captureDisplay(_ displayID: DisplayID, options: CaptureOptions) async throws -> CapturedImage {
        captureCalls.add(1, ordering: .relaxed)
        if StaleSource.take(remainingDisplays) { throw CaptureError.displayNotFound(displayID) }
        return try await base.captureDisplay(displayID, options: options)
    }

    func captureWindow(_ windowID: WindowID, options: CaptureOptions) async throws -> CapturedImage {
        windowCalls.add(1, ordering: .relaxed)
        if StaleSource.take(remainingWindows) { throw CaptureError.windowNotFound(windowID) }
        return try await base.captureWindow(windowID, options: options)
    }

    private static func take(_ remaining: borrowing Mutex<Int>) -> Bool {
        remaining.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
    }
}

@MainActor
private struct Harness {
    let home: URL
    let overlay = RecordingOverlay()
    let results = RecordingResults()
    let clipboard = RecordingClipboard()
    let history: HistoryStore
    let coordinator: CaptureCoordinator

    init(
        source: any CaptureSource,
        windows: FakeWindowSource = FakeWindowSource(),
        clock: any Clock = SystemClock(),
        configuration: CaptureConfiguration = CaptureConfiguration()
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "snap-coordinator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = SnapPaths(home: home)
        history = HistoryStore(paths: paths, clock: clock)
        let stage = CaptureOutputStage(history: history, clipboard: clipboard, clock: clock)
        coordinator = CaptureCoordinator(
            captureSource: source, windowSource: windows, overlay: overlay, results: results,
            output: stage, clock: clock, configuration: { configuration }
        )
    }

    func cleanUp() {
        do { try FileManager.default.removeItem(at: home) } catch { Issue.record("cleanup failed: \(error)") }
    }
}

@MainActor
@Suite struct CaptureCoordinatorTests {
    let display = DisplayInfo.fake5K
    let selection = CGRect(x: 400, y: 200, width: 842, height: 516)

    @Test func areaCaptureFollowsTheDesignedEventOrder() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        let stored = try #require(await ticket.stored.value)

        #expect(ticket.result.trace.order == [.present, .frozen, .confirm, .card, .encode, .history, .clipboard])
        #expect(LatencyLog.followsCanonicalOrder(ticket.result.trace.order))
        #expect(harness.results.orderAtCard == [.present, .frozen, .confirm])
        #expect(harness.results.stored.count == 1)
        #expect(stored.copied)
        #expect(harness.clipboard.writtenImages.count == 1)
    }

    @Test func storedItemKeepsTheScreenRectAndPixelSize() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        let stored = try #require(await ticket.stored.value)
        let image = ticket.result.image.cgImage

        #expect(stored.item.screenRect == ticket.result.rect)
        #expect(stored.item.pixelSize == PixelSize(width: image.width, height: image.height))
        // The item.json on disk carries both, so a pin from history opens at the captured rect.
        let reread = try #require(try harness.history.item(id: stored.item.id))
        #expect(reread.screenRect == ticket.result.rect)
        #expect(reread.pixelSize == PixelSize(width: image.width, height: image.height))
    }

    @Test func theOverlayDoesNotWaitForTheCaptureAndTheCaptureDoesNotWaitForTheOverlay() async throws {
        // The screenshot starts off the main thread before the overlay is drawn, so the frozen
        // image lands about one screenshot's time after the hotkey (design 6.2, 2026-11-26).
        let clock = FakeClock()
        let source = FakeCaptureSource(displays: [display], delay: 1, clock: clock)
        let harness = try Harness(source: source, clock: clock)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()

        let began = await harness.coordinator.begin(mode: .area)
        #expect(began)
        #expect(harness.overlay.calls.first == .present(.area))
        #expect(harness.coordinator.lastTrace?.order == [.present])

        // The capture is still waiting on the clock: the overlay is up with no frozen image.
        while clock.sleeperCount == 0 { await Task.yield() }
        #expect(!harness.overlay.calls.contains(.frozen(display.id)))
        clock.advance(by: 1)
        while !harness.overlay.calls.contains(.frozen(display.id)) { await Task.yield() }
        #expect(harness.coordinator.lastTrace?.order == [.present, .frozen])
        await harness.coordinator.confirm(.cancelled)
    }

    @Test func selectionMadeBeforeTheFrozenImageWaitsForIt() async throws {
        let clock = FakeClock()
        let source = FakeCaptureSource(displays: [display], delay: 0.5, clock: clock)
        let harness = try Harness(source: source, clock: clock)
        defer { harness.cleanUp() }
        harness.overlay.resolve(.area(displayID: display.id, rect: selection))

        let run = Task { await harness.coordinator.run(mode: .area) }
        while clock.sleeperCount == 0 { await Task.yield() }
        #expect(harness.results.cards.isEmpty)
        clock.advance(by: 0.5)
        let ticket = try #require(await run.value)
        _ = await ticket.stored.value
        #expect(ticket.result.trace.order.prefix(4) == [.present, .confirm, .frozen, .card])
        #expect(ticket.result.image.pixelWidth == 1684)
    }

    @Test func areaCropUsesDisplayPixels() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        let stored = try #require(await ticket.stored.value)
        #expect(ticket.result.image.pixelWidth == 1684)
        #expect(ticket.result.image.pixelHeight == 1032)
        #expect(ticket.result.image.scale == 2)
        #expect(ticket.result.rect == selection)

        let written = try PNGReader.read(stored.item.originalURL)
        #expect(written.pixelWidth == 1684)
        #expect(written.scale == 2)
        #expect(stored.item.originalURL.path(percentEncoded: false).hasPrefix(harness.home.path(percentEncoded: false)))
    }

    @Test func cropOnAOneXDisplayKeepsPointSize() throws {
        let ultrawide = DisplayInfo.fakeUltrawide
        let image = try #require(SyntheticImages.gradientGrid(width: 3440, height: 1440))
        let frozen = CapturedImage(cgImage: image, scale: 1, displayID: ultrawide.id)
        let (cropped, rect) = try CaptureCoordinator.crop(
            frozen, to: CGRect(x: 3400, y: 10, width: 100, height: 50), on: ultrawide
        )
        // Clamped to the display's right edge.
        #expect(cropped.pixelWidth == 40)
        #expect(cropped.pixelHeight == 50)
        #expect(rect.maxX == 3440)
    }

    @Test func windowSelectionCapturesTheWindowLiveWithItsShadowSetting() async throws {
        let source = FakeCaptureSource(displays: [display])
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        let notes = try #require(FakeWindowSource.sample.first { $0.ownerName == "Notes" })
        harness.overlay.resolve(.window(notes, includeShadow: false))

        let ticket = try #require(await harness.coordinator.run(mode: .window))
        _ = await ticket.stored.value
        #expect(source.recordedCalls.contains { call in
            if case .window(notes.id, let options) = call { return options.includeWindowShadow == false }
            return false
        })
        #expect(ticket.result.image.pixelWidth == Int(notes.frame.width * 2))
        #expect(ticket.result.sourceApp == "Notes")
        #expect(ticket.result.trace.order.first == .present)
        #expect(LatencyLog.followsCanonicalOrder(ticket.result.trace.order))
    }

    @Test func windowListReachesTheOverlay() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        #expect(await harness.coordinator.begin(mode: .window))
        for _ in 0..<10_000 where !harness.overlay.calls.contains(.windows(FakeWindowSource.sample.count)) {
            await Task.yield()
        }
        #expect(harness.overlay.calls.contains(.windows(FakeWindowSource.sample.count)))
        await harness.coordinator.confirm(.cancelled)
    }

    @Test func cancelDismissesWithoutACard() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        harness.overlay.resolve(.cancelled)

        let ticket = await harness.coordinator.run(mode: .area)
        #expect(ticket == nil)
        #expect(harness.overlay.dismissCount == 1)
        #expect(harness.results.cards.isEmpty)
        #expect(!harness.coordinator.isCapturing)
        #expect(try harness.history.allItems().isEmpty)
    }

    @Test func secondHotkeyWhileCapturingIsIgnored() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        #expect(await harness.coordinator.begin(mode: .area))
        #expect(await harness.coordinator.begin(mode: .area) == false)
        await harness.coordinator.confirm(.cancelled)
        #expect(!harness.coordinator.isCapturing)
    }

    @Test func staleFilterErrorTriggersExactlyOneRetry() async throws {
        let source = StaleSource(base: FakeCaptureSource(displays: [display]), staleDisplays: 1)
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()
        let displaysBefore = source.displaysCount
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        _ = await ticket.stored.value
        #expect(source.captureCount == 2)
        #expect(source.displaysCount == displaysBefore + 1)
        #expect(harness.results.failures.isEmpty)
    }

    @Test func persistentStaleErrorRetriesOnceThenFails() async throws {
        let source = StaleSource(base: FakeCaptureSource(displays: [display]), staleDisplays: 10)
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()

        let ticket = await harness.coordinator.run(mode: .area)
        #expect(ticket == nil)
        #expect(source.captureCount == 2)
        #expect(harness.results.failures.count == 1)
        #expect(harness.results.failures.first?.captureError == .displayNotFound(display.id))
        #expect(harness.overlay.dismissCount == 1)
        #expect(!harness.coordinator.isCapturing)
    }

    @Test func windowCaptureRetriesOnceOnStaleContent() async throws {
        let source = StaleSource(base: FakeCaptureSource(displays: [display]), staleDisplays: 0, staleWindows: 1)
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()
        let displaysBefore = source.displaysCount
        let notes = try #require(FakeWindowSource.sample.first { $0.ownerName == "Notes" })
        harness.overlay.resolve(.window(notes, includeShadow: true))

        let ticket = try #require(await harness.coordinator.run(mode: .window))
        _ = await ticket.stored.value
        #expect(source.windowCount == 2)
        #expect(source.displaysCount == displaysBefore + 1)
        #expect(harness.results.failures.isEmpty)
    }

    @Test func permissionErrorIsReportedAndClosesTheOverlay() async throws {
        let source = FakeCaptureSource(displays: [display])
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()
        source.setFailure(.permissionDenied)

        let ticket = await harness.coordinator.run(mode: .area)
        #expect(ticket == nil)
        #expect(harness.results.failures.count == 1)
        #expect(harness.results.failures.first?.isPermissionError == true)
        #expect(harness.overlay.dismissCount == 1)
    }

    @Test func fullscreenSkipsTheOverlayAndUsesTheDisplayUnderThePointer() async throws {
        let displays = DisplayInfo.fakeSideBySide
        let harness = try Harness(source: FakeCaptureSource(displays: displays))
        defer { harness.cleanUp() }

        let ticket = try #require(await harness.coordinator.run(mode: .fullscreen, pointer: CGPoint(x: 3000, y: 700)))
        _ = await ticket.stored.value
        #expect(harness.overlay.calls.isEmpty)
        #expect(ticket.result.image.pixelWidth == 3440)
        #expect(ticket.result.image.scale == 1)
        #expect(ticket.result.trace.order == [.frozen, .confirm, .card, .encode, .history, .clipboard])
    }

    /// Regression: fullscreen never orders the overlay panels in, so listing them made the live
    /// source fall back to excluding all of Snap, which leaves the desktop icons in.
    @Test func fullscreenExcludesOnScreenPanelsButNotTheHiddenOverlay() async throws {
        let source = FakeCaptureSource(displays: [display])
        let configuration = CaptureConfiguration(
            options: CaptureOptions(hideDesktopIcons: true, excludedWindowIDs: [9001]),
            overlayWindowIDs: [7001]
        )
        let harness = try Harness(source: source, configuration: configuration)
        defer { harness.cleanUp() }

        let ticket = try #require(await harness.coordinator.run(mode: .fullscreen))
        _ = await ticket.stored.value
        let excluded = source.recordedCalls.compactMap { call -> [WindowID]? in
            if case .display(_, let options) = call { return options.excludedWindowIDs }
            return nil
        }
        #expect(excluded == [[9001]])
    }

    /// Regression: a Quick Access card from an earlier capture is excluded with the overlay panels.
    @Test func areaCaptureExcludesTheOverlayAndTheQuickAccessPanel() async throws {
        let source = FakeCaptureSource(displays: [display])
        let configuration = CaptureConfiguration(
            options: CaptureOptions(excludedWindowIDs: [9001]),
            overlayWindowIDs: [7001, 7002]
        )
        let harness = try Harness(source: source, configuration: configuration)
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        _ = await ticket.stored.value
        let excluded = source.recordedCalls.compactMap { call -> [WindowID]? in
            if case .display(_, let options) = call { return options.excludedWindowIDs }
            return nil
        }
        #expect(excluded.map(Set.init) == [Set([9001, 7001, 7002])])
    }

    @Test func selectingARegionEndsAtTheSelectionWithNoCard() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)
        let region = try #require(await harness.coordinator.selectRegion())
        #expect(region.display.id == display.id)
        #expect(region.rect == selection)
        #expect(harness.results.cards.isEmpty)
        #expect(harness.overlay.dismissCount == 1)
        #expect(!harness.coordinator.isCapturing)

        harness.overlay.selectAfterFrozen = .cancelled
        #expect(await harness.coordinator.selectRegion() == nil)
    }

    @Test func aDeliveredImageIsStoredLikeACapture() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        let tall = try #require(SyntheticImages.gradientGrid(width: 200, height: 1200))
        let ticket = harness.coordinator.deliverCapture(CapturedImage(cgImage: tall, scale: 2), rect: selection)
        let stored = try #require(await ticket.stored.value)
        #expect(harness.results.cards.count == 1)
        #expect(stored.item.pixelSize == PixelSize(width: 200, height: 1200))
        #expect(stored.item.mode == .area)
        #expect(harness.clipboard.writtenImages.count == 1)
    }

    @Test func previousAreaCapturesTheStoredRectWithoutTheOverlay() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        let area = try #require(LastArea.store(selection, displays: [display]))

        let ticket = try #require(await harness.coordinator.runPreviousArea(area))
        _ = await ticket.stored.value
        #expect(harness.overlay.calls.isEmpty)
        #expect(ticket.result.mode == .area)
        #expect(ticket.result.rect == selection)
        #expect(ticket.result.image.pixelWidth == 1684)
        #expect(!harness.coordinator.isCapturing)
    }

    @Test func previousAreaOnAChangedDisplayCapturesNothing() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        let moved = LastArea(displayID: display.id, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rect: selection)
        #expect(await harness.coordinator.runPreviousArea(moved) == nil)
        #expect(!harness.coordinator.isCapturing)
    }

    @Test func aFailedHistoryWriteStillCopiesAndIsReported() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        // A file where the history folder should be makes every history write fail.
        let historyPath = SnapPaths(home: harness.home).historyDirectory.path(percentEncoded: false)
        #expect(FileManager.default.createFile(atPath: historyPath, contents: Data()))
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        #expect(await ticket.stored.value == nil)
        #expect(harness.clipboard.writtenImages.count == 1)
        let failure = try #require(harness.results.failures.last)
        #expect(failure.stage == .output)
        #expect(failure.traceID == ObjectIdentifier(ticket.result.trace))
        #expect(failure.copied)
    }

    @Test func clipboardOffLeavesThePasteboardAlone() async throws {
        let configuration = CaptureConfiguration(copyToClipboard: false)
        let harness = try Harness(source: FakeCaptureSource(displays: [display]), configuration: configuration)
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        let stored = try #require(await ticket.stored.value)
        #expect(!stored.copied)
        #expect(harness.clipboard.writtenImages.isEmpty)
        #expect(!ticket.result.trace.order.contains(.clipboard))
    }

    @Test func saveToFolderWritesACopyInsideSnapHome() async throws {
        let saveHome = FileManager.default.temporaryDirectory
            .appending(path: "snap-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: saveHome) } catch { Issue.record("\(error)") }
        }
        let folder = SnapPaths(home: saveHome).defaultSaveFolder
        let harness = try Harness(
            source: FakeCaptureSource(displays: [display]),
            configuration: CaptureConfiguration(saveFolder: folder)
        )
        defer { harness.cleanUp() }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let ticket = try #require(await harness.coordinator.run(mode: .area))
        let stored = try #require(await ticket.stored.value)
        let saved = try #require(stored.savedURL)
        #expect(FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)))
        #expect(saved.lastPathComponent.hasPrefix("Still "))
        #expect(ticket.result.trace.order.last == .save)
    }

    @Test func concurrentSavesWithTheSameNameKeepEveryFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "snap-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: home) } catch { Issue.record("\(error)") }
        }
        let folder = SnapPaths(home: home).defaultSaveFolder
        // Noise encodes to a large PNG, so the old check-then-rename window was wide enough to lose files.
        let image = try #require(SyntheticImages.noise(width: 1600, height: 1000))
        let date = Date(timeIntervalSince1970: 1_792_843_200)
        let runs = 12
        let saved = Mutex<[URL]>([])
        // Every run has the same timestamp, so all of them want the same file name at once.
        DispatchQueue.concurrentPerform(iterations: runs) { run in
            // Separate history stores, so the runs reach the save step together, as a Quick Access
            // Save and a capture's own save can.
            let history = HistoryStore(paths: SnapPaths(home: home.appending(path: "run-\(run)", directoryHint: .isDirectory)))
            let stage = CaptureOutputStage(history: history, clipboard: nil)
            let result = CaptureResult(
                mode: .area, image: CapturedImage(cgImage: image, scale: 2), createdAt: date,
                rect: CGRect(x: 0, y: 0, width: 400, height: 300),
                trace: CaptureTrace(mode: .area, triggerTime: 0)
            )
            do {
                let stored = try stage.run(result, configuration: CaptureConfiguration(saveFolder: folder))
                if let url = stored.savedURL { saved.withLock { $0.append(url) } }
            } catch {
                Issue.record("run failed: \(error)")
            }
        }
        let urls = saved.withLock { $0 }
        #expect(Set(urls).count == runs)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(files.filter { $0.hasSuffix(".png") }.count == runs)
    }

    @Test func configurationFollowsSettings() {
        var settings = Settings()
        settings.capture.copyToClipboard = false
        settings.capture.saveToFolder = true
        settings.capture.includeWindowShadow = false
        let home = URL(filePath: "/tmp/snap-config-test", directoryHint: .isDirectory)
        let configuration = CaptureConfiguration(
            settings: settings, paths: SnapPaths(home: home), overlayWindowIDs: [5], excludedWindowIDs: [7]
        )
        #expect(configuration.copyToClipboard == false)
        #expect(configuration.options.includeWindowShadow == false)
        #expect(configuration.options.excludedWindowIDs == [7])
        #expect(configuration.captureOptions(overlayShown: false).excludedWindowIDs == [7])
        #expect(configuration.captureOptions(overlayShown: true).excludedWindowIDs == [7, 5])
        #expect(configuration.saveFolder?.path(percentEncoded: false).hasPrefix("/tmp/snap-config-test") == true)
    }

    @Test func latencyLineHasTheDocumentedShape() {
        let trace = CaptureTrace(mode: .area, triggerTime: 10)
        trace.record(.present, at: 10.004)
        trace.record(.frozen, at: 10.020)
        trace.record(.confirm, at: 11)
        trace.record(.card, at: 11.0015)
        #expect(LatencyLog.line(for: trace) == "latency mode=area overlay_ms=4.0 frozen_ms=20.0 card_ms=1.5")

        let fullscreen = CaptureTrace(mode: .fullscreen, triggerTime: 0)
        #expect(LatencyLog.line(for: fullscreen) == "latency mode=fullscreen overlay_ms=- frozen_ms=- card_ms=-")
    }

    @Test func orderCheckRejectsEncodingBeforeTheCard() {
        #expect(LatencyLog.followsCanonicalOrder([.present, .frozen, .confirm, .card, .encode, .history, .clipboard]))
        #expect(LatencyLog.followsCanonicalOrder([.frozen, .confirm, .card, .encode, .history]))
        #expect(!LatencyLog.followsCanonicalOrder([.present, .frozen, .confirm, .encode, .card]))
        #expect(!LatencyLog.followsCanonicalOrder([.present, .frozen, .confirm, .card, .encode, .clipboard, .history]))
        #expect(!LatencyLog.followsCanonicalOrder([.present, .present]))
    }

    @Test func percentilesUseNearestRank() throws {
        let values = (1...50).map(Double.init)
        let summary = try #require(LatencyLog.summarize(values))
        #expect(summary.p50 == 25)
        #expect(summary.p95 == 48)
        #expect(summary.max == 50)
        #expect(LatencyLog.summarize([]) == nil)
    }

    // MARK: All-in-one HUD (design 20.5, D59)

    private func hudState(_ mode: HUDMode) -> AllInOneState {
        AllInOneState(
            mode: mode, target: .area,
            lastArea: LastArea(displayID: display.id, displayFrame: display.frameTopLeft, rect: selection),
            displays: [display]
        )
    }

    private func displayCaptures(_ source: FakeCaptureSource) -> Int {
        source.recordedCalls.filter { if case .display = $0 { true } else { false } }.count
    }

    @Test func hudScreenshotModeCropsTheFrozenImageAndStoresTheLastArea() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        var stored: [LastArea] = []
        harness.coordinator.onAreaConfirmed = { stored.append($0) }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)

        let outcome = await harness.coordinator.runHUD(hudState(.screenshot))
        let ticket = try #require(outcome.ticket)
        _ = await ticket.stored.value
        #expect(harness.overlay.calls.first == .presentHUD(.screenshot, area: selection))
        #expect(ticket.result.trace.order.prefix(4) == [.present, .frozen, .confirm, .card])
        #expect(ticket.result.mode == .area)
        #expect(ticket.result.image.pixelWidth == 1684)
        #expect(stored == [LastArea(displayID: display.id, displayFrame: display.frameTopLeft, rect: selection)])
        #expect(harness.overlay.dismissCount == 1)
    }

    @Test func hudRecordModeRequestsNoFrozenCaptureAndLeavesTheOverlayUp() async throws {
        let source = FakeCaptureSource(displays: [display])
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()
        var stored: [LastArea] = []
        harness.coordinator.onAreaConfirmed = { stored.append($0) }
        harness.overlay.resolve(.record(.area(selection)))

        let outcome = await harness.coordinator.runHUD(hudState(.record))
        guard case .record(let target, let trace) = outcome else {
            Issue.record("expected a recording, got \(outcome)")
            return
        }
        #expect(target == .area(selection))
        #expect(trace.order == [.present, .confirm])
        #expect(displayCaptures(source) == 0)
        #expect(!harness.overlay.calls.contains(.frozen(display.id)))
        // The countdown runs on the same panels, so the coordinator does not dismiss them.
        #expect(harness.overlay.dismissCount == 0)
        #expect(!harness.coordinator.isCapturing)
        #expect(harness.results.cards.isEmpty)
        #expect(stored.map(\.rect) == [selection])
        #expect(try harness.history.allItems().isEmpty)
    }

    @Test func switchingTheHUDToScreenshotStartsTheFrozenCaptures() async throws {
        let source = FakeCaptureSource(displays: [display])
        let harness = try Harness(source: source)
        defer { harness.cleanUp() }
        try await harness.coordinator.refreshDisplays()
        #expect(await harness.coordinator.beginHUD(hudState(.record)))
        #expect(displayCaptures(source) == 0)

        harness.overlay.hudModeChanged?(.screenshot)
        for _ in 0..<10_000 where !harness.overlay.calls.contains(.frozen(display.id)) { await Task.yield() }
        #expect(displayCaptures(source) == 1)
        #expect(harness.overlay.calls.contains(.frozen(display.id)))
        // Back to Record and to Screenshot again: the capture already running is reused.
        harness.overlay.hudModeChanged?(.record)
        harness.overlay.hudModeChanged?(.screenshot)
        #expect(displayCaptures(source) == 1)

        let ticket = try #require(await harness.coordinator.confirm(.area(displayID: display.id, rect: selection)))
        _ = await ticket.stored.value
        #expect(ticket.result.image.pixelHeight == 1032)
    }

    @Test func hudFullscreenAndWindowTargetsKeepTheirModes() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        var stored: [LastArea] = []
        harness.coordinator.onAreaConfirmed = { stored.append($0) }
        harness.overlay.resolve(.fullscreen(displayID: display.id))
        let fullscreen = try #require(await harness.coordinator.runHUD(hudState(.screenshot)).ticket)
        _ = await fullscreen.stored.value
        #expect(fullscreen.result.mode == .fullscreen)
        #expect(fullscreen.result.image.pixelWidth == display.pixelWidth)
        #expect(fullscreen.result.rect == display.frameTopLeft)
        #expect(stored.isEmpty)

        let window = try #require(FakeWindowSource.sample.first)
        harness.overlay.resolve(.window(window, includeShadow: false))
        let windowTicket = try #require(await harness.coordinator.runHUD(hudState(.screenshot)).ticket)
        _ = await windowTicket.stored.value
        #expect(windowTicket.result.mode == .window)
        #expect(windowTicket.result.sourceApp == window.ownerName)
    }

    @Test func plainAreaCaptureAlsoStoresTheLastArea() async throws {
        let harness = try Harness(source: FakeCaptureSource(displays: [display]))
        defer { harness.cleanUp() }
        var stored: [LastArea] = []
        harness.coordinator.onAreaConfirmed = { stored.append($0) }
        harness.overlay.selectAfterFrozen = .area(displayID: display.id, rect: selection)
        let ticket = try #require(await harness.coordinator.run(mode: .area))
        _ = await ticket.stored.value
        #expect(stored.map(\.rect) == [selection])
        #expect(stored.first?.restore(on: [display]) == selection)
    }
}
