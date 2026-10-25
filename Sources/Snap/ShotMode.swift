import AppKit
import CoreGraphics
import Foundation
import SnapCore

/// `Snap --shot <scenario> --appearance light|dark --out <png> [--scale 2]`.
struct ShotOptions: Sendable {
    var scenario: ShotScenario
    var dark: Bool
    var output: URL
    var scale: Double

    nonisolated static let usage = "usage: Snap --shot <scenario> --appearance light|dark --out <png> [--scale 2]\n"
        + "scenarios: " + ShotScenario.allCases.map(\.rawValue).joined(separator: ", ")

    static func parse(_ arguments: [String]) -> Result<ShotOptions, ShotError> {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard ["--shot", "--appearance", "--out", "--scale"].contains(name) else {
                return .failure(.usage("unknown argument \(name)"))
            }
            guard index + 1 < arguments.count else { return .failure(.usage("\(name) needs a value")) }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard let name = values["--shot"], let scenario = ShotScenario(rawValue: name) else {
            return .failure(.usage("unknown scenario \(values["--shot"] ?? "")"))
        }
        let dark: Bool
        switch values["--appearance"] ?? "light" {
        case "light": dark = false
        case "dark": dark = true
        case let other: return .failure(.usage("--appearance must be light or dark, not \(other)"))
        }
        guard let path = values["--out"], path.hasSuffix(".png") else {
            return .failure(.usage("--out <path>.png is required"))
        }
        let scale = values["--scale"].flatMap(Double.init) ?? 2
        guard scale >= 1, scale <= 4 else { return .failure(.usage("--scale must be between 1 and 4")) }
        return .success(ShotOptions(
            scenario: scenario, dark: dark, output: URL(filePath: path).standardizedFileURL, scale: scale
        ))
    }
}

enum ShotError: Error, CustomStringConvertible {
    case usage(String)
    case renderFailed(String)
    case wrongSize(expected: String, actual: String)
    case foregroundApp

    var description: String {
        switch self {
        case .usage(let message): "\(message)\n\(ShotOptions.usage)"
        case .renderFailed(let scenario): "\(scenario) rendered no image"
        case .wrongSize(let expected, let actual): "rendered \(actual) px, expected \(expected) px"
        case .foregroundApp: "the process became a regular (foreground) app while rendering; LSUIElement is not in effect"
        }
    }
}

/// The headless shot mode (design 16, D27). It never calls `NSApplication.run`, never creates an
/// `NSWindow` or `NSPanel` and never uses a SnapSystem live type: the scenario is drawn from fakes
/// and demo builders, AppKit trees through `cacheDisplay(in:to:)` and SwiftUI through
/// `ImageRenderer`, with the appearance set on the root view. A bare `RunLoop.main` serves the
/// main queue so SwiftUI can finish its layout between passes.
///
/// Rendering an AppKit or SwiftUI view does instantiate `NSApplication.shared` (`NSApp` is set
/// after the first `.view` scenario), which registers the process with the window server. The
/// bundle's `LSUIElement` is what keeps that registration a UIElement, so shot mode runs only from
/// the bundle (see `isUIElement`), and it checks the activation policy again before writing.
enum ShotMode {
    /// Exit status when the binary is not running from a bundle whose Info.plist sets `LSUIElement`.
    static let notInBundleStatus: Int32 = 78

    /// Shot mode draws through AppKit, which creates `NSApp` and registers the process. Only the
    /// bundle's `LSUIElement` keeps that registration a UIElement (no Dock icon, no activation); a
    /// bare `.build/release/Snap` would register as a foreground app. So the mode refuses to run
    /// unless the Info.plist it was launched with sets `LSUIElement` to true.
    static func isUIElement(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "true", "yes"].contains(text.lowercased())
        default: false
        }
    }

    static func run(_ options: ShotOptions) -> Never {
        guard isUIElement(Bundle.main.object(forInfoDictionaryKey: "LSUIElement")) else {
            report("refusing to run: shot mode only runs from the Snap.app bundle, whose Info.plist sets "
                + "LSUIElement (build it with scripts/bundle.sh and run Snap.app/Contents/MacOS/Snap)")
            exit(notInBundleStatus)
        }
        Task { @MainActor in
            let status: Int32
            do {
                let image = try await render(options)
                // Rendering created NSApp; it must still be a UIElement, never a foreground app.
                guard NSRunningApplication.current.activationPolicy != .regular else {
                    throw ShotError.foregroundApp
                }
                try write(image, scale: options.scale, to: options.output)
                print("wrote \(options.output.path(percentEncoded: false)) (\(image.width)x\(image.height))")
                status = 0
            } catch {
                report("\(error)")
                status = 1
            }
            exit(status)
        }
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    static func fail(_ error: ShotError) -> Never {
        report("\(error)")
        exit(64)
    }

    private static func render(_ options: ShotOptions) async throws -> CGImage {
        let scenario = options.scenario
        let image: CGImage?
        switch scenario.content(dark: options.dark, scale: options.scale) {
        case .image(let rendered):
            image = rendered
        case .view(let view):
            // Two passes with a run loop turn between them, so state SwiftUI applies after the
            // first layout (preview renders, observation updates) is in the final pixels.
            _ = cacheDisplay(view, scale: options.scale)
            try await Task.sleep(for: .milliseconds(150))
            image = cacheDisplay(view, scale: options.scale)
        }
        guard let image else { throw ShotError.renderFailed(scenario.rawValue) }
        let expected = (Int((scenario.pointSize.width * options.scale).rounded()),
                        Int((scenario.pointSize.height * options.scale).rounded()))
        guard image.width == expected.0, image.height == expected.1 else {
            throw ShotError.wrongSize(expected: "\(expected.0)x\(expected.1)", actual: "\(image.width)x\(image.height)")
        }
        return image
    }

    /// Draws `view` into a bitmap of `scale` pixels per point with no window. The bitmap is
    /// tagged sRGB so colors pass through unconverted for the pixel checks.
    static func cacheDisplay(_ view: NSView, scale: Double) -> CGImage? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int((size.width * scale).rounded()),
                  pixelsHigh: Int((size.height * scale).rounded()),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let tagged = bitmap.retagging(with: .sRGB) else { return nil }
        tagged.size = size
        view.layoutSubtreeIfNeeded()
        // Without a window every layer rasterizes at 1x and text comes out soft at 2x, so the
        // layers are told the target scale and redrawn before the capture.
        if let layer = view.layer { setContentsScale(scale, of: layer) }
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: tagged)
        return tagged.cgImage
    }

    private static func setContentsScale(_ scale: Double, of layer: CALayer) {
        // Only SwiftUI's drawing layers (text, shapes) and text fields are redrawn. Image layers
        // (SF Symbols) and AppKit control parts (popup arrows) hold set contents that a redraw
        // would empty.
        let drawing = NSStringFromClass(type(of: layer)).hasSuffix("CGDrawingLayer")
        if layer.contentsScale != scale, drawing || layer.delegate is NSTextField {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
        for sublayer in layer.sublayers ?? [] { setContentsScale(scale, of: sublayer) }
    }

    /// PNG at 72 DPI times the scale, written to a temp file in the same folder and renamed.
    private static func write(_ image: CGImage, scale: Double, to url: URL) throws {
        let data = try PNGWriter.data(for: image, scale: scale)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appending(path: ".\(url.lastPathComponent).shot-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temp)
        if rename(temp.path(percentEncoded: false), url.path(percentEncoded: false)) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("Snap --shot: \(message)\n".utf8))
    }
}
