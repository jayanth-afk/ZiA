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

        // Prune older user/assistant messages if exceeding token limit
        while estimateTokens(messages: context) > tokenLimit && context.count > 2 {
            context.remove(at: 1) // Remove oldest non-system message
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
        Guidelines: Be concise, direct, intelligent, and execute actions decisively.
        """
    }
}
