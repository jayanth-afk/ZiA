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
    /// The provider was rejected by a quota/rate limit (HTTP 429 or equivalent).
    ///
    /// This is deliberately distinct from `.error`: a rate limit is a
    /// *temporary* condition with a server-known duration, so the router cools
    /// the worker down for exactly that long instead of counting it toward the
    /// hard-failure circuit breaker (which would quarantine a perfectly healthy
    /// provider for minutes over a momentary throttle). `retryAfter` is the
    /// server-provided delay in seconds when present.
    case rateLimited(retryAfter: TimeInterval?)
}

/// Parses HTTP rate-limit signals into a bounded cooldown.
///
/// Kept provider-agnostic so every OpenAI-compatible backend emits the same
/// typed signal. `Retry-After` is interpreted in its delta-seconds form; the
/// HTTP-date form (rare for these APIs) is ignored, falling back to the default.
enum ProviderRateLimit {
    /// Cooldown applied when the server does not say how long to wait.
    static let defaultCooldown: TimeInterval = 30
    /// Hard upper bound so a hostile or buggy `Retry-After` can never park a
    /// worker indefinitely.
    static let maxCooldown: TimeInterval = 900

    /// `Retry-After` (delta-seconds) from a response, clamped to a sane range.
    /// Returns nil when absent or unparseable, so callers fall back to the default.
    static func retryAfter(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return clamp(seconds) }
        return nil
    }

    /// Resolve a server hint (or nil) to the cooldown actually applied.
    static func cooldown(for retryAfter: TimeInterval?) -> TimeInterval {
        guard let retryAfter else { return defaultCooldown }
        return clamp(retryAfter)
    }

    static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, 1), maxCooldown)
    }
}

// MARK: - Provider Protocol

/// Universal protocol that every AI provider (MLX local, Claude, Gemini, OpenAI, Groq) conforms to.
protocol LLMProvider: Actor {
    nonisolated var id: String { get }
    nonisolated var capabilities: Set<Capability> { get }
    var isAvailable: Bool { get async }
    nonisolated var currentLatencyMs: Int { get }

    /// Verified availability (N1). When `probe` is false the provider must answer
    /// from cheap local facts only (NEVER the network) and is expected to return
    /// `.unverified` when all it knows is "a key is configured". When `probe` is
    /// true the provider MAY make a single bounded probe (≤ `ProviderAvailability.probeTimeout`).
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error>

    /// Optional per-request overrides (e.g. ["max_tokens": 384]). Default
    /// implementation ignores options and forwards to complete(messages:tools:stream:).
    /// Callers that never pass options are unaffected.
    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool,
        options: [String: any Sendable]
    ) -> AsyncThrowingStream<StreamChunk, any Error>
}

extension LLMProvider {
    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool,
        options: [String: any Sendable]
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        complete(messages: messages, tools: tools, stream: stream)
    }

    /// Default verified availability: derive from the provider's own boolean.
    /// This never claims more than `isAvailable`, and never touches the network.
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        await isAvailable ? .available : .unavailable(reason: "not configured")
    }
}
