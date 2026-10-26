import Foundation
import SnapCore

// Headless tool: links SnapCore only, so it never loads ScreenCaptureKit, never shows a window
// and never captures the screen. Every capture it runs goes through the fakes.

let usage = """
    usage: snapctl gen-fixture <name> --out <png>
           snapctl beautify <in.png> --out <out.png> [--preset default|<json>]
                    [--background solid:#RRGGBB|gradient:<name>|mesh:<name>|blurred|image:<path>|none]
                    [--ratio W:H] [--no-autobalance] [--report]
           snapctl preset --default --json
           snapctl history gen --items N --days D [--seed S] [--now <ISO date>] [--json]
           snapctl history list [--query q] [--kind image|video] [--runs R] [--now <ISO date>] --json
           snapctl history sweep [--now <ISO date>] [--skip id,...] --json
           snapctl history recover --json
           snapctl record --fake --target area|window|fullscreen --display WxH@S [--rect x,y,w,h] --frames N
                    --fps F [--codec h264|hevc] [--audio system,microphone] [--kill-after-frames K]
                    [--countdown S] [--runs R] --json
           snapctl probe <file.mp4> --json
           snapctl annotate --in <png> --doc <json|path> --out <png> [--report]
           snapctl recall fixture --line <text> [--line <text> ...] [--source-app <name>] [--age-days N]
           snapctl recall build [--fake-ocr <file.json>] [--json]
           snapctl recall list [--json]
    """

/// A usage mistake: printed with the usage text, exit status 64.
struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parsed command line: positional arguments, boolean flags and `--name value` options.
struct CommandArguments {
    static let valueOptions: Set<String> = [
        "--out", "--preset", "--background", "--ratio",
        // history
        "--items", "--days", "--seed", "--now", "--query", "--kind", "--runs", "--skip",
        // record, probe and annotate
        "--target", "--display", "--rect", "--frames", "--fps", "--codec", "--audio", "--kill-after-frames",
        "--countdown", "--in", "--doc",
        // recall
        "--source-app", "--age-days", "--fake-ocr",
    ]

    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if CommandArguments.valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { throw UsageError("\(argument) needs a value") }
                options[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") { flags.insert(argument) } else { positional.append(argument) }
            index += 1
        }
    }

    var json: Bool { flags.contains("--json") }

    /// An output path from `--out`, required.
    func outputURL() throws -> URL {
        guard let path = options["--out"], !path.isEmpty else { throw UsageError("missing --out <path>") }
        return URL(filePath: path).standardizedFileURL
    }
}

/// Reports a thrown error and returns the exit status for it.
func exitStatus(for error: any Error) -> Int32 {
    if let usageError = error as? UsageError {
        FileHandle.standardError.write(Data("snapctl: \(usageError)\n\(usage)\n".utf8))
        return 64
    }
    FileHandle.standardError.write(Data("snapctl: \(error)\n".utf8))
    return 1
}

/// Subcommands that are not built yet print this and exit 64.
func notImplemented(_ command: String) -> Int32 {
    FileHandle.standardError.write(Data("snapctl: \(command): not implemented\n".utf8))
    return 64
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(64)
}
let rest = Array(arguments.dropFirst())

let status: Int32
switch command {
case "gen-fixture":
    status = await FixtureCommand.run(rest)
case "beautify":
    status = await BeautifyCommand.run(rest)
case "preset":
    status = await PresetCommand.run(rest)
case "history":
    status = await HistoryCommand.run(rest)
case "record":
    status = await RecordCommand.run(rest)
case "probe":
    status = await ProbeCommand.run(rest)
case "annotate":
    status = await AnnotateCommand.run(rest)
case "recall":
    status = await RecallCommand.run(rest)
case "latency":
    FileHandle.standardError.write(Data("snapctl: latency moved to snapbench latency (it drives the SnapUI controllers)\n".utf8))
    status = 64
case "-h", "--help", "help":
    print(usage)
    status = 0
default:
    FileHandle.standardError.write(Data("snapctl: unknown command \(command)\n\(usage)\n".utf8))
    status = 64
}
exit(status)
