import Foundation

/// Bounded, deterministic rendering of actual prior conversation turns.
/// This source is conversational context only and is never consulted by the
/// reference resolver or execution pipeline.
enum ConversationHistoryAnswer {
    static func recentSummary(messages: [Message], limit: Int = 6) -> String {
        let maxLimit = max(1, limit)
        var turns: [Message] = []
        turns.reserveCapacity(maxLimit)

        // Single backward pass to collect last 'limit' user/assistant messages without allocating full filtered array
        for message in messages.reversed() {
            if message.role == .user || message.role == .assistant {
                turns.append(message)
                if turns.count >= maxLimit { break }
            }
        }

        guard !turns.isEmpty else { return "We haven't discussed anything in this conversation yet." }

        var result = "Recently, we discussed:\n"
        result.reserveCapacity(128 + turns.count * 120)

        // Iterate in chronological order
        for message in turns.reversed() {
            let speaker = message.role == .user ? "You" : "I"
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(speaker)
            result.append(": ")
            if content.count > 240 {
                result.append(contentsOf: content.prefix(240))
            } else {
                result.append(content)
            }
            result.append("\n")
        }

        if result.hasSuffix("\n") {
            result.removeLast()
        }

        return result
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