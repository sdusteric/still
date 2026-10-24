import Foundation

/// Where Snap keeps its files (design section 14). Everything lives under `SNAP_HOME`, default
/// `~/Library/Application Support/Snap`, so tests and shots isolate all state with one variable.
public struct SnapPaths: Sendable, Hashable {
    public static let environmentKey = "SNAP_HOME"
    static let defaultHomeRelativePath = "Library/Application Support/Snap"

    public let home: URL
    /// True when `home` is the default location (SNAP_HOME unset, empty or equal to the default).
    public let isDefaultHome: Bool
    private let userHome: URL

    /// Uses `home` as SNAP_HOME. `userHome` is only consulted to tell whether `home` is the default.
    public init(home: URL, userHome: URL = URL.homeDirectory) {
        let standardized = home.standardizedFileURL
        let defaultHome = SnapPaths.defaultHome(userHome: userHome)
        self.home = standardized
        self.userHome = userHome.standardizedFileURL
        self.isDefaultHome = SnapPaths.samePath(standardized, defaultHome)
    }

    /// Resolves `SNAP_HOME`, expanding a leading `~`. Empty or unset means the default.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let userHome = SnapPaths.userHome(environment: environment)
        if let value = environment[SnapPaths.environmentKey], !value.isEmpty {
            let expanded = SnapPaths.expandTilde(value, userHome: userHome)
            self.init(home: URL(filePath: expanded, directoryHint: .isDirectory), userHome: userHome)
        } else {
            self.init(home: SnapPaths.defaultHome(userHome: userHome), userHome: userHome)
        }
    }

    public var settingsFile: URL { home.appending(path: "settings.json", directoryHint: .notDirectory) }
    public var presetsFile: URL { home.appending(path: "presets.json", directoryHint: .notDirectory) }
    public var stateFile: URL { home.appending(path: "state.json", directoryHint: .notDirectory) }
    public var historyDirectory: URL { home.appending(path: "history", directoryHint: .isDirectory) }
    public var logsDirectory: URL { home.appending(path: "logs", directoryHint: .isDirectory) }
    public var logFile: URL { logsDirectory.appending(path: "snap.log", directoryHint: .notDirectory) }

    /// `history/<id>/` for one capture.
    public func historyDirectory(for id: String) -> URL {
        historyDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    /// The save folder used when settings name none: ~/Downloads only for the default SNAP_HOME,
    /// otherwise `$SNAP_HOME/Saved`, so no test or shot can write into the user's Downloads.
    public var defaultSaveFolder: URL {
        if isDefaultHome {
            return userHome.appending(path: "Downloads", directoryHint: .isDirectory)
        }
        return home.appending(path: "Saved", directoryHint: .isDirectory)
    }

    /// The save folder for `settings`: its own folder when set, else `defaultSaveFolder`.
    /// A non-default SNAP_HOME ignores a stored folder outside it, for the same reason.
    public func saveFolder(for settings: Settings) -> URL {
        guard let path = settings.general.saveFolderPath, !path.isEmpty else { return defaultSaveFolder }
        let folder = URL(filePath: SnapPaths.expandTilde(path, userHome: userHome), directoryHint: .isDirectory)
            .standardizedFileURL
        if isDefaultHome || SnapPaths.isInside(folder, home) { return folder }
        return defaultSaveFolder
    }

    /// Creates `home`, `history` and `logs` if missing.
    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    static func defaultHome(userHome: URL) -> URL {
        userHome.appending(path: defaultHomeRelativePath, directoryHint: .isDirectory).standardizedFileURL
    }

    static func userHome(environment: [String: String]) -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
        }
        return URL.homeDirectory
    }

    static func expandTilde(_ path: String, userHome: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let base = userHome.path(percentEncoded: false)
        let rest = path.dropFirst(path == "~" ? 1 : 2)
        return base.hasSuffix("/") ? base + rest : base + "/" + rest
    }

    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        trimmed(lhs) == trimmed(rhs)
    }

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let childPath = trimmed(child)
        let parentPath = trimmed(parent)
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func trimmed(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
