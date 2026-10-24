import Foundation
import SnapCore

/// `snapctl preset`: prints the first-run default Background preset, or with `--starred` the one
/// starred in `SNAP_HOME/presets.json`.
enum PresetCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            let preset: BackgroundPreset
            if parsed.flags.contains("--default") {
                preset = BackgroundPreset.factoryDefault
            } else if parsed.flags.contains("--starred") {
                let store = PresetStore(paths: SnapPaths())
                try store.load()
                preset = store.starred
            } else {
                throw UsageError("preset needs --default or --starred")
            }
            print(try describe(preset, json: parsed.json))
            return 0
        } catch {
            return exitStatus(for: error)
        }
    }

    static func describe(_ preset: BackgroundPreset, json: Bool) throws -> String {
        guard json else {
            return "\(preset.name): padding \(preset.padding), inset \(preset.inset), "
                + "cornerRadius \(preset.cornerRadius), shadow \(preset.shadow), alignment \(preset.alignment), "
                + "autoBalance \(preset.autoBalance)"
        }
        return try jsonString(preset)
    }

    static func jsonString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
