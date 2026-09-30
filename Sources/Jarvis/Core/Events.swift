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

/// Semantic interaction state emitted by the production voice/agent pipeline.
/// UI surfaces consume this contract instead of inferring backend work from
/// AppState (which describes enablement, not the current interaction).
enum InteractionPhase: String, Sendable, CaseIterable {
    case idle
    case listening
    case understanding
    case thinking
    case executing
    case speaking
    case success
    case error
    case stopped
}

struct InteractionPhaseChangedEvent: JarvisEvent {
    let phase: InteractionPhase
    let taskID: String?
    let timestamp: Date

    init(phase: InteractionPhase, taskID: String? = nil, timestamp: Date = .now) {
        self.phase = phase
        self.taskID = taskID
        self.timestamp = timestamp
    }
}

/// Serializes backend progress and actual speech state into one UI contract.
/// Speech temporarily overlays backend progress; when utterance ends, the
/// latest backend phase is restored so an acknowledgement cannot make a
/// still-running task look idle or complete.
@MainActor
enum InteractionPhaseCenter {
    private(set) static var backendPhase: InteractionPhase = .idle
    private static var taskID: String?
    private static var isSpeechActive = false

    static func report(_ phase: InteractionPhase, taskID: String? = nil) {
        backendPhase = phase
        self.taskID = taskID
        emit(isSpeechActive ? .speaking : phase)
    }

    static func speechStarted() {
        isSpeechActive = true
        emit(.speaking)
    }

    static func speechFinished() {
        isSpeechActive = false
        emit(backendPhase)
    }

    static func resetForTesting() {
        backendPhase = .idle
        taskID = nil
        isSpeechActive = false
    }

    private static func emit(_ phase: InteractionPhase) {
        EventBus.shared.publish(InteractionPhaseChangedEvent(phase: phase, taskID: taskID))
    }
}

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
