import Foundation

/// Configuration store backed by UserDefaults.
///
/// All provider model names and provider assignments are configuration,
/// not code. Changing a model should never require changing the architecture.
///
/// Provider config slots:
///   reflex   — local small model for intent classification
///   normal   — local medium model for general queries
///   deep     — cloud model for complex reasoning
///   vision   — cloud model for multimodal/screen understanding
///   speed    — cloud model for fast fallback
///   realtime — cloud model for speech-to-speech conversation
@MainActor
final class Config {
    static let shared = Config()

    private let defaults = UserDefaults.standard

    private init() {
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            // Wake word
            Keys.wakeWord: "jarvis",

            // Hotkey
            Keys.hotkeyEnabled: true,

            // Autonomy (0=autonomous, 1=notify, 2=confirm, 3=review)
            Keys.autonomyLevel: 1,

            // TTS
            Keys.ttsProvider: "apple",

            // Provider model slots (empty = not configured)
            Keys.reflexModel: "",
            Keys.normalModel: "",

            // Cloud provider assignments
            Keys.deepProvider: "anthropic",
            Keys.deepModel: "",
            Keys.visionProvider: "google",
            Keys.visionModel: "",
            Keys.speedProvider: "groq",
            Keys.speedModel: "",
            Keys.realtimeProvider: "openai",
            Keys.realtimeModel: "",

            // Budget
            Keys.dailyBudgetUSD: 5.0,

            // Memory
            Keys.autoExtractMemory: true,
            Keys.inferredMemoryEnabled: false,

            // Resource management
            Keys.modelIdleEvictionSeconds: 300.0, // 5 minutes
            Keys.memoryReserveMB: 4096,           // 4GB for macOS + apps
        ])
    }

    // MARK: - Keys namespace

    private enum Keys {
        static let wakeWord = "jarvis.wakeWord"
        static let hotkeyEnabled = "jarvis.hotkey.enabled"
        static let autonomyLevel = "jarvis.autonomyLevel"
        static let ttsProvider = "jarvis.voice.ttsProvider"

        static let reflexModel = "jarvis.provider.reflex.model"
        static let normalModel = "jarvis.provider.normal.model"

        static let deepProvider = "jarvis.provider.deep.provider"
        static let deepModel = "jarvis.provider.deep.model"
        static let visionProvider = "jarvis.provider.vision.provider"
        static let visionModel = "jarvis.provider.vision.model"
        static let speedProvider = "jarvis.provider.speed.provider"
        static let speedModel = "jarvis.provider.speed.model"
        static let realtimeProvider = "jarvis.provider.realtime.provider"
        static let realtimeModel = "jarvis.provider.realtime.model"

        static let dailyBudgetUSD = "jarvis.budget.dailyLimit"
        static let autoExtractMemory = "jarvis.memory.autoExtract"
        static let inferredMemoryEnabled = "jarvis.memory.inferredEnabled"
        static let modelIdleEvictionSeconds = "jarvis.resource.modelIdleEviction"
        static let memoryReserveMB = "jarvis.resource.memoryReserveMB"
    }

    // MARK: - General

    var wakeWord: String {
        get { defaults.string(forKey: Keys.wakeWord) ?? "jarvis" }
        set { defaults.set(newValue, forKey: Keys.wakeWord) }
    }

    var hotkeyEnabled: Bool {
        get { defaults.bool(forKey: Keys.hotkeyEnabled) }
        set { defaults.set(newValue, forKey: Keys.hotkeyEnabled) }
    }

    var autonomyLevel: Int {
        get { defaults.integer(forKey: Keys.autonomyLevel) }
        set { defaults.set(min(max(newValue, 0), 3), forKey: Keys.autonomyLevel) }
    }

    var ttsProvider: String {
        get { defaults.string(forKey: Keys.ttsProvider) ?? "apple" }
        set { defaults.set(newValue, forKey: Keys.ttsProvider) }
    }

    // MARK: - Budget

    var dailyBudgetUSD: Double {
        get { defaults.double(forKey: Keys.dailyBudgetUSD) }
        set { defaults.set(newValue, forKey: Keys.dailyBudgetUSD) }
    }

    // MARK: - Memory

    var autoExtractMemory: Bool {
        get { defaults.bool(forKey: Keys.autoExtractMemory) }
        set { defaults.set(newValue, forKey: Keys.autoExtractMemory) }
    }

    var inferredMemoryEnabled: Bool {
        get { defaults.bool(forKey: Keys.inferredMemoryEnabled) }
        set { defaults.set(newValue, forKey: Keys.inferredMemoryEnabled) }
    }

    // MARK: - Resources

    var modelIdleEvictionSeconds: TimeInterval {
        get { defaults.double(forKey: Keys.modelIdleEvictionSeconds) }
        set { defaults.set(newValue, forKey: Keys.modelIdleEvictionSeconds) }
    }

    var memoryReserveMB: Int {
        get { defaults.integer(forKey: Keys.memoryReserveMB) }
        set { defaults.set(newValue, forKey: Keys.memoryReserveMB) }
    }

    // MARK: - Provider Model Config (generic slot access)

    /// Get the configured model name for a provider slot.
    func modelName(for slot: String) -> String? {
        let value = defaults.string(forKey: "jarvis.provider.\(slot).model")
        return (value?.isEmpty == true) ? nil : value
    }

    /// Set the model name for a provider slot.
    func setModelName(_ name: String, for slot: String) {
        defaults.set(name, forKey: "jarvis.provider.\(slot).model")
        JarvisLogger.app.info("Model for \(slot) set to: \(name)")
    }

    /// Get the provider assignment for a cloud slot.
    func providerName(for slot: String) -> String? {
        defaults.string(forKey: "jarvis.provider.\(slot).provider")
    }

    /// Set the provider assignment for a cloud slot.
    func setProviderName(_ name: String, for slot: String) {
        defaults.set(name, forKey: "jarvis.provider.\(slot).provider")
        JarvisLogger.app.info("Provider for \(slot) set to: \(name)")
    }
}
