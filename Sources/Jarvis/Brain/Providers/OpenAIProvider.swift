import Foundation

/// OpenAI provider for GPT-4o conversational intelligence and code generation.
actor OpenAIProvider: LLMProvider {
    nonisolated let id = "openai"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling,
        .codeGeneration,
        .realtimeVoice,
        .structuredOutput
    ]
    nonisolated let currentLatencyMs = 450

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    var isAvailable: Bool {
        get async {
            let hasKey = await KeychainManager.shared.hasAPIKey(for: .openai)
            let isOnline = await NetworkMonitor.shared.isOnline
            return hasKey && isOnline
        }
    }

    /// N1: a configured key is *unverified*, not available (no network on this path).
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard await KeychainManager.shared.hasAPIKey(for: .openai) else {
            return .unavailable(reason: "no OpenAI API key configured")
        }
        guard await NetworkMonitor.shared.isOnline else {
            return .unavailable(reason: "offline")
        }
        return .unverified(reason: "OpenAI API key configured; live availability not verified")
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard await self.isAvailable else {
                    continuation.yield(.error("OpenAI provider is unavailable (offline or missing API key)"))
                    continuation.finish()
                    return
                }

                guard let apiKey = await KeychainManager.shared.getAPIKey(for: .openai) else {
                    continuation.yield(.error("OpenAI API key is missing from Keychain"))
                    continuation.finish()
                    return
                }

                let modelName = await Config.shared.modelName(for: "general") ?? "gpt-4o"

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
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
                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        if status == 429 {
                            continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
                        } else {
                            continuation.yield(.error("OpenAI API error: \(errorMsg)"))
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
            message: available ? "OpenAI API ready" : "Key missing or offline"
        )
    }
}
