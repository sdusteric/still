import Foundation
import SnapCore

// Headless tool: links SnapCore only, so it never loads ScreenCaptureKit, never shows a window
// and never captures the screen. Every capture it runs goes through the fakes.

let usage = """
    usage: snapctl gen-fixture <name> --out <png>
           snapctl beautify <in.png> --out <out.png> [--preset default|<json>]
                    [--background solid:#RRGGBB|gradient:<name>|none] [--ratio W:H] [--no-autobalance] [--report]
           snapctl preset --default --json
           snapctl latency --fake --runs N --display WxH@S [--capture-delay-ms D] --json
    """

/// A usage mistake: printed with the usage text, exit status 64.
struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parsed command line: positional arguments, boolean flags and `--name value` options.
struct CommandArguments {
    static let valueOptions: Set<String> = [
        "--out", "--preset", "--background", "--ratio", "--runs", "--display", "--capture-delay-ms",
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

    func int(_ name: String, default value: Int) throws -> Int {
        guard let text = options[name] else { return value }
        guard let parsed = Int(text), parsed >= 0 else { throw UsageError("\(name) must be a whole number") }
        return parsed
    }

    func double(_ name: String, default value: Double) throws -> Double {
        guard let text = options[name] else { return value }
        guard let parsed = Double(text), parsed >= 0 else { throw UsageError("\(name) must be a number") }
        return parsed
    }

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

/// Subcommands that are not built yet print this and exit 2.
func notImplemented(_ command: String) -> Int32 {
    FileHandle.standardError.write(Data("snapctl: \(command) is not implemented\n".utf8))
    return 2
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
case "latency":
    status = await LatencyCommand.run(rest)
case "-h", "--help", "help":
    print(usage)
    status = 0
default:
    FileHandle.standardError.write(Data("snapctl: unknown command \(command)\n\(usage)\n".utf8))
    status = 64
}
exit(status)
