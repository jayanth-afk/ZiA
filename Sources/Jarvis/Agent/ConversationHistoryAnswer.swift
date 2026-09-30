import Foundation

/// Bounded, deterministic rendering of actual prior conversation turns.
/// This source is conversational context only and is never consulted by the
/// reference resolver or execution pipeline.
enum ConversationHistoryAnswer {
    static func recentSummary(messages: [Message], limit: Int = 6) -> String {
        let turns = Array(messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(max(1, limit)))
        guard !turns.isEmpty else { return "We haven't discussed anything in this conversation yet." }

        let rendered = turns.map { message -> String in
            let speaker = message.role == .user ? "You" : "I"
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(speaker): \(String(content.prefix(240)))"
        }
        return "Recently, we discussed:\n" + rendered.joined(separator: "\n")
    }

    @MainActor
    static func recentSummary() -> String {
        var messages = ConversationManager.shared.messages
        if !messages.contains(where: { $0.role == .user || $0.role == .assistant }) {
            messages = ConversationStore.shared.loadMessages(limit: 12)
        }
        return recentSummary(messages: messages)
    }
}
