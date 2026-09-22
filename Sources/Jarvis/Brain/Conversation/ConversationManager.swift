import Foundation

/// Manages active conversation history and context window.
@MainActor
final class ConversationManager {
    static let shared = ConversationManager()

    // MARK: - State
    private(set) var messages: [Message] = []
    var maxHistoryCount = 20

    private init() {
        // Add default system prompt
        reset()
    }

    // MARK: - Public API

    /// Reset conversation history to default system prompt.
    func reset() {
        messages = [
            Message(
                role: .system,
                content: "You are JARVIS, a highly capable voice-first AI assistant for macOS. You are concise, precise, direct, and action-oriented. You speak clearly and avoid robotic greetings."
            )
        ]
        JarvisLogger.brain.info("ConversationManager reset")
    }

    /// Add a user prompt to history.
    func addUserMessage(_ content: String) {
        messages.append(Message(role: .user, content: content))
        trimHistory()
    }

    /// Add an assistant response to history.
    func addAssistantMessage(_ content: String) {
        messages.append(Message(role: .assistant, content: content))
        trimHistory()
    }

    /// Get current messages formatted for provider request.
    func getContext() -> [Message] {
        return messages
    }

    // MARK: - Private

    private func trimHistory() {
        guard messages.count > maxHistoryCount + 1 else { return }
        // Preserve system message at index 0, drop oldest user/assistant turns
        let system = messages[0]
        let remaining = Array(messages.suffix(maxHistoryCount))
        messages = [system] + remaining
    }
}
