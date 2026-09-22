import Foundation

// MARK: - Capabilities

/// Model and provider capabilities for intelligent routing.
enum Capability: String, Sendable, CaseIterable {
    case textGeneration
    case toolCalling
    case vision
    case codeGeneration
    case realtimeVoice
    case longContext
    case structuredOutput
}

// MARK: - Health & Usage

struct ProviderHealth: Sendable {
    let isHealthy: Bool
    let latencyMs: Int
    let message: String?
}

struct TokenUsage: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    static let zero = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
}

// MARK: - Tools

struct ToolCall: Sendable {
    let id: String
    let name: String
    let arguments: String // JSON string
}

struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parametersJSON: String
}

// MARK: - Streaming

enum StreamChunk: Sendable {
    case text(String)
    case toolCall(ToolCall)
    case done(usage: TokenUsage)
    case error(String)
}

// MARK: - Provider Protocol

/// Universal protocol that every AI provider (MLX local, Claude, Gemini, OpenAI, Groq) conforms to.
protocol LLMProvider: Actor {
    nonisolated var id: String { get }
    nonisolated var capabilities: Set<Capability> { get }
    var isAvailable: Bool { get async }
    nonisolated var currentLatencyMs: Int { get }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, Error>

    func healthCheck() async -> ProviderHealth
}
