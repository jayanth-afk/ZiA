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
}