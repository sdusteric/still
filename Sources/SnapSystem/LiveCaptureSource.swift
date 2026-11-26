import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import SnapCore

/// Screen and window capture through ScreenCaptureKit (design 6.2 to 6.5). Compiled and linted,
/// but never run by a test, tool or agent: only the installed app calls it.
///
/// The shareable content is cached between captures (fetched with `excludingDesktopWindows: false`
/// so Finder's desktop-icon window is in the list to exclude) and refreshed in the background after
/// each capture. `displays()` always refetches it, which is what the coordinator's one stale retry uses.
///
/// The cache lists off-screen windows too. Still's panels are built once and only ordered in and
/// out, so they are in the list when a capture starts and the capture needs no refetch first: that
/// refetch made the frozen image 90 to 390 ms late, long enough for a popup or video to change.
public actor LiveCaptureSource: CaptureSource {
    static let finderBundleID = "com.apple.finder"

    private let log: Log?
    private let ownPID: pid_t
    private var content: SCShareableContent?
    private var refreshTask: Task<Void, Never>?
    private var finderObserver: (any NSObjectProtocol)?

    public init(log: Log? = nil) {
        self.log = log
        self.ownPID = ProcessInfo.processInfo.processIdentifier
    }

    // MARK: CaptureSource

    public func displays() async throws -> [DisplayInfo] {
        let content = try await fetchContent()
        return content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let colorSpace = CGDisplayCopyColorSpace(display.displayID).name.map { $0 as String }
            return DisplayInfo(
                id: display.displayID, frameTopLeft: display.frame,
                scale: Double(filter.pointPixelScale), colorSpaceName: colorSpace
            )
        }
    }

    public func captureDisplay(_ displayID: DisplayID, options: CaptureOptions) async throws -> CapturedImage {
        // Each step is timed and logged, so the latency line's frozen_ms can be split up.
        let clock = ContinuousClock()
        let start = clock.now
        let (content, own, source) = try await filterInputs(excluding: options.excludedWindowIDs)
        let contentDone = clock.now
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = makeDisplayFilter(display: display, content: content, options: options, own: own)
        let filterDone = clock.now
        let configuration = SCScreenshotConfiguration()
        configuration.dynamicRange = .sdr
        configuration.showsCursor = false
        let scale = Double(filter.pointPixelScale)
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())

        let image: CGImage
        do {
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
            guard let sdr = output.sdrImage else { throw CaptureError.failed("no SDR image for display \(displayID)") }
            image = sdr
        } catch {
            throw LiveCaptureSource.map(error, display: displayID)
        }
        let shotDone = clock.now
        log?.info(LiveCaptureSource.timingLine(
            display: displayID, content: source, contentSeconds: Self.seconds(contentDone - start),
            filterSeconds: Self.seconds(filterDone - contentDone), screenshotSeconds: Self.seconds(shotDone - filterDone),
            width: image.width, height: image.height
        ))
        scheduleRefresh()
        return CapturedImage(cgImage: image, scale: scale, displayID: displayID)
    }

    /// Part of one display (scrolling capture): only `rect`, in the display's top-left points,
    /// through `SCScreenshotConfiguration.sourceRect`, so each frame is small.
    public func captureRegion(_ displayID: DisplayID, rect: CGRect, options: CaptureOptions) async throws -> CapturedImage {
        let (content, own, _) = try await filterInputs(excluding: options.excludedWindowIDs)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = makeDisplayFilter(display: display, content: content, options: options, own: own)
        let configuration = SCScreenshotConfiguration()
        configuration.dynamicRange = .sdr
        configuration.showsCursor = false
        configuration.sourceRect = rect
        let scale = Double(filter.pointPixelScale)
        configuration.width = Int((rect.width * scale).rounded())
        configuration.height = Int((rect.height * scale).rounded())
        do {
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
            guard let image = output.sdrImage else { throw CaptureError.failed("no SDR image for display \(displayID)") }
            return CapturedImage(cgImage: image, scale: scale, displayID: displayID)
        } catch {
            throw LiveCaptureSource.map(error, display: displayID)
        }
    }

    /// One window, live, with a transparent background. `SCScreenshotConfiguration` has no
    /// `shouldBeOpaque`, so this path uses `captureImage` with a stream configuration.
    public func captureWindow(_ windowID: WindowID, options: CaptureOptions) async throws -> CapturedImage {
        let content = try await cachedContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        // The shadow makes the content rect larger than the window frame, so size from the filter.
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.shouldBeOpaque = false
        configuration.ignoreShadowsSingleWindow = !options.includeWindowShadow
        configuration.showsCursor = false
        configuration.captureDynamicRange = .SDR
        configuration.captureResolution = .best

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw LiveCaptureSource.map(error, window: windowID)
        }
        scheduleRefresh()
        return CapturedImage(cgImage: image, scale: scale, displayID: nil)
    }

    // MARK: Cache

    /// Drops the cached content and refetches it in the background. The app calls this on
    /// `didChangeScreenParametersNotification`; Finder relaunches are observed here.
    public func invalidate() {
        content = nil
        scheduleRefresh()
    }

    /// Starts watching for Finder relaunches, which replace the desktop-icon window.
    public func startObservingFinder() {
        guard finderObserver == nil else { return }
        finderObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard bundleID == LiveCaptureSource.finderBundleID, let self else { return }
            Task { await self.invalidate() }
        }
    }

    func cachedContent() async throws -> SCShareableContent {
        if let content { return content }
        return try await fetchContent()
    }

    func fetchContent() async throws -> SCShareableContent {
        do {
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            content = fresh
            return fresh
        } catch {
            throw LiveCaptureSource.map(error, display: nil)
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.fetchContent()
            } catch {
                self.log?.warning("capture: background content refresh failed: \(error)")
            }
        }
    }

    // MARK: Filters

    /// The cached content, and Still's windows to exclude that it lacks. A panel made since the last
    /// refresh comes from this process's own content, which is fast; only when that fails too is the
    /// whole list fetched again.
    private func filterInputs(
        excluding ids: [WindowID]
    ) async throws -> (SCShareableContent, [SCWindow], ContentSource) {
        let wasCached = content != nil
        let content = try await cachedContent()
        let missing = LiveCaptureSource.missing(ids, in: content.windows.map(\.windowID))
        guard !missing.isEmpty else { return (content, [], wasCached ? .cached : .fetched) }
        do {
            let own = try await SCShareableContent.currentProcess.windows.filter { missing.contains($0.windowID) }
            if LiveCaptureSource.missing(missing, in: own.map(\.windowID)).isEmpty { return (content, own, .ownWindows) }
        } catch {
            log?.warning("capture: own windows: \(error)")
        }
        log?.info("capture: refetching the window list for Still's panels")
        return (try await fetchContent(), [], .refetched)
    }

    /// Where a capture's window list came from, for the timing line.
    enum ContentSource: String {
        /// The cache, as it was.
        case cached
        /// No cache yet: fetched now.
        case fetched
        /// The cache plus this process's own windows (a panel made since the last refresh).
        case ownWindows = "own-windows"
        /// The whole list again: a panel was in neither.
        case refetched
    }

    static func timingLine(
        display: DisplayID, content: ContentSource, contentSeconds: Double, filterSeconds: Double,
        screenshotSeconds: Double, width: Int, height: Int
    ) -> String {
        func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
        return "capture timing display=\(display) content=\(content.rawValue) content_ms=\(ms(contentSeconds)) "
            + "filter_ms=\(ms(filterSeconds)) screenshot_ms=\(ms(screenshotSeconds)) size=\(width)x\(height)"
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The ids in `ids` that `known` lacks, each once.
    static func missing(_ ids: [WindowID], in known: [WindowID]) -> [WindowID] {
        let known = Set(known)
        var seen: Set<WindowID> = []
        return ids.filter { !known.contains($0) && seen.insert($0).inserted }
    }

    private func makeDisplayFilter(
        display: SCDisplay, content: SCShareableContent, options: CaptureOptions, own: [SCWindow] = []
    ) -> SCContentFilter {
        let excluded = (content.windows + own).filter { options.excludedWindowIDs.contains($0.windowID) }
        guard excluded.count == Set(options.excludedWindowIDs).count else {
            // The panels are still missing after a refetch: leave out all of Snap instead. The
            // coordinator lists only panels that are on screen, so this is a rare race. That
            // filter cannot also drop Finder's icon window, so icons stay visible for this capture.
            if let own = content.applications.first(where: { $0.processID == ownPID }) {
                log?.warning("capture: Snap panels not in shareable content; excluding Snap by app, desktop icons not hidden")
                return SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
            }
            log?.warning("capture: Snap panels and Snap missing from shareable content")
            return SCContentFilter(display: display, excludingWindows: excluded)
        }
        var windows = excluded
        if options.hideDesktopIcons {
            let icons = desktopIconWindows(in: content, display: display)
            if icons.isEmpty { log?.info("capture: no desktop icon window found on display \(display.displayID)") }
            windows.append(contentsOf: icons)
        }
        return SCContentFilter(display: display, excludingWindows: windows)
    }

    /// Finder's desktop-icon windows on `display` (design 6.3): matched by bundle id and the
    /// `.desktopIconWindow` level, or, if `SCWindow.windowLayer` reports something else, by the
    /// window number CGWindowList lists at that level.
    func desktopIconWindows(in content: SCShareableContent, display: SCDisplay) -> [SCWindow] {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let finderWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == LiveCaptureSource.finderBundleID && $0.frame.intersects(display.frame)
        }
        let byLayer = finderWindows.filter { $0.windowLayer == iconLevel }
        if !byLayer.isEmpty { return byLayer }
        let listed = LiveCaptureSource.cgWindowIDs(atLayer: iconLevel, ownerName: "Finder")
        return finderWindows.filter { listed.contains($0.windowID) }
    }

    private static func cgWindowIDs(atLayer layer: Int, ownerName: String) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids: Set<CGWindowID> = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == layer,
                  entry[kCGWindowOwnerName as String] as? String == ownerName,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            ids.insert(number.uint32Value)
        }
        return ids
    }

    static func containsAll(_ ids: [WindowID], in content: SCShareableContent) -> Bool {
        guard !ids.isEmpty else { return true }
        let known = Set(content.windows.map(\.windowID))
        return ids.allSatisfy { known.contains($0) }
    }

    // MARK: Errors

    /// Maps ScreenCaptureKit errors: -3801 (user declined) is a permission problem; a missing
    /// display or window list means the filter was built from stale content.
    static func map(_ error: any Error, display: DisplayID? = nil, window: WindowID? = nil) -> CaptureError {
        if let captureError = error as? CaptureError { return captureError }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case PermissionState.userDeclinedErrorCode:
                return .permissionDenied
            case SCStreamError.Code.noDisplayList.rawValue, SCStreamError.Code.noWindowList.rawValue,
                 SCStreamError.Code.noCaptureSource.rawValue, SCStreamError.Code.invalidParameter.rawValue:
                if let window { return .windowNotFound(window) }
                if let display { return .displayNotFound(display) }
            default:
                break
            }
        }
        return .failed("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
    }
}
