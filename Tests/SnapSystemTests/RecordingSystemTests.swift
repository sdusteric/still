import AVFoundation
import Foundation
import SnapCore
import SnapSystem
import Testing

// Pure helpers only: no ScreenCaptureKit object is made, AVCaptureDevice is never called, and
// the microphone gate runs over FakeMicrophoneAuthorization.

@Suite struct RecordingErrorMappingTests {
    let domain = LiveRecordingSource.streamErrorDomain

    func failure(_ code: Int, domain: String? = nil) -> StreamFailure {
        StreamFailure(domain: domain ?? self.domain, code: code, message: "test")
    }

    @Test func userDeclinedAtStartIsPermissionDenied() {
        #expect(LiveRecordingSource.startError(for: failure(-3801)) == .permissionDenied)
        #expect(LiveRecordingSource.ErrorCode.userDeclined == PermissionState.userDeclinedErrorCode)
    }

    @Test func otherStartErrorsCouldNotStart() {
        let failed = LiveRecordingSource.startError(for: failure(-3802))
        #expect(failed == .startFailed(failure(-3802).description))
        // The same code in another domain is not a permission problem.
        let foreign = LiveRecordingSource.startError(for: failure(-3801, domain: NSCocoaErrorDomain))
        #expect(foreign != .permissionDenied)
    }

    @Test func streamFailureKeepsDomainCodeAndMessage() {
        let error = NSError(domain: domain, code: -3817, userInfo: [NSLocalizedDescriptionKey: "stopped"])
        let failure = StreamFailure(error)
        #expect(failure.domain == domain)
        #expect(failure.code == -3817)
        #expect(failure.message == "stopped")
    }

    @Test func missingCaptureSourceMeansWindowClosedOrDisplayGone() {
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3815), filterKind: .desktopIndependentWindow)
            == .stoppedBySystem(.windowClosed))
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3813), filterKind: .desktopIndependentWindow)
            == .stoppedBySystem(.windowClosed))
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3815), filterKind: .displayExcludingWindows)
            == .stoppedBySystem(.displayDisconnected))
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3814), filterKind: .wholeDisplay)
            == .stoppedBySystem(.displayDisconnected))
    }

    @Test func systemStopsMapToStopReasons() {
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3817), filterKind: .wholeDisplay) == .stoppedBySystem(.user))
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3822), filterKind: .wholeDisplay) == .stoppedBySystem(.diskFull))
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3821), filterKind: .wholeDisplay)
            == .stoppedBySystem(.streamFailed))
    }

    @Test func otherMidStreamErrorsAreFailures() {
        let internalError = failure(-3811)
        #expect(LiveRecordingSource.sessionEvent(for: internalError, filterKind: .displayExcludingWindows)
            == .failed(internalError.description))
        let foreign = failure(-3815, domain: NSPOSIXErrorDomain)
        #expect(LiveRecordingSource.sessionEvent(for: foreign, filterKind: .desktopIndependentWindow)
            == .failed(foreign.description))
        #expect(LiveRecordingSource.sessionEvent(for: failure(-3801), filterKind: .wholeDisplay)
            == .failed(RecordingSourceError.permissionDenied.description))
    }
}

@Suite struct MicrophoneAuthorizationTests {
    final class TempHome {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-mic-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // A leftover temp folder is harmless.
            }
        }

        func store() -> StateStore { StateStore(fileURL: url.appendingPathComponent("state.json")) }
    }

    let requestDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestsOnceWhenNotDeterminedAndRecordsTheDate() async throws {
        let home = try TempHome()
        let fake = FakeMicrophoneAuthorization(status: .notDetermined, grantsOnRequest: true)
        let gate = MicrophoneAuthorization(stateStore: home.store(), underlying: fake, now: { [requestDate] in requestDate })
        #expect(await gate.requestAccess())
        #expect(fake.requestCount == 1)
        #expect(await gate.requestAccess())
        #expect(fake.requestCount == 1)

        let reloaded = home.store()
        try reloaded.load()
        #expect(reloaded.state.microphoneRequested == requestDate)
    }

    @Test func neverAsksAgainAfterAnEarlierRequestEvenIfUndetermined() async throws {
        let home = try TempHome()
        let store = home.store()
        try store.update { $0.microphoneRequested = requestDate }
        let fake = FakeMicrophoneAuthorization(status: .notDetermined)
        let gate = MicrophoneAuthorization(stateStore: store, underlying: fake)
        #expect(await gate.requestAccess() == false)
        #expect(fake.requestCount == 0)
    }

    @Test func decidedStatusAnswersWithoutAsking() async throws {
        let home = try TempHome()
        let granted = FakeMicrophoneAuthorization(status: .authorized)
        #expect(await MicrophoneAuthorization(stateStore: home.store(), underlying: granted).requestAccess())
        let denied = FakeMicrophoneAuthorization(status: .denied)
        #expect(await MicrophoneAuthorization(stateStore: home.store(), underlying: denied).requestAccess() == false)
        let restricted = FakeMicrophoneAuthorization(status: .restricted)
        #expect(await MicrophoneAuthorization(stateStore: home.store(), underlying: restricted).requestAccess() == false)
        #expect(granted.requestCount + denied.requestCount + restricted.requestCount == 0)
        #expect(home.store().state.microphoneRequested == nil)
    }

    @Test func concurrentRequestsPromptOnce() async throws {
        let home = try TempHome()
        let fake = FakeMicrophoneAuthorization(status: .notDetermined, grantsOnRequest: false)
        let gate = MicrophoneAuthorization(stateStore: home.store(), underlying: fake)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { await gate.requestAccess() } }
            for await _ in group {}
        }
        #expect(fake.requestCount == 1)
        #expect(gate.status() == .denied)
    }

    @Test func statusIsTheUnderlyingProbe() throws {
        let home = try TempHome()
        let fake = FakeMicrophoneAuthorization(status: .denied)
        let gate = MicrophoneAuthorization(stateStore: home.store(), underlying: fake)
        #expect(gate.status() == .denied)
        fake.currentStatus = .authorized
        #expect(gate.status() == .authorized)
        #expect(fake.requestCount == 0)
    }

    @Test func gateRuleAndStatusMapping() {
        #expect(MicrophoneAuthorization.shouldRequest(status: .notDetermined, requestedAt: nil))
        #expect(!MicrophoneAuthorization.shouldRequest(status: .notDetermined, requestedAt: requestDate))
        #expect(!MicrophoneAuthorization.shouldRequest(status: .denied, requestedAt: nil))
        #expect(MicrophoneAuthorization.access(for: .authorized) == .authorized)
        #expect(MicrophoneAuthorization.access(for: .denied) == .denied)
        #expect(MicrophoneAuthorization.access(for: .restricted) == .restricted)
        #expect(MicrophoneAuthorization.access(for: .notDetermined) == .notDetermined)
        #expect(MicrophoneAuthorization.privacySettingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)
    }
}

@Suite struct InputDeviceAndDiskTests {
    @Test func defaultDeviceFirstThenByNameWithoutDuplicates() {
        let devices = InputDevices.ordered(
            [
                (id: "usb", name: "Yeti"),
                (id: "builtin", name: "MacBook Pro Microphone"),
                (id: "usb", name: "Yeti"),
                (id: "iface", name: "Audio Interface"),
            ],
            defaultID: "builtin"
        )
        #expect(devices.map(\.id) == ["builtin", "iface", "usb"])
        #expect(devices.map(\.isDefault) == [true, false, false])
    }

    @Test func chosenDeviceResolvesOnlyWhileConnected() {
        let devices = [
            AudioInputDevice(id: "builtin", name: "Built-in", isDefault: true),
            AudioInputDevice(id: "usb", name: "USB", isDefault: false),
        ]
        #expect(InputDevices.resolve("usb", among: devices) == "usb")
        #expect(InputDevices.resolve("gone", among: devices) == nil)
        #expect(InputDevices.resolve(nil, among: devices) == nil)
        #expect(InputDevices.connectedDeviceID(nil) == nil)
    }

    @Test func freeSpacePrefersImportantUsage() {
        #expect(LiveDiskSpace.choose(importantUsage: 5_000, plain: 4_000) == 5_000)
        #expect(LiveDiskSpace.choose(importantUsage: 0, plain: 4_000) == 4_000)
        #expect(LiveDiskSpace.choose(importantUsage: nil, plain: 4_000) == 4_000)
        #expect(LiveDiskSpace.choose(importantUsage: 0, plain: nil) == 0)
        #expect(LiveDiskSpace.choose(importantUsage: nil, plain: nil) == nil)
    }

    @Test func missingFolderReadsItsNearestExistingAncestor() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("snap-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: base)
            } catch {
                // A leftover temp folder is harmless.
            }
        }
        let missing = base.appendingPathComponent("history/not-yet", isDirectory: true)
        #expect(LiveDiskSpace.existingAncestor(of: missing).standardizedFileURL.path == base.standardizedFileURL.path)
        #expect(LiveDiskSpace.existingAncestor(of: base).standardizedFileURL.path == base.standardizedFileURL.path)
        #expect(try LiveDiskSpace().availableBytes(at: missing) > 0)
    }
}
