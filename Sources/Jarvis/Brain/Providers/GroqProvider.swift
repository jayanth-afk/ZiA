import Foundation

/// Groq LPU provider for ultra-low latency inference (~300 tokens/sec).
actor GroqProvider: LLMProvider {
    nonisolated let id = "groq"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling
    ]
    nonisolated let currentLatencyMs = 150

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    var isAvailable: Bool {
        get async {
            let hasKey = await KeychainManager.shared.hasAPIKey(for: .groq)
            let isOnline = await NetworkMonitor.shared.isOnline
            return hasKey && isOnline
        }
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard await self.isAvailable else {
                    continuation.yield(.error("Groq provider is unavailable (offline or missing API key)"))
                    continuation.finish()
                    return
                }

                guard let apiKey = await KeychainManager.shared.getAPIKey(for: .groq) else {
                    continuation.yield(.error("Groq API key is missing from Keychain"))
                    continuation.finish()
                    return
                }

                let modelName = await Config.shared.modelName(for: "fast") ?? "llama-3.3-70b-versatile"

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
                        continuation.yield(.error("Groq API error: \(errorMsg)"))
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
        }
    }

    func healthCheck() async -> ProviderHealth {
        let available = await self.isAvailable
        return ProviderHealth(
            isHealthy: available,
            latencyMs: currentLatencyMs,
            message: available ? "Groq LPU ready" : "Key missing or offline"
        )
    }
}
