import Foundation
import Observation

/// What the menu and settings need from the updater. The app's `Updater` wraps Sparkle's
/// `SPUStandardUpdaterController`; tests use a fake, so they never link or start Sparkle.
public protocol UpdaterControlling: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func checkForUpdates()
}

/// When Snap may start an updater (app-updates CONTRACT.md): never in shot mode, never with
/// `SNAP_NO_UPDATES=1`, never under XCTest, and only from a `.app` bundle, so a bare `.build`
/// binary, tests and tools never reach Sparkle.
public enum UpdaterPolicy {
    public static let disableVariable = "SNAP_NO_UPDATES"

    public static func allowsUpdater(arguments: [String], environment: [String: String], bundleURL: URL) -> Bool {
        if arguments.contains("--shot") { return false }
        if environment[disableVariable] == "1" { return false }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return false }
        return bundleURL.pathExtension == "app"
    }

    /// The updater factory: `make` runs only when the policy allows an updater.
    public static func makeUpdater<Updater>(
        arguments: [String], environment: [String: String], bundleURL: URL, make: () -> Updater
    ) -> Updater? {
        allowsUpdater(arguments: arguments, environment: environment, bundleURL: bundleURL) ? make() : nil
    }
}

/// The "Automatically install updates" switch and "Check for Updates..." in settings. One switch
/// drives both Sparkle settings: on means check daily and install in the background.
@MainActor
@Observable
public final class UpdateSettingsModel {
    @ObservationIgnored private let updater: any UpdaterControlling

    public var automaticallyInstallsUpdates: Bool {
        didSet {
            guard automaticallyInstallsUpdates != oldValue else { return }
            updater.automaticallyChecksForUpdates = automaticallyInstallsUpdates
            updater.automaticallyDownloadsUpdates = automaticallyInstallsUpdates
        }
    }

    public init(updater: any UpdaterControlling) {
        self.updater = updater
        automaticallyInstallsUpdates = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    public func checkForUpdates() {
        updater.checkForUpdates()
    }
}
