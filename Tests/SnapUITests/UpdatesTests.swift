import Foundation
import SnapUI
import Testing

/// Records what the settings switch writes. Never links or starts Sparkle.
@MainActor
final class FakeUpdater: UpdaterControlling {
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var checks = 0

    init(checks: Bool = true, downloads: Bool = true) {
        automaticallyChecksForUpdates = checks
        automaticallyDownloadsUpdates = downloads
    }

    func checkForUpdates() { checks += 1 }
}

@MainActor @Suite struct UpdatesTests {
    static let app = URL(filePath: "/Applications/Snap.app", directoryHint: .isDirectory)
    static let normal = ["/Applications/Snap.app/Contents/MacOS/Snap"]

    private func make(_ arguments: [String], _ environment: [String: String], bundleURL: URL = app) -> (FakeUpdater?, Int) {
        var built = 0
        let updater = UpdaterPolicy.makeUpdater(arguments: arguments, environment: environment, bundleURL: bundleURL) {
            built += 1
            return FakeUpdater()
        }
        return (updater, built)
    }

    @Test func factoryReturnsNilInShotMode() {
        let (updater, built) = make(Self.normal + ["--shot", "menu", "--out", "/tmp/x.png"], [:])
        #expect(updater == nil)
        #expect(built == 0)
    }

    @Test func factoryReturnsNilWithNoUpdatesVariable() {
        let (updater, built) = make(Self.normal, ["SNAP_NO_UPDATES": "1"])
        #expect(updater == nil)
        #expect(built == 0)
        #expect(UpdaterPolicy.disableVariable == "SNAP_NO_UPDATES")
    }

    @Test func factoryReturnsNilOutsideAnAppBundleOrUnderXCTest() {
        #expect(make(Self.normal, [:], bundleURL: URL(filePath: "/tmp/build/release", directoryHint: .isDirectory)).0 == nil)
        #expect(make(Self.normal, ["XCTestConfigurationFilePath": "/tmp/x"]).0 == nil)
    }

    @Test func factoryBuildsTheUpdaterInANormalRun() {
        let (updater, built) = make(Self.normal, ["SNAP_NO_UPDATES": "0"])
        #expect(updater != nil)
        #expect(built == 1)
    }

    @Test func switchReadsBothUpdaterSettings() {
        #expect(UpdateSettingsModel(updater: FakeUpdater(checks: true, downloads: true)).automaticallyInstallsUpdates)
        #expect(!UpdateSettingsModel(updater: FakeUpdater(checks: true, downloads: false)).automaticallyInstallsUpdates)
        #expect(!UpdateSettingsModel(updater: FakeUpdater(checks: false, downloads: true)).automaticallyInstallsUpdates)
    }

    @Test func switchWritesBothUpdaterSettings() {
        let fake = FakeUpdater(checks: true, downloads: true)
        let model = UpdateSettingsModel(updater: fake)
        model.automaticallyInstallsUpdates = false
        #expect(fake.automaticallyChecksForUpdates == false)
        #expect(fake.automaticallyDownloadsUpdates == false)
        model.automaticallyInstallsUpdates = true
        #expect(fake.automaticallyChecksForUpdates == true)
        #expect(fake.automaticallyDownloadsUpdates == true)
        #expect(fake.checks == 0)
    }

    @Test func checkNowCallsTheUpdater() {
        let fake = FakeUpdater()
        UpdateSettingsModel(updater: fake).checkForUpdates()
        #expect(fake.checks == 1)
    }

    @Test func settingsHaveNoUpdatesGroupByDefault() {
        #expect(SettingsDemo.makeModel(tab: .general).updates == nil)
    }
}
