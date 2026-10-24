import Foundation

/// `SNAP_HOME/settings.json` (design 12.2). Changes are rare, so each one is written at once.
public final class SettingsStore: Sendable {
    private let store: DocumentStore<Settings>

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        store = DocumentStore(fileURL: fileURL, defaultDocument: Settings(), now: now)
    }

    public convenience init(paths: SnapPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(fileURL: paths.settingsFile, now: now)
    }

    public var fileURL: URL { store.fileURL }
    public var settings: Settings { store.document }

    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        try store.load()
    }

    /// Applies `change` and writes the file if anything changed. Out-of-range values are clamped.
    public func update(_ change: (inout Settings) -> Void) throws {
        store.mutate { settings in
            change(&settings)
            settings.quickAccess.autoCloseSeconds = QuickAccessSettings.clampSeconds(settings.quickAccess.autoCloseSeconds)
            if settings.general.fileNamePattern.isEmpty {
                settings.general.fileNamePattern = GeneralSettings.defaultFileNamePattern
            }
        }
        try store.flush()
    }
}
