import Foundation

/// The quick actions Shelf can open through `snap://<action>` (shelf design, section 11).
public enum ShelfAction: String, Sendable, CaseIterable {
    case captureArea = "capture-area"
    case captureWindow = "capture-window"
    case checkForUpdates = "check-for-updates"
}

public enum ShelfURL {
    public static let scheme = "snap"

    /// The value of `SDShelfActions` in Info.plist.
    public static var advertisedActions: [String] { ShelfAction.allCases.map(\.rawValue) }

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
}

/// What the app does for each action. Tests use a fake; the app delegate is the real one.
@MainActor
public protocol ShelfActionHandling: AnyObject {
    func perform(_ action: ShelfAction)
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
        guard let action = ShelfURL.parse(url) else {
            let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? ""
            log("ignored \(ShelfURL.scheme) URL with host '\(String(host.prefix(40)))'")
            return false
        }
        handler.perform(action)
        return true
    }
}
