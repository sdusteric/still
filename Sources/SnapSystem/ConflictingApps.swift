import AppKit
import Foundation
import SnapCore

/// Watches for CleanShot X (design 12.3): while one of its bundle ids runs, Snap holds back the
/// combos they share, and registers them when `NSWorkspace` reports CleanShot gone. Snap never
/// quits or signals CleanShot.
@MainActor
public final class ConflictingApps {
    public let watchedBundleIDs: Set<String>
    private let workspace: NSWorkspace
    private var observers: [any NSObjectProtocol] = []
    private var onChange: (@MainActor (Set<String>) -> Void)?

    public init(watchedBundleIDs: Set<String> = HotkeyConflicts.cleanShotBundleIDs, workspace: NSWorkspace = .shared) {
        self.watchedBundleIDs = watchedBundleIDs
        self.workspace = workspace
    }

    /// The watched bundle ids that are running now.
    public var runningBundleIDs: Set<String> {
        ConflictingApps.matching(workspace.runningApplications.map(\.bundleIdentifier), watched: watchedBundleIDs)
    }

    public var isCleanShotRunning: Bool { !runningBundleIDs.isEmpty }

    /// Calls `onChange` with the running watched ids whenever a watched app launches or quits.
    public func startObserving(onChange: @escaping @MainActor (Set<String>) -> Void) {
        stopObserving()
        self.onChange = onChange
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                MainActor.assumeIsolated { self?.applicationChanged(bundleID) }
            }
            observers.append(token)
        }
    }

    public func stopObserving() {
        let center = workspace.notificationCenter
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        onChange = nil
    }

    /// The ids in `bundleIDs` that are watched. Pure, for the running list and notifications.
    public nonisolated static func matching(_ bundleIDs: [String?], watched: Set<String>) -> Set<String> {
        Set(bundleIDs.compactMap { $0 }).intersection(watched)
    }

    private func applicationChanged(_ bundleID: String?) {
        guard let bundleID, watchedBundleIDs.contains(bundleID) else { return }
        // Read the list again rather than trusting the event: a second CleanShot copy may still run.
        onChange?(runningBundleIDs)
    }
}
