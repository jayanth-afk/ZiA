import Foundation

/// The global state machine for JARVIS.
///
/// States:
///   OFF    — App running but assistant disabled
///   SLEEP  — Listening for wake word / hotkey only (minimal CPU)
///   ACTIVE — Full pipeline running, processing a query
///
/// Transitions emit `StateChangedEvent` through the `EventBus`.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum State: String, Sendable, CaseIterable {
        case off
        case sleep
        case active
    }

    // MARK: - Published state

    private(set) var state: State = .off
    private(set) var lastTransition: Date = .now

    // System status (updated by monitors)
    private(set) var isOnline: Bool = true
    private(set) var memoryPressure: ResourceManager.PressureLevel = .nominal

    private init() {}

    // MARK: - State transitions

    func transition(to newState: State) {
        let oldState = state
        guard oldState != newState else { return }

        // Validate transition
        guard isValidTransition(from: oldState, to: newState) else {
            JarvisLogger.app.warning("Invalid transition: \(oldState.rawValue) → \(newState.rawValue)")
            return
        }

        state = newState
        lastTransition = .now

        JarvisLogger.app.info("State: \(oldState.rawValue) → \(newState.rawValue)")

        EventBus.shared.publish(StateChangedEvent(from: oldState, to: newState))
    }

    // MARK: - Status updates (called by monitors)

    func updateNetworkStatus(_ online: Bool) {
        isOnline = online
    }

    func updateMemoryPressure(_ level: ResourceManager.PressureLevel) {
        memoryPressure = level
    }

    // MARK: - Transition validation

    /// Valid transitions:
    ///   OFF → SLEEP (enable)
    ///   SLEEP → ACTIVE (wake word / hotkey)
    ///   SLEEP → OFF (disable)
    ///   ACTIVE → SLEEP (query done / timeout)
    ///   ACTIVE → OFF (disable)
    private func isValidTransition(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.off, .sleep): return true
        case (.sleep, .active): return true
        case (.sleep, .off): return true
        case (.active, .sleep): return true
        case (.active, .off): return true
        default: return false
        }
    }
}
