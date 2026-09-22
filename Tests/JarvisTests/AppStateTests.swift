@testable import Jarvis
import XCTest

final class AppStateTests: XCTestCase {

    @MainActor
    func testValidTransitions() {
        let state = AppState.shared

        // Reset to OFF
        if state.state != .off {
            state.transition(to: .off)
        }
        XCTAssertEqual(state.state, .off)

        // OFF → SLEEP
        state.transition(to: .sleep)
        XCTAssertEqual(state.state, .sleep)

        // SLEEP → ACTIVE
        state.transition(to: .active)
        XCTAssertEqual(state.state, .active)

        // ACTIVE → SLEEP
        state.transition(to: .sleep)
        XCTAssertEqual(state.state, .sleep)

        // SLEEP → OFF
        state.transition(to: .off)
        XCTAssertEqual(state.state, .off)
    }

    @MainActor
    func testInvalidTransitionRejected() {
        let state = AppState.shared

        if state.state != .off {
            state.transition(to: .off)
        }

        // OFF → ACTIVE is invalid (must go through SLEEP)
        state.transition(to: .active)
        XCTAssertEqual(state.state, .off, "OFF → ACTIVE should be rejected")
    }

    @MainActor
    func testSameStateIsNoOp() {
        let state = AppState.shared

        if state.state != .off {
            state.transition(to: .off)
        }

        let timeBefore = state.lastTransition
        state.transition(to: .off) // Same state
        XCTAssertEqual(state.lastTransition, timeBefore, "Same-state transition should not update timestamp")
    }

    @MainActor
    func testNetworkStatusUpdates() {
        let state = AppState.shared

        state.updateNetworkStatus(false)
        XCTAssertFalse(state.isOnline)

        state.updateNetworkStatus(true)
        XCTAssertTrue(state.isOnline)
    }

    @MainActor
    func testMemoryPressureUpdates() {
        let state = AppState.shared

        state.updateMemoryPressure(.warning)
        XCTAssertEqual(state.memoryPressure, .warning)

        state.updateMemoryPressure(.nominal)
        XCTAssertEqual(state.memoryPressure, .nominal)
    }
}
