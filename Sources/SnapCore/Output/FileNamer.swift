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

    /// The first free name: `Base.png`, then `Base 2.png`, `Base 3.png` and so on. `exists`
    /// receives the full file name (with extension) and says whether it is taken.
    public func fileName(
        date: Date,
        counter: Int = 1,
        app: String? = nil,
        fileExtension: String = "png",
        exists: (String) -> Bool
    ) -> String {
        let base = baseName(date: date, counter: counter, app: app)
        let first = FileNamer.join(base, fileExtension)
        if !exists(first) { return first }
        for suffix in 2...10_000 {
            let candidate = FileNamer.join("\(base) \(suffix)", fileExtension)
            if !exists(candidate) { return candidate }
        }
        return FileNamer.join("\(base) \(UUID().uuidString.prefix(8))", fileExtension)
    }

    /// A file name for `directory`, checking the real file system.
    public func fileName(
        in directory: URL,
        date: Date,
        counter: Int = 1,
        app: String? = nil,
        fileExtension: String = "png"
    ) -> String {
        fileName(date: date, counter: counter, app: app, fileExtension: fileExtension) { name in
            FileManager.default.fileExists(atPath: directory.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false))
        }
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
