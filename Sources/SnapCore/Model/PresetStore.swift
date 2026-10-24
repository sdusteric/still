import Foundation

/// The contents of `presets.json`: the saved Background presets and which one is starred.
public struct PresetLibrary: VersionedDocument {
    public static let currentVersion = 1

    public var version: Int
    public var presets: [BackgroundPreset]
    /// The default preset, used by one-click Background (design 10.1).
    public var starredID: String

    public init(
        version: Int = PresetLibrary.currentVersion,
        presets: [BackgroundPreset] = [BackgroundPreset.factoryDefault],
        starredID: String = BackgroundPreset.factoryID
    ) {
        self.version = version
        self.presets = presets
        self.starredID = starredID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PresetLibrary()
        self.init(
            version: try container.value(.version, default: defaults.version),
            presets: try container.value(.presets, default: defaults.presets),
            starredID: try container.value(.starredID, default: defaults.starredID)
        )
        normalize()
    }

    /// Keeps at least one preset and a starred id that names one of them.
    mutating func normalize() {
        if presets.isEmpty { presets = [BackgroundPreset.factoryDefault] }
        if !presets.contains(where: { $0.id == starredID }), let first = presets.first {
            starredID = first.id
        }
    }
}

/// `SNAP_HOME/presets.json`. Changes are rare, so each one is written at once.
public final class PresetStore: Sendable {
    private let store: DocumentStore<PresetLibrary>

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        store = DocumentStore(fileURL: fileURL, defaultDocument: PresetLibrary(), now: now)
    }

    public convenience init(paths: SnapPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(fileURL: paths.presetsFile, now: now)
    }

    public var fileURL: URL { store.fileURL }
    public var presets: [BackgroundPreset] { store.document.presets }
    public var starredID: String { store.document.starredID }

    /// The starred preset: what one-click Background applies.
    public var starred: BackgroundPreset {
        let library = store.document
        return library.presets.first { $0.id == library.starredID } ?? library.presets.first ?? .factoryDefault
    }

    public func preset(id: String) -> BackgroundPreset? {
        store.document.presets.first { $0.id == id }
    }

    @discardableResult
    public func load() throws -> StoreLoadOutcome {
        try store.load()
    }

    /// Adds `preset`, or replaces the one with the same id. Values are clamped.
    public func save(_ preset: BackgroundPreset) throws {
        let value = preset.clamped()
        store.mutate { library in
            if let index = library.presets.firstIndex(where: { $0.id == value.id }) {
                library.presets[index] = value
            } else {
                library.presets.append(value)
            }
        }
        try store.flush()
    }

    /// Stars the preset with `id`. Returns false when there is none.
    @discardableResult
    public func setStarred(id: String) throws -> Bool {
        let known = store.mutate { library -> Bool in
            guard library.presets.contains(where: { $0.id == id }) else { return false }
            library.starredID = id
            return true
        }
        try store.flush()
        return known
    }

    /// Removes a preset. The last one cannot be removed (the factory default replaces it), and
    /// removing the starred one stars the first that remains.
    public func delete(id: String) throws {
        store.mutate { library in
            library.presets.removeAll { $0.id == id }
            library.normalize()
        }
        try store.flush()
    }

    /// A new unused id for a preset saved from the editor.
    public static func makeID() -> String { UUID().uuidString.lowercased() }
}
