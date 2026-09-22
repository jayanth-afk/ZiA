import os

/// Centralized structured logging via Apple's os.Logger framework.
///
/// Each subsystem gets its own category for filtering in Console.app:
///   - Filter by subsystem: `com.jarvis.app`
///   - Filter by category: `voice`, `brain`, `actions`, etc.
enum JarvisLogger {
    private static let subsystem = "com.jarvis.app"

    /// App lifecycle, state transitions
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Voice pipeline: STT, TTS, wake word, VAD
    static let voice = Logger(subsystem: subsystem, category: "voice")

    /// Brain: routing, intent classification, provider calls
    static let brain = Logger(subsystem: subsystem, category: "brain")

    /// Action execution: macOS control, shell, automation
    static let actions = Logger(subsystem: subsystem, category: "actions")

    /// Memory: conversation storage, fact extraction, vector search
    static let memory = Logger(subsystem: subsystem, category: "memory")

    /// EventBus dispatching
    static let events = Logger(subsystem: subsystem, category: "events")

    /// Network connectivity
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Resource management: memory pressure, model loading
    static let resources = Logger(subsystem: subsystem, category: "resources")

    /// Pipeline timing and latency measurement
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")

    /// Security: permissions, data classification, sandbox
    static let security = Logger(subsystem: subsystem, category: "security")
}
