import Foundation

/// Cerebras Inference provider. Uses the OpenAI-compatible chat-completions API
/// so Cerebras can act as an independent high-speed fallback for GPT-OSS 120B.
actor CerebrasProvider: LLMProvider {
    nonisolated let id = "cerebras"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .codeGeneration,
        .longContext,
        .structuredOutput
    ]
    nonisolated let currentLatencyMs = 300

    static let fallbackModel = "gpt-oss-120b"

    private let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
    private let modelsEndpoint = URL(string: "https://api.cerebras.ai/v1/models")!
    private let session: URLSession
    private let modelOverride: String?
    private let apiKeyOverride: String?
    private let usesKeychain: Bool
    private let chatTimeout: TimeInterval = 20
    private let modelsTimeout: TimeInterval = 5

    init(model: String? = nil, session: URLSession = .shared,
         apiKey: String? = nil, usesKeychain: Bool = true) {
        self.modelOverride = model
        self.session = session
        self.apiKeyOverride = apiKey
        self.usesKeychain = usesKeychain
    }

    var resolvedModel: String {
        get async {
            if let modelOverride { return modelOverride }
            return await Config.shared.modelName(for: "cerebras") ?? Self.fallbackModel
        }
    }

    private func resolveAPIKey() async -> String? {
        if let apiKeyOverride { return apiKeyOverride }
        if !usesKeychain { return nil }
        return await KeychainManager.shared.getAPIKey(for: .cerebras)
    }

    var isAvailable: Bool {
        get async {
            guard await resolveAPIKey() != nil else { return false }
            return await NetworkMonitor.shared.isOnline
        }
    }

    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard await resolveAPIKey() != nil else {
            return .unavailable(reason: "no Cerebras API key configured")
        }
        guard await NetworkMonitor.shared.isOnline else {
            return .unavailable(reason: "offline")
        }
        guard probe else {
            return .unverified(reason: "Cerebras API key configured; model not verified")
        }
        switch await verifyModelAvailability() {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }

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

    func verifyModelAvailability() async -> ModelAvailability {
        guard let apiKey = await resolveAPIKey() else {
            return .unavailable(reason: "no Cerebras API key configured")
        }

        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = modelsTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .unavailable(reason: "Cerebras /models HTTP \(status)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                return .unavailable(reason: "Cerebras /models returned an unparseable body")
            }
            let ids = models.compactMap { $0["id"] as? String }
            let model = await resolvedModel
            return ids.contains(model)
                ? .available
                : .unavailable(reason: "model '\(model)' is not available to this Cerebras account")
        } catch {
            return .unavailable(reason: "Cerebras /models request failed: \(error.localizedDescription)")
        }
    }

    func complete(messages: [Message], tools: [ToolDefinition]?, stream: Bool)
        -> AsyncThrowingStream<StreamChunk, any Error> {
        complete(messages: messages, tools: tools, stream: stream, options: [:])
    }

    func complete(messages: [Message], tools: [ToolDefinition]?, stream: Bool,
                   options: [String: any Sendable])
        -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = await self.resolveAPIKey() else {
                    continuation.yield(.error("Cerebras API key is missing from Keychain"))
                    continuation.finish()
                    return
                }
                guard await NetworkMonitor.shared.isOnline else {
                    continuation.yield(.error("Cerebras provider is unavailable (offline)"))
                    continuation.finish()
                    return
                }

                let resolvedModel = await self.resolvedModel
                let model = (options["model"] as? String) ?? resolvedModel
                var request = URLRequest(url: self.endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = self.chatTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                let apiMessages = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                var body: [String: Any] = [
                    "model": model,
                    "messages": apiMessages,
                    "stream": stream
                ]
                if let maxTokens = options["max_tokens"] as? Int {
                    body["max_tokens"] = maxTokens
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    if stream {
                        try await self.streamCompletion(request, continuation: continuation)
                    } else {
                        try await self.singleCompletion(request, continuation: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func singleCompletion(
        _ request: URLRequest,
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation
    ) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            if status == 429 {
                continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
            } else {
                continuation.yield(.error("Cerebras API error: HTTP \(status): \(body.prefix(300))"))
            }
            return
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            continuation.yield(.error("Cerebras returned an unparseable response body"))
            return
        }
        continuation.yield(.text(content))
        continuation.yield(.done(usage: Self.usage(from: json)))
    }

    private func streamCompletion(
        _ request: URLRequest,
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 300 { break }
            }
            if status == 429 {
                continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
            } else {
                continuation.yield(.error("Cerebras API error: HTTP \(status): \(body.prefix(300))"))
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
        let usage = json["usage"] as? [String: Any]
        let input = usage?["prompt_tokens"] as? Int ?? 0
        let output = usage?["completion_tokens"] as? Int ?? 0
        return TokenUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
    }

    func healthCheck() async -> ProviderHealth {
        switch await verifyModelAvailability() {
        case .available:
            return ProviderHealth(isHealthy: true, latencyMs: currentLatencyMs,
                                  message: "Cerebras ready (model '\(await resolvedModel)' confirmed)")
        case .unavailable(let reason):
            return ProviderHealth(isHealthy: false, latencyMs: 0,
                                  message: "Cerebras unavailable: \(reason)")
        }
    }
}
