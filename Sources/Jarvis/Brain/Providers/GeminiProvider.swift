import Foundation

/// Google Gemini provider for fast reasoning, massive context, and vision understanding.
actor GeminiProvider: LLMProvider {
    nonisolated let id = "gemini"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling,
        .vision,
        .longContext,
        .structuredOutput
    ]
    nonisolated let currentLatencyMs = 380

    var isAvailable: Bool {
        get async {
            let hasKey = await KeychainManager.shared.hasAPIKey(for: .google)
            let isOnline = await NetworkMonitor.shared.isOnline
            return hasKey && isOnline
        }
    }

    /// N1: a configured key is *unverified*, not available (no network on this path).
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard await KeychainManager.shared.hasAPIKey(for: .google) else {
            return .unavailable(reason: "no Google AI API key configured")
        }
        guard await NetworkMonitor.shared.isOnline else {
            return .unavailable(reason: "offline")
        }
        return .unverified(reason: "Google AI API key configured; live availability not verified")
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard await self.isAvailable else {
                    continuation.yield(.error("Gemini provider is unavailable (offline or missing API key)"))
                    continuation.finish()
                    return
                }

                guard let apiKey = await KeychainManager.shared.getAPIKey(for: .google) else {
                    continuation.yield(.error("Gemini API key is missing from Keychain"))
                    continuation.finish()
                    return
                }

                let modelName = await Config.shared.modelName(for: "vision") ?? "gemini-2.5-flash"
                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
                    continuation.yield(.error("Invalid Gemini API URL"))
                    continuation.finish()
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var contents: [[String: Any]] = []
                for msg in messages {
                    if msg.role == .system { continue }
                    let role = msg.role == .assistant ? "model" : "user"
                    contents.append([
                        "role": role,
                        "parts": [["text": msg.content]]
                    ])
                }

                let body: [String: Any] = ["contents": contents]

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        if status == 429 {
                            continuation.yield(.rateLimited(retryAfter: ProviderRateLimit.retryAfter(from: response as? HTTPURLResponse)))
                        } else {
                            continuation.yield(.error("Gemini API error: \(errorMsg)"))
                        }
                        continuation.finish()
                        return
                    }

                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let firstCandidate = candidates.first,
                       let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let firstPart = parts.first,
                       let text = firstPart["text"] as? String {
                        continuation.yield(.text(text))

                        let usageDict = json["usageMetadata"] as? [String: Any]
                        let inTokens = usageDict?["promptTokenCount"] as? Int ?? 0
                        let outTokens = usageDict?["candidatesTokenCount"] as? Int ?? 0
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
            message: available ? "Gemini API ready" : "Key missing or offline"
        )
    }
}
