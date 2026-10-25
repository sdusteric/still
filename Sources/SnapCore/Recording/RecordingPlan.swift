import CoreGraphics
import CoreVideo
import Foundation

/// Why a recording plan cannot be made. The HUD shows these on its size chip.
public enum RecordingPlanError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The output would be smaller than 64 x 64 px after rounding down to even sizes.
    case tooSmall(PixelSize)
    /// The target names a display that is not connected, or an area that touches no display.
    case noDisplay
    /// An empty area or window frame.
    case emptyTarget

    public var description: String {
        switch self {
        case .tooSmall: "Too small to record"
        case .noDisplay: "No display for this recording"
        case .emptyTarget: "Nothing to record"
        }
    }
}

/// Every value the live recorder passes to ScreenCaptureKit, computed without it (design 20.6,
/// D60). `LiveRecordingSource` only copies fields: the filter, `sourceRect`, the output size,
/// frame interval, queue depth, cursor and click flags, colour space, audio and codec.
public struct RecordingPlan: Sendable, Hashable {
    public static let minimumPixelSide = 64
    public static let queueDepth = 6
    public static let audioSampleRate = 48_000
    public static let audioChannelCount = 2

    /// Which content filter the live code builds.
    public enum FilterKind: String, Sendable, Hashable, Codable {
        /// `SCContentFilter(display:excludingWindows:)` cropped by `sourceRect` (area).
        case displayExcludingWindows
        /// `SCContentFilter(desktopIndependentWindow:)` (window).
        case desktopIndependentWindow
        /// `SCContentFilter(display:excludingWindows:)` uncropped (fullscreen).
        case wholeDisplay
    }

    public var target: RecordingTarget
    public var filterKind: FilterKind
    /// The display recorded from (area and fullscreen), or the display the window is mostly on.
    public var displayID: DisplayID
    /// Set for the window filter.
    public var windowID: WindowID?
    /// Snap's panels (overlay, countdown, outline, HUD, Quick Access, hint) and, when Hide desktop
    /// icons is on, Finder's icon window. Pins are not listed: they are content (D62). Empty for
    /// the window filter, which shows one window only.
    public var excludedWindowIDs: [WindowID]
    /// Display-local points for area and fullscreen, window-local points for a window. Its size
    /// times `scale` equals `pixelSize`, so pixels map one to one.
    public var sourceRect: CGRect
    /// Where the recording is on screen in global top-left points (area and window), for item.json.
    public var screenRect: CGRect?
    /// Pixels per point of the output: the display scale for Retina, 1 for the 1x setting.
    public var scale: Double
    /// Even width and height, at least 64 x 64.
    public var pixelSize: PixelSize
    public var fps: Int
    public var queueDepth: Int
    public var showsCursor: Bool
    public var showsMouseClicks: Bool
    /// The window shadow is never recorded (D60).
    public var ignoresShadowsSingleWindow: Bool
    /// `CGColorSpace.sRGB`: players and chat apps assume sRGB and BT.709 for video.
    public var colorSpaceName: String
    /// `kCVImageBufferYCbCrMatrix_ITU_R_709_2`.
    public var colorMatrix: String
    public var capturesAudio: Bool
    public var excludesCurrentProcessAudio: Bool
    public var audioSampleRate: Int
    public var audioChannelCount: Int
    public var capturesMicrophone: Bool
    /// nil records from the system default input.
    public var microphoneDeviceID: String?
    public var codec: VideoFormat
    /// `history/<id>/<file name>.mp4`; nil until the controller has written `item.json`.
    public var outputURL: URL?

    /// `minimumFrameInterval` in seconds: 1/30 or 1/60.
    public var minimumFrameInterval: TimeInterval { 1 / Double(fps) }

    /// The audio sources the file carries.
    public var audioSources: [AudioSource] {
        var sources: [AudioSource] = []
        if capturesAudio { sources.append(.system) }
        if capturesMicrophone { sources.append(.microphone) }
        return sources
    }

    /// Builds the plan for `target`.
    /// - Parameters:
    ///   - settings: the Recording tab plus Hide desktop icons from the Capture tab.
    ///   - excludedWindowIDs: Snap's own panels.
    ///   - desktopIconWindowIDs: Finder's icon windows, excluded when Hide desktop icons is on.
    public static func make(
        target: RecordingTarget,
        displays: [DisplayInfo],
        settings: Settings,
        excludedWindowIDs: [WindowID] = [],
        desktopIconWindowIDs: [WindowID] = []
    ) throws -> RecordingPlan {
        let recording = settings.recording
        var exclusions = Set(excludedWindowIDs)
        if settings.capture.hideDesktopIcons { exclusions.formUnion(desktopIconWindowIDs) }
        let sortedExclusions = exclusions.sorted()

        let filterKind: FilterKind
        let display: DisplayInfo
        let scale: Double
        let pixelSize: PixelSize
        let sourceRect: CGRect
        var screenRect: CGRect?
        var windowID: WindowID?

        switch target {
        case .area(let rect):
            let area = rect.standardized
            guard area.width > 0, area.height > 0 else { throw RecordingPlanError.emptyTarget }
            guard let found = bestDisplay(for: area, in: displays) else { throw RecordingPlanError.noDisplay }
            display = found
            scale = outputScale(recording.scale, display: found)
            let clipped = area.intersection(found.frameTopLeft)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw RecordingPlanError.noDisplay }
            let local = clipped.offsetBy(dx: -found.frameTopLeft.minX, dy: -found.frameTopLeft.minY)
            // Snap the origin to the output pixel grid, then size the rect from the even pixel size.
            let originX = floorToGrid(local.minX, scale: scale)
            let originY = floorToGrid(local.minY, scale: scale)
            pixelSize = try evenPixelSize(
                width: local.maxX - originX, height: local.maxY - originY, scale: scale
            )
            sourceRect = CGRect(
                x: originX, y: originY,
                width: Double(pixelSize.width) / scale, height: Double(pixelSize.height) / scale
            )
            screenRect = sourceRect.offsetBy(dx: found.frameTopLeft.minX, dy: found.frameTopLeft.minY)
            filterKind = .displayExcludingWindows

        case .window(let window):
            let frame = window.frame.standardized
            guard frame.width > 0, frame.height > 0 else { throw RecordingPlanError.emptyTarget }
            guard let found = bestDisplay(for: frame, in: displays) else { throw RecordingPlanError.noDisplay }
            display = found
            scale = outputScale(recording.scale, display: found)
            pixelSize = try evenPixelSize(width: frame.width, height: frame.height, scale: scale)
            sourceRect = CGRect(
                x: 0, y: 0, width: Double(pixelSize.width) / scale, height: Double(pixelSize.height) / scale
            )
            screenRect = CGRect(origin: frame.origin, size: sourceRect.size)
            windowID = window.id
            filterKind = .desktopIndependentWindow

        case .fullscreen(let displayID):
            guard let found = displays.first(where: { $0.id == displayID }) else { throw RecordingPlanError.noDisplay }
            display = found
            scale = outputScale(recording.scale, display: found)
            pixelSize = try evenPixelSize(
                width: found.frameTopLeft.width, height: found.frameTopLeft.height, scale: scale
            )
            sourceRect = CGRect(
                x: 0, y: 0, width: Double(pixelSize.width) / scale, height: Double(pixelSize.height) / scale
            )
            filterKind = .wholeDisplay
        }

        return RecordingPlan(
            target: target,
            filterKind: filterKind,
            displayID: display.id,
            windowID: windowID,
            excludedWindowIDs: filterKind == .desktopIndependentWindow ? [] : sortedExclusions,
            sourceRect: sourceRect,
            screenRect: screenRect,
            scale: scale,
            pixelSize: pixelSize,
            fps: RecordingSettings.normalizedFPS(recording.fps),
            queueDepth: queueDepth,
            showsCursor: recording.showCursor,
            showsMouseClicks: recording.highlightClicks,
            ignoresShadowsSingleWindow: true,
            colorSpaceName: CGColorSpace.sRGB as String,
            colorMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
            capturesAudio: recording.systemAudio,
            excludesCurrentProcessAudio: true,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount,
            capturesMicrophone: recording.microphone,
            microphoneDeviceID: recording.microphone ? recording.microphoneDeviceID : nil,
            codec: recording.format,
            outputURL: nil
        )
    }

    /// Rounds `points * scale` down to whole pixels, then down to an even number, and refuses
    /// anything under 64 px on a side.
    public static func evenPixelSize(width: Double, height: Double, scale: Double) throws -> PixelSize {
        let size = PixelSize(width: evenDown(width * scale), height: evenDown(height * scale))
        guard size.width >= minimumPixelSide, size.height >= minimumPixelSide else {
            throw RecordingPlanError.tooSmall(size)
        }
        return size
    }

    static func evenDown(_ pixels: Double) -> Int {
        // A small epsilon keeps 330.5 * 2 from landing on 660.9999.
        let whole = Int((pixels + 1e-6).rounded(.down))
        return max(whole - whole % 2, 0)
    }

    static func floorToGrid(_ points: Double, scale: Double) -> Double {
        ((points * scale) + 1e-6).rounded(.down) / scale
    }

    static func outputScale(_ setting: RecordingScale, display: DisplayInfo) -> Double {
        switch setting {
        case .retina: display.scale > 0 ? display.scale : 1
        case .oneX: 1
        }
    }

    /// The display a rect overlaps most; ties go to the earlier display.
    static func bestDisplay(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (display: DisplayInfo, area: Double)?
        for display in displays {
            let overlap = rect.intersection(display.frameTopLeft)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (display, area) }
        }
        return best?.display
    }

    /// One line for `snap.log` and the status menu: `target=area size=1280x800 fps=30 codec=avc1 audio=none`.
    public var logSummary: String {
        let audio = audioSources.isEmpty ? "none" : audioSources.map(\.rawValue).joined(separator: ",")
        return "target=\(target.mode.rawValue) size=\(pixelSize) fps=\(fps) codec=\(codec.fourCC) audio=\(audio)"
    }
}
