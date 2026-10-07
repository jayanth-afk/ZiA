import Foundation

/// Groq LPU provider for ultra-low latency inference (~300 tokens/sec).
///
/// Honest capability notes:
///   • Both `stream: true` (SSE) and `stream: false` (single JSON body) are
///     parsed. SSE deltas are forwarded as they arrive; the terminal `[DONE]`
///     sentinel and any trailing usage are handled.
///   • The configured model is NOT assumed to exist. `verifyModelAvailability()`
///     checks Groq's `/models` with a bounded timeout and returns the exact
///     reason when the model is absent, instead of silently substituting one.
///   • The session and API key are injectable so tests exercise the real request
///     path against a `URLProtocol` mock with no network access.
actor GroqProvider: LLMProvider {
    nonisolated let id: String
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling
    ]
    nonisolated let currentLatencyMs = 150

    /// Production fallback when the `fast` config slot is unset.
    static let fallbackModel = "openai/gpt-oss-20b"

    /// Outcome of a live model-availability probe. Always carries the reason
    /// when unavailable — never a bare boolean.
    enum ModelAvailability: Equatable, Sendable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// When nil, the model is read from the configured slot at request time.
    private let modelOverride: String?
    private let modelSlot: String
    /// API key injected by a caller (test). When nil, the keychain is consulted.
    private let apiKeyOverride: String?
    /// When false, the keychain is never consulted (tests that pin the
    /// "no key" path deterministically). Production uses the keychain.
    private let usesKeychain: Bool
    private let session: URLSession

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let modelsEndpoint = URL(string: "https://api.groq.com/openai/v1/models")!
    /// Bounds for the two request kinds. Chat is generous; the model probe must
    /// never stall a health check.
    private let chatTimeout: TimeInterval = 20
    private let modelsTimeout: TimeInterval = 5

    init(id: String = "groq", model: String? = nil, modelSlot: String = "fast",
         session: URLSession = .shared, apiKey: String? = nil,
         usesKeychain: Bool = true) {
        self.id = id
        self.modelOverride = model
        self.modelSlot = modelSlot
        self.session = session
        self.apiKeyOverride = apiKey
        self.usesKeychain = usesKeychain
    }

    /// The model this provider will actually request.
    var resolvedModel: String {
        get async {
            if let modelOverride { return modelOverride }
            if let configured = await Config.shared.modelName(for: modelSlot) {
                return configured
            }
            if modelSlot == "strong" {
                return "openai/gpt-oss-120b"
            }
            return Self.fallbackModel
        }
    }

    /// Whether a Groq API key is configured (injected or in the keychain).
    var hasAPIKey: Bool {
        get async { await resolveAPIKey() != nil }
    }

    var isAvailable: Bool {
        get async {
            guard await resolveAPIKey() != nil else { return false }
            if apiKeyOverride != nil { return true }
            return await NetworkMonitor.shared.isOnline
        }
    }

    /// N1: Groq is `.available` only when the configured model is confirmed by the
    /// bounded `/models` probe. Without a probe, a configured key is `.unverified`
    /// — a key alone never proves the model this account can actually use.
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard await resolveAPIKey() != nil else {
            return .unavailable(reason: "no Groq API key configured")
        }
        guard probe else {
            return .unverified(reason: "Groq API key configured; model not verified")
        }
        switch await verifyModelAvailability() {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }

    private func resolveAPIKey() async -> String? {
        if let apiKeyOverride { return apiKeyOverride }
        if !usesKeychain { return nil }
        return await KeychainManager.shared.getAPIKey(for: .groq)
    }

    // MARK: - Model availability (bounded, exact reason)

    /// Verify the configured model against Groq's `/models`. Bounded by
    /// `modelsTimeout`; every failure path returns the exact reason.
    func verifyModelAvailability() async -> ModelAvailability {
        guard let apiKey = await resolveAPIKey() else {
            return .unavailable(reason: "no Groq API key configured")
        }
        if apiKeyOverride == nil, await !NetworkMonitor.shared.isOnline {
            return .unavailable(reason: "offline")
        }
        let model = await resolvedModel

        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = modelsTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable(reason: "no HTTP response from Groq /models")
            }
            guard (200...299).contains(http.statusCode) else {
                let body = (String(data: data, encoding: .utf8) ?? "").prefix(160)
                return .unavailable(reason: "Groq /models HTTP \(http.statusCode): \(body)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                return .unavailable(reason: "Groq /models returned an unparseable body")
            }
            let ids = models.compactMap { $0["id"] as? String }
            if ids.contains(model) { return .available }
            return .unavailable(reason: "model '\(model)' is not available to this account (Groq /models lists \(ids.count) models)")
        } catch {
            return .unavailable(reason: "Groq /models request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Completion

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = await self.resolveAPIKey() else {
                    continuation.yield(.error("Groq API key is missing from Keychain"))
                    continuation.finish()
                    return
                }
                if self.apiKeyOverride == nil, await !NetworkMonitor.shared.isOnline {
                    continuation.yield(.error("Groq provider is unavailable (offline)"))
                    continuation.finish()
                    return
                }

                let modelName = await self.resolvedModel

                var request = URLRequest(url: self.endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = self.chatTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                var apiMessages: [[String: String]] = []
                for msg in messages {
                    apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
                }

                let body: [String: Any] = [
                    "model": modelName,
                    "messages": apiMessages,
                    "stream": stream
                ]

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    if stream {
                        try await self.streamCompletion(request, continuation: continuation)
                    } else {
                        try await self.singleCompletion(request, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
            // Cancellation propagation: when the consumer stops iterating (an
            // interruption, a "wait", or a superseded turn), cancel the in-flight
            // request instead of orphaning it. Without this the Task keeps
            // streaming into a dead continuation — an orphaned stream.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming: one JSON body with a single `choices[0].message.content`.
    private func singleCompletion(
        _ request: URLRequest,
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation
    ) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (String(data: data, encoding: .utf8) ?? "").prefix(300)
            if status == 429 {
                continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
            } else {
                continuation.yield(.error("Groq API error: HTTP \(status): \(body)"))
            }
            return
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            continuation.yield(.error("Groq returned an unparseable response body"))
            return
        }
        continuation.yield(.text(content))
        continuation.yield(.done(usage: Self.usage(from: json)))
    }

    /// Streaming: parse Server-Sent Events (`data: {json}` lines, `[DONE]` end).
    /// Previously the provider advertised streaming but returned an unparseable
    /// body when `stream:true` was requested; the SSE framing is now handled.
    private func streamCompletion(
        _ request: URLRequest,
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Drain a bounded prefix of the error body for an exact message.
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 300 { break }
            }
            if status == 429 {
                continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
            } else {
                continuation.yield(.error("Groq API error: HTTP \(status) \(body.prefix(300))"))
            }
            return
        }

        var usage = TokenUsage.zero
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.text(content))
            }
            if json["usage"] != nil {
                usage = Self.usage(from: json)
            }
        }
        continuation.yield(.done(usage: usage))
    }

    private static func usage(from json: [String: Any]) -> TokenUsage {
        let usageDict = json["usage"] as? [String: Any]
        let inTokens = usageDict?["prompt_tokens"] as? Int ?? 0
        let outTokens = usageDict?["completion_tokens"] as? Int ?? 0
        return TokenUsage(promptTokens: inTokens, completionTokens: outTokens, totalTokens: inTokens + outTokens)
    }

    // MARK: - Health

    /// Health is not "the key exists" — it is "the configured model actually
    /// answers". The probe is bounded and its exact reason is surfaced.
    func healthCheck() async -> ProviderHealth {
        guard await resolveAPIKey() != nil else {
            return ProviderHealth(isHealthy: false, latencyMs: 0, message: "Groq unavailable: no API key configured")
        }
        let model = await resolvedModel
        switch await verifyModelAvailability() {
        case .available:
            return ProviderHealth(isHealthy: true, latencyMs: currentLatencyMs,
                                  message: "Groq LPU ready (model '\(model)' confirmed via /models)")
        case .unavailable(let reason):
            return ProviderHealth(isHealthy: false, latencyMs: 0,
                                  message: "Groq model '\(model)' unavailable: \(reason)")
        }
    }
}
