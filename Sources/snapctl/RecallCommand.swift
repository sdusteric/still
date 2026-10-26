import Foundation
import SnapCore

/// `snapctl recall` (Recall design 11 and 12), over `SNAP_HOME`:
/// - `fixture --line <text> ... [--source-app <name>] [--age-days N]`: draws the lines with
///   SyntheticText and adds the PNG to history, back-dated by N days.
/// - `build [--fake-ocr <file.json>] [--json]`: reconciles the recall folder with history and waits
///   for the queue, with Vision or with a fake that maps file names to lines.
/// - `list [--json]`: the entries in the recall folder.
/// Every subcommand refuses the default SNAP_HOME, so it never touches the real history or Shelf.
enum RecallCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let sub = arguments.first else { throw UsageError("recall needs fixture, build or list") }
            var rest = Array(arguments.dropFirst())
            let lines = takeRepeated("--line", from: &rest)
            let parsed = try CommandArguments(rest)
            let paths = SnapPaths()
            guard !paths.isDefaultHome else {
                throw UsageError("recall \(sub) refuses the default SNAP_HOME; set SNAP_HOME to a temp folder")
            }
            try paths.createDirectories()
            switch sub {
            case "fixture": return try fixture(lines: lines, parsed, paths: paths)
            case "build": return try await build(parsed, paths: paths)
            case "list": return try list(parsed, paths: paths)
            default: throw UsageError("unknown recall command \(sub)")
            }
        } catch {
            return exitStatus(for: error)
        }
    }

    /// Removes every `name value` pair from `arguments` and returns the values in order.
    static func takeRepeated(_ name: String, from arguments: inout [String]) -> [String] {
        var values: [String] = []
        var kept: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == name, index + 1 < arguments.count {
                values.append(arguments[index + 1])
                index += 2
            } else {
                kept.append(arguments[index])
                index += 1
            }
        }
        arguments = kept
        return values
    }

    private static func fixture(lines: [String], _ parsed: CommandArguments, paths: SnapPaths) throws -> Int32 {
        guard !lines.isEmpty else { throw UsageError("recall fixture needs at least one --line") }
        let days = try parsed.options["--age-days"].map { value -> Double in
            guard let days = Double(value), days >= 0 else { throw UsageError("--age-days must be a number of days") }
            return days
        } ?? 0
        let png = try SyntheticText.png(lines: lines, size: CGSize(width: 1600, height: 140 + 58 * lines.count), fontSize: 36)
        let created = Date().addingTimeInterval(-days * 86_400)
        let item = try HistoryStore(paths: paths).add(
            pngData: png, fileName: "Snap fixture \(Int(created.timeIntervalSince1970)).png", mode: .area, scale: 1,
            sourceApp: parsed.options["--source-app"], createdAt: created
        )
        print(item.id)
        return 0
    }

    private static func build(_ parsed: CommandArguments, paths: SnapPaths) async throws -> Int32 {
        let history = HistoryStore(paths: paths)
        let recognizer: any TextRecognizer
        if let file = parsed.options["--fake-ocr"] {
            let map = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(filePath: file)))
            recognizer = FakeTextRecognizer(results: map.mapValues { lines in
                OCRResult(imageName: "", language: nil, lines: lines.map { .init(text: $0, confidence: 1, box: [0, 0, 1, 1]) })
            })
        } else {
            recognizer = VisionTextRecognizer()
        }
        let settings = SettingsStore(paths: paths)
        do {
            try settings.load()
        } catch {
            FileHandle.standardError.write(Data("snapctl: settings.json unreadable, using defaults: \(error)\n".utf8))
        }
        let indexer = RecallIndexer(
            history: history, ocr: OCRStore(history: history), recognizer: recognizer,
            writer: RecallWriter(directory: paths.recallDirectory), options: RecallOptions(settings.settings.general), log: nil
        )
        await indexer.reconcile()
        await indexer.drain()
        return try list(parsed, paths: paths)
    }

    private struct Listed: Encodable {
        var id: String
        var title: String
        var segments: [String]
        var preview: String?
    }

    private static func list(_ parsed: CommandArguments, paths: SnapPaths) throws -> Int32 {
        let writer = RecallWriter(directory: paths.recallDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var listed: [Listed] = []
        for id in try writer.storedIDs().sorted() {
            let url = paths.recallDirectory.appending(path: "\(id).json", directoryHint: .notDirectory)
            let entry = try decoder.decode(RecallEntry.self, from: Data(contentsOf: url))
            listed.append(Listed(id: entry.id, title: entry.title, segments: entry.segments.map(\.text), preview: entry.preview))
        }
        if parsed.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(listed), as: UTF8.self))
        } else {
            for entry in listed { print("\(entry.id)  \(entry.title)  \(entry.segments.joined(separator: " | "))") }
        }
        return 0
    }
}
