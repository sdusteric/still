import Foundation

/// Builds capture file names from the pattern setting (design section 9). Pure: the time zone,
/// counter, app name and the "does this file exist" check are all passed in.
///
/// Tokens: `{yyyy} {MM} {dd} {HH} {mm} {ss} {counter} {app}`. Unknown tokens stay as written.
/// Colons and slashes never appear in the result, since Finder shows a colon as a slash.
public struct FileNamer: Sendable, Hashable {
    public static let defaultPattern = GeneralSettings.defaultFileNamePattern
    public static let maximumBaseLength = 150
    static let fallbackBase = "Snap"

    public var pattern: String
    public var timeZone: TimeZone

    public init(pattern: String = FileNamer.defaultPattern, timeZone: TimeZone = .current) {
        self.pattern = pattern.isEmpty ? FileNamer.defaultPattern : pattern
        self.timeZone = timeZone
    }

    /// The name without extension and without collision handling.
    /// - Parameters:
    ///   - counter: replaces `{counter}`, unpadded.
    ///   - app: replaces `{app}`; empty when the source app is unknown.
    public func baseName(date: Date, counter: Int = 1, app: String? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let tokens: [String: String] = [
            "{yyyy}": String(format: "%04d", parts.year ?? 0),
            "{MM}": String(format: "%02d", parts.month ?? 0),
            "{dd}": String(format: "%02d", parts.day ?? 0),
            "{HH}": String(format: "%02d", parts.hour ?? 0),
            "{mm}": String(format: "%02d", parts.minute ?? 0),
            "{ss}": String(format: "%02d", parts.second ?? 0),
            "{counter}": String(counter),
            "{app}": FileNamer.sanitize(app ?? ""),
        ]
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            if pattern[index] == "{",
               let close = pattern[index...].firstIndex(of: "}"),
               let value = tokens[String(pattern[index...close])] {
                result += value
                index = pattern.index(after: close)
            } else {
                result.append(pattern[index])
                index = pattern.index(after: index)
            }
        }
        return FileNamer.tidy(result)
    }

    /// The names to try in order: `Base.png`, then `Base 2.png` up to `Base 10000.png`, then one
    /// with a random suffix.
    public func candidates(
        date: Date,
        counter: Int = 1,
        app: String? = nil,
        fileExtension: String = "png"
    ) -> some Sequence<String> {
        let base = baseName(date: date, counter: counter, app: app)
        return (1...10_001).lazy.map { suffix in
            switch suffix {
            case 1: FileNamer.join(base, fileExtension)
            case 10_001: FileNamer.join("\(base) \(UUID().uuidString.prefix(8))", fileExtension)
            default: FileNamer.join("\(base) \(suffix)", fileExtension)
            }
        }
    }

    /// The first free name: `Base.png`, then `Base 2.png`, `Base 3.png` and so on. `exists`
    /// receives the full file name (with extension) and says whether it is taken.
    public func fileName(
        date: Date,
        counter: Int = 1,
        app: String? = nil,
        fileExtension: String = "png",
        exists: (String) -> Bool
    ) -> String {
        let names = candidates(date: date, counter: counter, app: app, fileExtension: fileExtension)
        return names.first { !exists($0) } ?? FileNamer.join("\(baseName(date: date)) \(UUID().uuidString.prefix(8))", fileExtension)
    }

    /// Writes `data` into `directory` under the first free name and returns its URL. The name is
    /// claimed atomically, so concurrent saves made in the same second each keep their file.
    public func write(
        _ data: Data,
        into directory: URL,
        date: Date,
        counter: Int = 1,
        app: String? = nil,
        fileExtension: String = "png"
    ) throws -> URL {
        try AtomicFile.writeNew(
            data, in: directory,
            names: candidates(date: date, counter: counter, app: app, fileExtension: fileExtension)
        )
    }

    /// Replaces the characters a file name cannot carry: colon and slash (and control characters).
    public static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case ":": "."
            case "/": "-"
            default: scalar.value < 0x20 || scalar.value == 0x7F ? " " : Character(scalar)
            }
        })
    }

    private static func tidy(_ text: String) -> String {
        var cleaned = sanitize(text)
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > maximumBaseLength {
            cleaned = String(cleaned.prefix(maximumBaseLength)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? fallbackBase : cleaned
    }

    private static func join(_ base: String, _ fileExtension: String) -> String {
        fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }
}
