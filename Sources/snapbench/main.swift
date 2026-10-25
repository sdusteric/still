import Foundation

// Headless benchmark: links SnapCore and SnapUI (AppKit, never SnapSystem), so it never loads
// ScreenCaptureKit, never makes a window and never captures the screen. Captures go through the
// fakes and the UI controllers run without panels.

let usage = """
    usage: snapbench latency --fake [--mode area|hud] [--record] --runs N --display WxH@S [--capture-delay-ms D] [--json]
    """

/// A usage mistake: printed with the usage text, exit status 64.
struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parsed command line: boolean flags and `--name value` options.
struct BenchArguments {
    static let valueOptions: Set<String> = ["--runs", "--display", "--capture-delay-ms", "--mode"]

    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if BenchArguments.valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { throw UsageError("\(argument) needs a value") }
                options[argument] = arguments[index + 1]
                index += 2
                continue
            }
            guard argument.hasPrefix("--") else { throw UsageError("unexpected argument \(argument)") }
            flags.insert(argument)
            index += 1
        }
    }

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
}

/// Reports a thrown error and returns the exit status for it.
func exitStatus(for error: any Error) -> Int32 {
    if let usageError = error as? UsageError {
        FileHandle.standardError.write(Data("snapbench: \(usageError)\n\(usage)\n".utf8))
        return 64
    }
    FileHandle.standardError.write(Data("snapbench: \(error)\n".utf8))
    return 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
let status: Int32
switch arguments.first {
case "latency":
    status = await LatencyBench.run(Array(arguments.dropFirst()))
case "-h", "--help", "help":
    print(usage)
    status = 0
default:
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    status = 64
}
exit(status)
