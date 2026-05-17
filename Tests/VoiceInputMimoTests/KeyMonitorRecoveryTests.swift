import XCTest
@testable import VoiceInputMimo

/// Tests for B2 — defensive state recovery when CGEventTap is disabled by
/// the system (`tapDisabledByTimeout` / `tapDisabledByUserInput`). Without
/// recovery, a key-down event before the disable + key-up event during the
/// disable window leaves the state machine stuck (`fnPressed = true` /
/// `activeKeyCode != nil` / `parkActive = true`), causing the app to record
/// indefinitely.
///
/// We test `recoverStuckStateOnTapDisable()` directly rather than fabricating
/// CGEvent tap-disable events because (a) `CGEventTap.tapCreate` requires
/// accessibility permission which is unavailable in unit tests, and (b) the
/// system-disabled event sequence is hard to observe deterministically.
final class KeyMonitorRecoveryTests: XCTestCase {

    func testRecovery_StuckFnPressed_SynthesizesFnUpAndClearsState() {
        let monitor = KeyMonitor()
        var fnUpCount = 0
        monitor.onFnUp = { fnUpCount += 1 }

        monitor.fnPressed = true

        monitor.recoverStuckStateOnTapDisable()

        // Callback dispatched async on main queue.
        let exp = expectation(description: "onFnUp fired")
        DispatchQueue.main.async {
            XCTAssertEqual(fnUpCount, 1, "onFnUp must fire exactly once for stuck fnPressed")
            XCTAssertFalse(monitor.fnPressed, "fnPressed must be cleared")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRecovery_StuckActiveKeyCode_SynthesizesFnUpAndClearsState() {
        let monitor = KeyMonitor()
        var fnUpCount = 0
        monitor.onFnUp = { fnUpCount += 1 }

        monitor.activeKeyCode = 63  // any keycode

        monitor.recoverStuckStateOnTapDisable()

        let exp = expectation(description: "onFnUp fired")
        DispatchQueue.main.async {
            XCTAssertEqual(fnUpCount, 1, "onFnUp must fire for stuck activeKeyCode")
            XCTAssertNil(monitor.activeKeyCode, "activeKeyCode must be cleared")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRecovery_StuckParkActive_SynthesizesParkUpAndClearsState() {
        let monitor = KeyMonitor()
        var parkUpCount = 0
        monitor.onParkUp = { parkUpCount += 1 }

        monitor.parkActive = true

        monitor.recoverStuckStateOnTapDisable()

        let exp = expectation(description: "onParkUp fired")
        DispatchQueue.main.async {
            XCTAssertEqual(parkUpCount, 1, "onParkUp must fire for stuck parkActive")
            XCTAssertFalse(monitor.parkActive, "parkActive must be cleared")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRecovery_NoStuckState_FiresNoCallbacks() {
        let monitor = KeyMonitor()
        var fnUpCount = 0
        var parkUpCount = 0
        monitor.onFnUp = { fnUpCount += 1 }
        monitor.onParkUp = { parkUpCount += 1 }

        // No state set — recovery should be a no-op.
        monitor.recoverStuckStateOnTapDisable()

        let exp = expectation(description: "no callbacks fired")
        DispatchQueue.main.async {
            XCTAssertEqual(fnUpCount, 0, "onFnUp must NOT fire when no state is stuck")
            XCTAssertEqual(parkUpCount, 0, "onParkUp must NOT fire when no state is stuck")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRecovery_MultipleStuckStates_FiresAllCorrespondingCallbacks() {
        // Defensive: if both Fn and Park were active (shouldn't happen in
        // practice but the state machine doesn't enforce mutual exclusion),
        // recovery must clear both and fire both callbacks.
        let monitor = KeyMonitor()
        var fnUpCount = 0
        var parkUpCount = 0
        monitor.onFnUp = { fnUpCount += 1 }
        monitor.onParkUp = { parkUpCount += 1 }

        monitor.fnPressed = true
        monitor.activeKeyCode = 63
        monitor.parkActive = true

        monitor.recoverStuckStateOnTapDisable()

        let exp = expectation(description: "all callbacks fired")
        DispatchQueue.main.async {
            // fnPressed + activeKeyCode each fire onFnUp (2 total).
            XCTAssertEqual(fnUpCount, 2, "fnPressed + activeKeyCode each synthesize onFnUp")
            XCTAssertEqual(parkUpCount, 1, "parkActive synthesizes onParkUp once")
            XCTAssertFalse(monitor.fnPressed)
            XCTAssertNil(monitor.activeKeyCode)
            XCTAssertFalse(monitor.parkActive)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
