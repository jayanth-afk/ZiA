import Foundation

public struct ContextMessage: Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public final class ContextBuilder: @unchecked Sendable {
    public static let shared = ContextBuilder()

    public init() {}

    public func buildContext(
        systemPrompt: String,
        messages: [ContextMessage],
        maxTokens: Int = 4000
    ) -> String {
        let approxMaxChars = maxTokens * 4
        
        var estimatedCapacity = systemPrompt.count + 64
        for msg in messages {
            estimatedCapacity += msg.role.count + msg.content.count + 8
        }
        
        var result = String()
        result.reserveCapacity(min(estimatedCapacity, approxMaxChars))

        result.append(systemPrompt)
        result.append("\n\n")

        var currentLength = result.count
        var includedMessages: [ContextMessage] = []
        includedMessages.reserveCapacity(messages.count)

        for msg in messages.reversed() {
            let msgLength = msg.role.count + msg.content.count + 6
            if currentLength + msgLength > approxMaxChars {
                break
            }
            includedMessages.append(msg)
            currentLength += msgLength
        }

        for msg in includedMessages.reversed() {
            result.append(msg.role)
            result.append(": ")
            result.append(msg.content)
            result.append("\n")
        }

        return result
    }

    func estimateTokens(messages: [Message]) -> Int {
        messages.reduce(0) { $0 + max(1, ($1.content.count + 3) / 4) }
    }

    func buildContext(messages: [Message], tokenLimit: Int = 4000) -> [Message] {
        let suppliedSystem = messages.first(where: { $0.role == .system })?.content ?? ""
        let prompt = "You are JARVIS, a macOS assistant. Never claim an action succeeded without evidence.\n\(suppliedSystem)"
        let budget = max(1, tokenLimit)
        var selected: [Message] = []
        var tokens = max(1, (prompt.count + 3) / 4)
        for message in messages.filter({ $0.role != .system }).reversed() {
            let cost = max(1, (message.content.count + 3) / 4)
            guard tokens + cost <= budget else { break }
            selected.append(message)
            tokens += cost
        }
        return [Message(role: .system, content: prompt)] + selected.reversed()
    }
}