import CoreGraphics
import Foundation

/// Options for one capture, taken from settings at the time of the hotkey.
public struct CaptureOptions: Sendable, Hashable {
    /// Exclude Finder's desktop-icon window from display captures (design 6.3).
    public var hideDesktopIcons: Bool
    /// Include the system window shadow in window captures (design 6.5). Option-click flips it.
    public var includeWindowShadow: Bool
    /// Windows to leave out of display captures: Snap's own panels that are on screen for this
    /// capture (the overlay when shown, the Quick Access stack, the permission hint).
    public var excludedWindowIDs: [WindowID]

    public init(hideDesktopIcons: Bool = true, includeWindowShadow: Bool = true, excludedWindowIDs: [WindowID] = []) {
        self.hideDesktopIcons = hideDesktopIcons
        self.includeWindowShadow = includeWindowShadow
        self.excludedWindowIDs = excludedWindowIDs
    }
}

/// Why a capture failed.
public enum CaptureError: Error, Sendable, Hashable {
    /// Screen Recording permission is missing or lapsed (including `SCStreamErrorUserDeclined`).
    case permissionDenied
    case displayNotFound(DisplayID)
    case windowNotFound(WindowID)
    /// Any other failure, with the underlying error text for the log.
    case failed(String)
}

/// Produces screen images. Live: ScreenCaptureKit in SnapSystem. Fake: generated images in
/// `FakeCaptureSource`, so the coordinator runs in tests and `snapctl` without the screen.
public protocol CaptureSource: Sendable {
    /// The displays that can be captured, in the global top-left point space.
    func displays() async throws -> [DisplayInfo]
    /// One display, at its native pixel size, excluding the windows in `options`.
    func captureDisplay(_ displayID: DisplayID, options: CaptureOptions) async throws -> CapturedImage
    /// One window, live, with a transparent background and, if requested, its shadow.
    func captureWindow(_ windowID: WindowID, options: CaptureOptions) async throws -> CapturedImage
    /// Part of one display, `rect` in the display's own top-left points (scrolling capture).
    func captureRegion(_ displayID: DisplayID, rect: CGRect, options: CaptureOptions) async throws -> CapturedImage
}

extension CaptureSource {
    /// The whole display, cropped. The live source asks ScreenCaptureKit for the region only.
    public func captureRegion(_ displayID: DisplayID, rect: CGRect, options: CaptureOptions) async throws -> CapturedImage {
        let full = try await captureDisplay(displayID, options: options)
        let pixels = CGRect(
            x: rect.minX * full.scale, y: rect.minY * full.scale, width: rect.width * full.scale, height: rect.height * full.scale
        ).integral
        guard let cropped = full.cgImage.cropping(to: pixels) else {
            throw CaptureError.failed("region \(rect) is outside display \(displayID)")
        }
        return CapturedImage(cgImage: cropped, scale: full.scale, displayID: displayID)
    }
}

extension CaptureSource {
    /// Every display at once, in parallel. The result is in the order of `displayIDs`.
    public func captureDisplays(_ displayIDs: [DisplayID], options: CaptureOptions) async throws -> [CapturedImage] {
        try await withThrowingTaskGroup(of: (Int, CapturedImage).self) { group in
            for (index, id) in displayIDs.enumerated() {
                group.addTask { (index, try await self.captureDisplay(id, options: options)) }
            }
            var images = [CapturedImage?](repeating: nil, count: displayIDs.count)
            for try await (index, image) in group {
                images[index] = image
            }
            return images.compactMap { $0 }
        }
    }
}
