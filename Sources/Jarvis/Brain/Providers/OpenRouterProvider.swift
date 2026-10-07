import Foundation

/// OpenRouter provider for unified multi-model routing and access to open & frontier models.
actor OpenRouterProvider: LLMProvider {
    nonisolated let id = "openrouter"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling,
        .codeGeneration,
        .longContext,
        .structuredOutput
    ]
    nonisolated let currentLatencyMs = 350

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    var isAvailable: Bool {
        get async {
            let hasKey = await KeychainManager.shared.hasAPIKey(for: .openrouter)
            let isOnline = await NetworkMonitor.shared.isOnline
            return hasKey && isOnline
        }
    }

    /// N1: a configured key is *unverified*, not available (no network on this path).
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard await KeychainManager.shared.hasAPIKey(for: .openrouter) else {
            return .unavailable(reason: "no OpenRouter API key configured")
        }
        guard await NetworkMonitor.shared.isOnline else {
            return .unavailable(reason: "offline")
        }
        return .unverified(reason: "OpenRouter API key configured; live availability not verified")
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        complete(messages: messages, tools: tools, stream: stream, options: [:])
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool,
        options: [String: any Sendable]
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard await self.isAvailable else {
                    continuation.yield(.error("OpenRouter provider is unavailable (offline or missing API key)"))
                    continuation.finish()
                    return
                }

                guard let apiKey = await KeychainManager.shared.getAPIKey(for: .openrouter) else {
                    continuation.yield(.error("OpenRouter API key is missing from Keychain"))
                    continuation.finish()
                    return
                }

                let configuredModel = await Config.shared.modelName(for: "openrouter")
                let modelName = (options["model"] as? String) ?? configuredModel ?? "nvidia/nemotron-3-ultra-550b-a55b:free"

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("https://jarvis.app", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Jarvis AI", forHTTPHeaderField: "X-Title")

                var apiMessages: [[String: String]] = []
                for msg in messages {
                    apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
                }

                var body: [String: Any] = [
                    "model": modelName,
                    "messages": apiMessages,
                    "stream": stream
                ]

                if let maxTokens = options["max_tokens"] as? Int {
                    body["max_tokens"] = maxTokens
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        if status == 429 {
                            continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: httpResponse)))
                        } else {
                            continuation.yield(.error("OpenRouter API error: \(errorMsg)"))
                        }
                        continuation.finish()
                        return
                    }

                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        continuation.yield(.text(content))

                        let usageDict = json["usage"] as? [String: Any]
                        let inTokens = usageDict?["prompt_tokens"] as? Int ?? 0
                        let outTokens = usageDict?["completion_tokens"] as? Int ?? 0
                        continuation.yield(.done(usage: TokenUsage(promptTokens: inTokens, completionTokens: outTokens, totalTokens: inTokens + outTokens)))
                    }

                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func healthCheck() async -> ProviderHealth {
        let available = await self.isAvailable
        return ProviderHealth(
            isHealthy: available,
            latencyMs: currentLatencyMs,
            message: available ? "OpenRouter API ready" : "Key missing or offline"
        )
    }
}
