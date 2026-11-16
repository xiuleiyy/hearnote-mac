import Foundation
import XCTest
@testable import HearNoteCore

final class AudioRouteRecoveryTests: XCTestCase {
    func testHardwareReplacementKeepsRecoverySeparateFromInputLease() throws {
        var route = AudioRouteRecovery()
        let initial = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: initial))
        XCTAssertTrue(route.isActive)
        XCTAssertFalse(route.accepts(input: initial))
        let replacement = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        XCTAssertNotEqual(replacement, initial)
        XCTAssertTrue(route.succeeded(recovery: recovery, input: replacement, activeHardwareInput: replacement))
        XCTAssertTrue(route.accepts(input: replacement))
        XCTAssertNil(route.recoveryID)
    }

    func testLateConfigurationNotificationCannotRetireReplacement() throws {
        var route = AudioRouteRecovery()
        let old = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: old))
        let current = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        XCTAssertTrue(route.succeeded(recovery: recovery, input: current, activeHardwareInput: current))
        XCTAssertNil(route.configurationChanged(input: old))
        XCTAssertTrue(route.accepts(input: current))
    }

    func testChangesDuringAttemptCoalesceWithoutResettingRetryBudget() throws {
        var route = AudioRouteRecovery(maximumAttempts: 2)
        let old = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: old))
        let first = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        XCTAssertEqual(route.configurationChanged(input: first), recovery)
        XCTAssertEqual(route.attempts, 1)
        let second = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        route.attemptFailed(recovery: recovery, input: second)
        XCTAssertNil(route.nextAttempt(recovery: recovery))
        XCTAssertEqual(route.attempts, 2)
    }

    func testSuccessfulReplacementGetsFreshBudgetForLaterUserSwitch() throws {
        var route = AudioRouteRecovery(maximumAttempts: 1)
        let initial = route.start()
        let firstRecovery = try XCTUnwrap(route.configurationChanged(input: initial))
        let replaced = try XCTUnwrap(route.nextAttempt(recovery: firstRecovery))
        XCTAssertTrue(route.succeeded(recovery: firstRecovery, input: replaced, activeHardwareInput: replaced))
        let secondRecovery = try XCTUnwrap(route.configurationChanged(input: replaced))
        XCTAssertNotEqual(secondRecovery, firstRecovery)
        XCTAssertNotNil(route.nextAttempt(recovery: secondRecovery))
    }

    func testStopWhileWaitingPreventsRestart() throws {
        var route = AudioRouteRecovery()
        let initial = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: initial))
        route.stop()
        XCTAssertNil(route.nextAttempt(recovery: recovery))
        XCTAssertNil(route.configurationChanged(input: initial))
        XCTAssertFalse(route.isActive)
    }

    func testStopDuringAttemptRejectsLateSuccess() throws {
        var route = AudioRouteRecovery()
        let initial = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: initial))
        let replacement = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        route.stop()
        XCTAssertFalse(route.succeeded(recovery: recovery, input: replacement, activeHardwareInput: replacement))
        XCTAssertFalse(route.accepts(input: replacement))
    }

    func testOldRecoveryCannotAffectNextMeeting() throws {
        var route = AudioRouteRecovery()
        let old = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: old))
        let oldAttempt = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        route.stop()
        let current = route.start()
        route.attemptFailed(recovery: recovery, input: oldAttempt)
        XCTAssertFalse(route.succeeded(recovery: recovery, input: oldAttempt, activeHardwareInput: oldAttempt))
        XCTAssertNil(route.nextAttempt(recovery: recovery))
        XCTAssertTrue(route.accepts(input: current))
    }

    func testEOSOnlyTailFromRetiredHardwareCannotCompleteRecovery() throws {
        var route = AudioRouteRecovery(maximumAttempts: 2)
        let initial = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: initial))
        let retired = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        XCTAssertFalse(route.succeeded(recovery: recovery, input: retired, activeHardwareInput: nil))
        XCTAssertEqual(route.recoveryID, recovery)
        route.attemptFailed(recovery: recovery, input: retired)
        let current = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        XCTAssertFalse(route.succeeded(recovery: recovery, input: retired, activeHardwareInput: current))
        XCTAssertTrue(route.succeeded(recovery: recovery, input: current, activeHardwareInput: current))
    }

    func testDuplicateAttemptFailureCannotInvalidateLaterAttempt() throws {
        var route = AudioRouteRecovery()
        let initial = route.start()
        let recovery = try XCTUnwrap(route.configurationChanged(input: initial))
        let old = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        route.attemptFailed(recovery: recovery, input: old)
        let current = try XCTUnwrap(route.nextAttempt(recovery: recovery))
        route.attemptFailed(recovery: recovery, input: old)
        XCTAssertTrue(route.accepts(input: current))
        XCTAssertTrue(route.succeeded(recovery: recovery, input: current, activeHardwareInput: current))
    }
}
