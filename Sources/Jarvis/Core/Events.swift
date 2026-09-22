import Foundation

// MARK: - Event Protocol

/// All events published through EventBus must conform to this protocol.
/// Sendable is required for safe cross-isolation passing.
protocol JarvisEvent: Sendable {}

// MARK: - State Events

/// Emitted when JARVIS transitions between states (OFF/SLEEP/ACTIVE).
struct StateChangedEvent: JarvisEvent {
    let from: AppState.State
    let to: AppState.State
    let timestamp: Date = .now
}

// MARK: - System Events

/// Network connectivity changed.
struct NetworkStatusChangedEvent: JarvisEvent {
    let isOnline: Bool
    let connectionType: String
}

/// Memory pressure level changed.
struct MemoryPressureChangedEvent: JarvisEvent {
    let level: ResourceManager.PressureLevel
    let availableMemoryMB: Int
}

// MARK: - Input Events

/// Global hotkey (Option+Space) was pressed.
struct HotkeyPressedEvent: JarvisEvent {}

/// Emergency stop phrase detected — bypasses normal pipeline.
struct EmergencyStopEvent: JarvisEvent {
    let phrase: String
}

// MARK: - Voice Events (Phase 2 placeholders — types defined now for EventBus wiring)

/// Wake word ("Jarvis") detected by keyword spotter.
struct WakeWordDetectedEvent: JarvisEvent {}

/// Partial transcript available from STT.
struct TranscriptPartialEvent: JarvisEvent {
    let text: String
}

/// Final transcript from STT — ready for routing.
struct TranscriptFinalEvent: JarvisEvent {
    let text: String
    let durationMs: Double
}

/// User interrupted JARVIS while it was speaking.
struct UserInterruptedEvent: JarvisEvent {}

// MARK: - Routing Events (Phase 3-5 placeholders)

/// Intent was classified (deterministic or LLM).
struct IntentDetectedEvent: JarvisEvent {
    let intent: String
    let confidence: Double
    let isDeterministic: Bool
}

/// A provider was selected for the current query.
struct ProviderSelectedEvent: JarvisEvent {
    let provider: String
    let reason: String
}

/// A provider failed; fallback activated.
struct ProviderFailedEvent: JarvisEvent {
    let provider: String
    let error: String
    let fallbackProvider: String?
}

// MARK: - Task Events (Phase 7 placeholders)

/// A task was created in the worker pool.
struct TaskCreatedEvent: JarvisEvent {
    let taskID: String
    let description: String
}

/// Task progress update.
struct TaskProgressEvent: JarvisEvent {
    let taskID: String
    let stage: String
    let detail: String?
}

/// Task completed (success or failure).
struct TaskCompletedEvent: JarvisEvent {
    let taskID: String
    let success: Bool
    let result: String?
    let error: String?
}
