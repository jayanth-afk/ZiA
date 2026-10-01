@testable import Jarvis
import Testing

@Suite struct AppStateTests {

    @Test @MainActor
    func validTransitions() {
        let state = AppState.shared

        // Reset to OFF
        if state.state != .off {
            state.transition(to: .off)
        }
        #expect(state.state == .off)

        // OFF → SLEEP
        state.transition(to: .sleep)
        #expect(state.state == .sleep)

        // SLEEP → ACTIVE
        state.transition(to: .active)
        #expect(state.state == .active)

        // ACTIVE → SLEEP
        state.transition(to: .sleep)
        #expect(state.state == .sleep)

        // SLEEP → OFF
        state.transition(to: .off)
        #expect(state.state == .off)
    }

    @Test @MainActor
    func invalidTransitionRejected() {
        let state = AppState.shared

        if state.state != .off {
            state.transition(to: .off)
        }

        // OFF → ACTIVE is invalid (must go through SLEEP)
        state.transition(to: .active)
        #expect(state.state == .off, "OFF → ACTIVE should be rejected")
    }

    @Test @MainActor
    func sameStateIsNoOp() {
        let state = AppState.shared

        if state.state != .off {
            state.transition(to: .off)
        }

        let timeBefore = state.lastTransition
        state.transition(to: .off) // Same state
        #expect(state.lastTransition == timeBefore, "Same-state transition should not update timestamp")
    }

    @Test @MainActor
    func networkStatusUpdates() {
        let state = AppState.shared

        state.updateNetworkStatus(false)
        #expect(!state.isOnline)

        state.updateNetworkStatus(true)
        #expect(state.isOnline)
    }

    @Test @MainActor
    func memoryPressureUpdates() {
        let state = AppState.shared

        state.updateMemoryPressure(.warning)
        #expect(state.memoryPressure == .warning)

        state.updateMemoryPressure(.nominal)
        #expect(state.memoryPressure == .nominal)
    }
}
