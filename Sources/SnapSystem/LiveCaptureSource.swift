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
        var content = try await cachedContent()
        guard content.displays.contains(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        // Snap's panels that are on screen now (the overlay when shown, a Quick Access card) may be
        // missing from a list cached before they were ordered in: refetch once before capturing.
        if !LiveCaptureSource.containsAll(options.excludedWindowIDs, in: content) {
            content = try await fetchContent()
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = makeDisplayFilter(display: display, content: content, options: options)
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
        scheduleRefresh()
        return CapturedImage(cgImage: image, scale: scale, displayID: displayID)
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

    private func cachedContent() async throws -> SCShareableContent {
        if let content { return content }
        return try await fetchContent()
    }

    private func fetchContent() async throws -> SCShareableContent {
        do {
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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

    private func makeDisplayFilter(display: SCDisplay, content: SCShareableContent, options: CaptureOptions)
        -> SCContentFilter {
        let excluded = content.windows.filter { options.excludedWindowIDs.contains($0.windowID) }
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
    private func desktopIconWindows(in content: SCShareableContent, display: SCDisplay) -> [SCWindow] {
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

    private static func containsAll(_ ids: [WindowID], in content: SCShareableContent) -> Bool {
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
