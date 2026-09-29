import Foundation

/// Intelligent context builder that estimates token counts and injects real-time state.
@MainActor
final class ContextBuilder {
    static let shared = ContextBuilder()

    private init() {}

    // MARK: - Public API

    /// Build context with injected system metadata.
    func buildContext(messages: [Message], tokenLimit: Int = 4096) -> [Message] {
        var context = messages

        // Generate dynamic system metadata banner
        let systemPrompt = buildSystemPrompt()

        if let first = context.first, first.role == .system {
            context[0] = Message(role: .system, content: systemPrompt)
        } else {
            context.insert(Message(role: .system, content: systemPrompt), at: 0)
        }

        // Prune old turns as units so the model does not receive an orphaned
        // answer without its question. Keep the newest user request intact.
        while estimateTokens(messages: context) > tokenLimit && context.count > 2 {
            if context.count >= 4,
               context[1].role == .user,
               context[2].role == .assistant {
                context.removeSubrange(1...2)
            } else {
                context.remove(at: 1)
            }
        }

        return context
    }

    /// Fast token estimation (standard rule: ~4 chars per token in English).
    func estimateTokens(messages: [Message]) -> Int {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        return max(1, totalChars / 4)
    }

    // MARK: - Private

    private func buildSystemPrompt() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let now = formatter.string(from: Date())

        let onlineStr = AppState.shared.isOnline ? "Online" : "Offline"
        let memStr = "\(ResourceManager.shared.totalMemoryMB)MB"

        return """
        You are JARVIS, an autonomous personal AI operating layer for macOS.
        Current System Time: \(now)
        Network Status: \(onlineStr)
        Unified Memory: \(memStr)
        Guidelines: Answer the current request directly and use prior context only when relevant. Be concise by default, especially for voice. Ask a clarifying question only when ambiguity changes the action or answer. Never claim an action succeeded unless it was verified. State uncertainty instead of inventing current facts.
        """
    }
}
