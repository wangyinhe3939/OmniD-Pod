import XCTest
@testable import DDOffKeyCore

final class OffKeyMediaStartGateTests: XCTestCase {
    func testPermissionFailurePreservesIntentAndAllowsFreshRetry() {
        var lifecycle = OffKeyTapLifecycle()
        var gate = OffKeyMediaStartGate()
        lifecycle.setMediaRequested(true)
        guard let waiting = gate.requestStart(desired: true) else {
            return XCTFail("An enabled HUD must request a start")
        }
        lifecycle.installationFailed(for: .mediaKeys)
        XCTAssertTrue(lifecycle.mediaRequested)
        XCTAssertFalse(gate.permitsInstallation(generation: waiting, mode: lifecycle.mode))

        lifecycle.setMediaRequested(lifecycle.mediaRequested)
        guard let retry = gate.requestStart(desired: lifecycle.mediaRequested) else {
            return XCTFail("Permission failure must permit a later retry")
        }
        XCTAssertTrue(gate.permitsInstallation(generation: retry, mode: lifecycle.mode))
        XCTAssertFalse(gate.permitsInstallation(generation: waiting, mode: lifecycle.mode))
    }

    func testStopInvalidatesStartWaitingForAuthorization() {
        var gate = OffKeyMediaStartGate()
        let waitingGeneration = gate.requestStart(desired: true)

        gate.updateDesired(false)

        XCTAssertNotNil(waitingGeneration)
        XCTAssertFalse(gate.mediaDesired)
        XCTAssertFalse(gate.permitsInstallation(
            generation: waitingGeneration!,
            mode: .mediaKeys
        ))
    }

    func testOnlyNewestStartCanInstallAfterDisableAndReenable() {
        var gate = OffKeyMediaStartGate()
        let oldGeneration = gate.requestStart(desired: true)!
        gate.updateDesired(false)
        let newestGeneration = gate.requestStart(desired: true)!

        XCTAssertFalse(gate.permitsInstallation(
            generation: oldGeneration,
            mode: .mediaKeys
        ))
        XCTAssertTrue(gate.permitsInstallation(
            generation: newestGeneration,
            mode: .mediaKeys
        ))
    }

    func testCleaningModePreventsPendingMediaStartFromInstalling() {
        var gate = OffKeyMediaStartGate()
        let waitingGeneration = gate.requestStart(desired: true)!

        XCTAssertFalse(gate.permitsInstallation(
            generation: waitingGeneration,
            mode: .keyboardCleaning
        ))
        XCTAssertTrue(gate.permitsInstallation(
            generation: waitingGeneration,
            mode: .mediaKeys
        ))
    }
}
