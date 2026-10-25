import Foundation
import SnapCore
import Synchronization
import Testing

/// A preflight result the test can flip, and a count of how many times it was read.
private final class FakePreflight: Sendable {
    private let granted: Mutex<Bool>
    init(_ granted: Bool) { self.granted = Mutex(granted) }
    func set(_ value: Bool) { granted.withLock { $0 = value } }
    var closure: @Sendable () -> Bool { { [self] in granted.withLock { $0 } } }
}

@Suite struct PermissionStateTests {
    let requestDate = Date(timeIntervalSince1970: 1_792_843_200)

    @Test func grantedPermissionCapturesWithoutAnyPrompt() {
        let preflight = FakePreflight(true)
        var state = PermissionState(preflight: preflight.closure)
        #expect(state.status == .granted)
        #expect(state.needsOnboarding == false)
        #expect(state.needsAttention == false)
        #expect(state.hotkeyPressed() == .capture)
        #expect(state.requestDecision() == .alreadyGranted)
    }

    @Test func firstRunWithoutPermissionShowsOnboarding() {
        let state = PermissionState(preflight: FakePreflight(false).closure)
        #expect(state.status == .denied)
        #expect(state.needsOnboarding)
        #expect(state.needsAttention)
    }

    @Test func atMostOneRequestIsEverAllowed() {
        var state = PermissionState(preflight: FakePreflight(false).closure)
        var requests = 0
        for _ in 0..<5 {
            if state.requestDecision() == .request {
                requests += 1
                state.recordRequest(at: requestDate)
            }
        }
        #expect(requests == 1)
        #expect(state.requestDecision() == .openSystemSettings)
        #expect(state.hasRequested)
    }

    @Test func aPersistedRequestDateMeansNoRequestEvenAfterRelaunch() {
        let state = PermissionState(preflight: FakePreflight(false).closure, requestedAt: requestDate)
        #expect(state.requestDecision() == .openSystemSettings)
        #expect(state.needsOnboarding == false)
    }

    @Test func recordRequestKeepsTheFirstDate() {
        var state = PermissionState(preflight: FakePreflight(false).closure)
        state.recordRequest(at: requestDate)
        state.recordRequest(at: requestDate.addingTimeInterval(500))
        #expect(state.requestedAt == requestDate)
    }

    @Test func hotkeyWhileDeniedShowsTheHintAndNeverRequests() {
        var state = PermissionState(preflight: FakePreflight(false).closure, requestedAt: requestDate)
        for _ in 0..<3 {
            #expect(state.hotkeyPressed() == .showHint)
        }
        #expect(state.requestDecision() == .openSystemSettings)
    }

    @Test func grantingLaterTurnsTheHotkeyBackIntoACapture() {
        let preflight = FakePreflight(false)
        var state = PermissionState(preflight: preflight.closure, requestedAt: requestDate)
        #expect(state.hotkeyPressed() == .showHint)
        preflight.set(true)
        state.appDidActivate()
        #expect(state.hotkeyPressed() == .capture)
        #expect(state.status == .granted)
    }

    @Test func userDeclinedErrorLapsesThePermissionAndShowsTheHintOnce() {
        let preflight = FakePreflight(true)
        var state = PermissionState(preflight: preflight.closure, requestedAt: requestDate)
        #expect(PermissionState.userDeclinedErrorCode == -3801)

        #expect(state.captureFailed(errorCode: -3801) == .showHint)
        #expect(state.status == .unknown)
        #expect(state.needsAttention)
        #expect(state.captureFailed(errorCode: -3801) == .logOnly)
        // A lapsed grant can be renewed, so the next hotkey still tries to capture.
        #expect(state.hotkeyPressed() == .capture)
    }

    @Test func aSuccessfulCaptureEndsTheLapseAndRearmsTheHint() {
        var state = PermissionState(preflight: FakePreflight(true).closure, requestedAt: requestDate)
        #expect(state.captureFailed(errorCode: -3801) == .showHint)
        state.captureSucceeded()
        #expect(state.status == .granted)
        #expect(state.needsAttention == false)
        #expect(state.captureFailed(errorCode: -3801) == .showHint)
    }

    @Test func otherErrorsWithPermissionGrantedAreNotAboutPermission() {
        var state = PermissionState(preflight: FakePreflight(true).closure, requestedAt: requestDate)
        #expect(state.captureFailed(errorCode: -3815) == .unrelated)
        #expect(state.captureFailed(errorCode: nil) == .unrelated)
        #expect(state.status == .granted)
    }

    @Test func anErrorWithoutPermissionShowsTheHint() {
        var state = PermissionState(preflight: FakePreflight(false).closure, requestedAt: requestDate)
        #expect(state.captureFailed(errorCode: -3801) == .showHint)
        var other = PermissionState(preflight: FakePreflight(false).closure, requestedAt: requestDate)
        #expect(other.captureFailed(errorCode: -3815) == .showHint)
        #expect(other.status == .denied)
    }

    @Test func relaunchIsOfferedWhenTheGrantDoesNotShowUpAfterReturning() {
        let preflight = FakePreflight(false)
        var state = PermissionState(preflight: preflight.closure)
        state.appDidActivate()
        #expect(state.offersRelaunch == false)

        state.recordRequest(at: requestDate)
        state.appDidActivate()
        #expect(state.offersRelaunch)

        preflight.set(true)
        state.appDidActivate()
        #expect(state.offersRelaunch == false)
    }

    @Test func relaunchIsOfferedWhenCaptureFailsAfterAGrant() {
        var state = PermissionState(preflight: FakePreflight(true).closure, requestedAt: requestDate)
        _ = state.captureFailed(errorCode: -3801)
        #expect(state.offersRelaunch)
        state.captureSucceeded()
        #expect(state.offersRelaunch == false)
    }

    // MARK: The re-approval badge (design 13), with the fake permission source

    @Test func aGrantedMacShowsNoBadge() {
        let source = FakePermissionSource(granted: true)
        var state = PermissionState(source: source)
        #expect(state.hotkeyPressed() == .capture)
        #expect(!state.showsBadge)
        #expect(!state.needsAttention)
        #expect(source.reads > 0, "the badge rests on the preflight only")
    }

    @Test func missingPermissionAloneDoesNotBadgeUntilACaptureIsRefused() {
        let source = FakePermissionSource(granted: false)
        var state = PermissionState(source: source)
        #expect(state.needsAttention, "the menu row is there")
        #expect(!state.showsBadge, "nothing failed yet")
        #expect(state.hotkeyPressed() == .showHint)
        #expect(state.showsBadge)
    }

    @Test func aReapprovalLapseBadgesUntilACaptureWorks() {
        let source = FakePermissionSource(granted: true)
        var state = PermissionState(source: source)
        // macOS asks again: the preflight still says yes, but ScreenCaptureKit declines.
        #expect(state.captureFailed(errorCode: PermissionState.userDeclinedErrorCode) == .showHint)
        #expect(state.status == .unknown)
        #expect(state.showsBadge)
        state.appDidActivate()
        #expect(state.showsBadge, "the preflight saying yes does not end a lapse; only a capture does")
        state.captureSucceeded()
        #expect(!state.showsBadge)
        #expect(!state.needsAttention)
    }

    @Test func aGrantSeenOnMenuOpenClearsTheBadge() {
        let source = FakePermissionSource(granted: false)
        var state = PermissionState(source: source)
        #expect(state.captureFailed(errorCode: nil) == .showHint)
        #expect(state.showsBadge)
        source.granted = true
        state.appDidActivate()
        #expect(!state.showsBadge)
        #expect(state.status == .granted)
    }

    @Test func anUnrelatedCaptureErrorDoesNotBadge() {
        var state = PermissionState(source: FakePermissionSource(granted: true))
        #expect(state.captureFailed(errorCode: -3815) == .unrelated)
        #expect(!state.showsBadge)
    }

    @Test func theMenuRowAsksForTheOKAndIsClickable() {
        let model = MenuModel(MenuInput(permissionNeeded: true))
        let row = model.item(.status)
        #expect(row?.title == "Screen Recording needs your OK")
        #expect(row?.kind == .status)
        #expect(row?.isEnabled == true, "a click opens the Screen Recording pane; nothing opens on its own")
    }
}

