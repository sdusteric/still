import Foundation

/// The quick actions Shelf can open through `snap://<action>` (shelf design, section 11).
public enum ShelfAction: String, Sendable, CaseIterable {
    case captureArea = "capture-area"
    case captureWindow = "capture-window"
    case checkForUpdates = "check-for-updates"
}

/// A URL Shelf may open: a plain quick action, or `open-item` for a search result (Recall design 13).
public enum ShelfRequest: Sendable, Equatable {
    case action(ShelfAction)
    case openItem(id: String)
}

public enum ShelfURL {
    public static let scheme = "snap"
    public static let openItemAction = "open-item"

    /// The value of `SDShelfActions` in Info.plist, in its order.
    public static var advertisedActions: [String] {
        [ShelfAction.captureArea.rawValue, ShelfAction.captureWindow.rawValue, openItemAction, ShelfAction.checkForUpdates.rawValue]
    }

    public static func isShelfURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Accepts only `snap://<allowlisted action>` with no path, query, fragment, user or port.
    public static func parse(_ url: URL) -> ShelfAction? {
        guard isShelfURL(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host?.lowercased()
        else { return nil }
        return ShelfAction(rawValue: host)
    }

    /// A plain action as `parse` takes it, or `snap://open-item?id=<id>` with an id of
    /// `[A-Za-z0-9-]{1,64}`. Other query items are ignored; a path, fragment or authority is refused.
    public static func request(_ url: URL) -> ShelfRequest? {
        if let action = parse(url) { return .action(action) }
        guard isShelfURL(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.host?.lowercased() == openItemAction,
              let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
              isValidItemID(id)
        else { return nil }
        return .openItem(id: id)
    }

    static func isValidItemID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }
}

/// What the app does for each action. Tests use a fake; the app delegate is the real one.
@MainActor
public protocol ShelfActionHandling: AnyObject {
    func perform(_ action: ShelfAction)
    /// Shows one capture in History, selected.
    func openItem(id: String)
}

@MainActor
public struct ShelfRouter {
    private let handler: any ShelfActionHandling
    private let log: (String) -> Void

    public init(handler: any ShelfActionHandling, log: @escaping (String) -> Void) {
        self.handler = handler
        self.log = log
    }

    /// Runs the action for an allowlisted URL. Anything else is ignored and logged by its host
    /// only (never the query). Returns whether an action ran.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        switch ShelfURL.request(url) {
        case .action(let action)?:
            handler.perform(action)
        case .openItem(let id)?:
            handler.openItem(id: id)
        case nil:
            let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? ""
            log("ignored \(ShelfURL.scheme) URL with host '\(String(host.prefix(40)))'")
            return false
        }
        return true
    }
}
