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
                content: "You are JARVIS, a voice-first macOS assistant. Answer the user's actual request directly, use relevant conversation context, and be concise by default (one or two spoken sentences). Take authorized actions instead of merely describing how; never claim an action succeeded without evidence. Ask one brief clarifying question only when ambiguity changes the action or answer. Avoid greetings and filler."
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
        // Preserve the system prompt and complete user/assistant turns wherever
        // possible; orphaned turns degrade relevance and confuse provider context.
        let system = messages[0]
        var remaining = Array(messages.dropFirst())
        while remaining.count > maxHistoryCount {
            if remaining.count >= 2,
               remaining[0].role == .user,
               remaining[1].role == .assistant {
                remaining.removeFirst(2)
            } else {
                remaining.removeFirst()
            }
        }
        messages = [system] + remaining
    }
}
