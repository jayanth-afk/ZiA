import Foundation

/// A structured message in a JARVIS conversation.
struct Message: Sendable, Identifiable, Codable {
    enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    let id: String
    let role: Role
    let content: String
    let timestamp: Date
    let toolCallID: String?

    init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        timestamp: Date = .now,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCallID = toolCallID
    }
}
