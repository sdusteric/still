import Foundation
import SnapUI
import Sparkle

/// Sparkle 2 behind `UpdaterControlling` (app-updates CONTRACT.md). The feed, key and schedule
/// come from Info.plist. Only `AppDelegate` creates it, through `make()`, which returns nil in
/// shot mode, with `SNAP_NO_UPDATES=1` and outside a `.app` bundle.
final class Updater: UpdaterControlling {
    private let controller: SPUStandardUpdaterController

    static func make(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Updater? {
        UpdaterPolicy.makeUpdater(arguments: arguments, environment: environment, bundleURL: bundleURL) { Updater() }
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
