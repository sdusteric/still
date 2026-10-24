import CoreGraphics
import Foundation
import SnapCore

/// `snapctl beautify`: renders a capture with a Background preset (design 10.2) and, with --report, prints its geometry.
enum BeautifyCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            guard let input = parsed.positional.first else { throw UsageError("beautify needs an input png") }
            let output = try parsed.outputURL()

            var preset = try loadPreset(parsed.options["--preset"])
            if let text = parsed.options["--background"] {
                guard let fill = BackgroundFill(parsing: text) else {
                    throw UsageError("--background must be solid:#RRGGBB, gradient:<name>, image:<path> or none")
                }
                preset.background = fill
            }
            if let text = parsed.options["--ratio"] {
                guard let ratio = AspectRatio(parsing: text) else { throw UsageError("--ratio must look like 16:9") }
                preset.ratio = ratio
            }
            if parsed.flags.contains("--no-autobalance") { preset.autoBalance = false }

            let captured = try PNGReader.read(URL(filePath: input).standardizedFileURL)
            let result = try BeautifyRenderer.render(captured.cgImage, scale: captured.scale, preset: preset)
            try PNGWriter.write(result.image, scale: result.geometry.outputScale, to: output)
            if parsed.flags.contains("--report") {
                print(try PresetCommand.jsonString(result.geometry))
            }
            return 0
        } catch {
            return exitStatus(for: error)
        }
    }

    /// `default` is the first-run preset, `starred` the one in SNAP_HOME/presets.json, anything
    /// starting with `{` inline JSON, and anything else a path to a JSON file.
    static func loadPreset(_ text: String?) throws -> BackgroundPreset {
        guard let text, text != "default" else { return BackgroundPreset.factoryDefault }
        if text == "starred" {
            let store = PresetStore(paths: SnapPaths())
            try store.load()
            return store.starred
        }
        let data: Data
        if text.hasPrefix("{") {
            data = Data(text.utf8)
        } else {
            data = try Data(contentsOf: URL(filePath: text).standardizedFileURL)
        }
        do {
            return try JSONDecoder().decode(BackgroundPreset.self, from: data)
        } catch {
            throw UsageError("--preset is not a valid preset: \(error)")
        }
    }
}
