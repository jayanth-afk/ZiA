import Foundation

/// Anthropic Claude provider for deep reasoning, complex analysis, and code generation.
actor ClaudeProvider: LLMProvider {
    nonisolated let id = "anthropic"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling,
        .codeGeneration,
        .longContext,
        .structuredOutput
    ]
    nonisolated let currentLatencyMs = 650

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var isAvailable: Bool {
        get async {
            let hasKey = await KeychainManager.shared.hasAPIKey(for: .anthropic)
            let isOnline = await NetworkMonitor.shared.isOnline
            return hasKey && isOnline
        }
    }

    /// N1: a configured key is *unverified*, not available. This path performs no
    /// network probe (never on a hot path); a live probe is an explicit
    /// diagnostics/benchmark action.
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard await KeychainManager.shared.hasAPIKey(for: .anthropic) else {
            return .unavailable(reason: "no Anthropic API key configured")
        }
        guard await NetworkMonitor.shared.isOnline else {
            return .unavailable(reason: "offline")
        }
        return .unverified(reason: "Anthropic API key configured; live availability not verified")
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard await self.isAvailable else {
                    continuation.yield(.error("Claude provider is unavailable (offline or missing API key)"))
                    continuation.finish()
                    return
                }

                guard let apiKey = await KeychainManager.shared.getAPIKey(for: .anthropic) else {
                    continuation.yield(.error("Anthropic API key is missing from Keychain"))
                    continuation.finish()
                    return
                }

                let modelName = await Config.shared.modelName(for: "deep") ?? "claude-3-7-sonnet-20250219"

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                // Separate system prompt and chat messages
                var systemPrompt = ""
                var apiMessages: [[String: Any]] = []

                for msg in messages {
                    if msg.role == .system {
                        systemPrompt = msg.content
                    } else {
                        let role = msg.role == .assistant ? "assistant" : "user"
                        apiMessages.append(["role": role, "content": msg.content])
                    }
                }

                var body: [String: Any] = [
                    "model": modelName,
                    "max_tokens": 2048,
                    "stream": stream,
                    "messages": apiMessages
                ]
                if !systemPrompt.isEmpty {
                    body["system"] = systemPrompt
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        if status == 429 {
                            continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
                        } else {
                            continuation.yield(.error("Claude API error: \(errorMsg)"))
                        }
                        continuation.finish()
                        return
                    }

                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let content = json["content"] as? [[String: Any]],
                       let firstBlock = content.first,
                       let text = firstBlock["text"] as? String {
                        continuation.yield(.text(text))

                        let usageDict = json["usage"] as? [String: Any]
                        let inTokens = usageDict?["input_tokens"] as? Int ?? 0
                        let outTokens = usageDict?["output_tokens"] as? Int ?? 0
                        continuation.yield(.done(usage: TokenUsage(promptTokens: inTokens, completionTokens: outTokens, totalTokens: inTokens + outTokens)))
                    }

                    // Truthful quota intake: report only what the server's own headers
                    // expose. Absent headers leave the broker's view UNKNOWN (never inferred).
                    await ProviderQuotaSignal.report(response, for: self.id)

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
            message: available ? "Claude API ready" : "Key missing or offline"
        )
    }
}
