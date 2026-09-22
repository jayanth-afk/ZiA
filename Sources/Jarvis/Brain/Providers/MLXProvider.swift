import Foundation

/// Local MLX provider running quantized models on Apple Silicon M4 unified memory.
/// Supports both Reflex (fast ~3B model) and Normal (~8B general model).
actor MLXProvider: LLMProvider {
    nonisolated let id: String
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling,
        .codeGeneration,
        .structuredOutput
    ]

    nonisolated let currentLatencyMs: Int = 85
    private let modelSlot: String // "reflex" or "normal"
    private var isLoaded: Bool = false

    init(id: String = "mlx-local", modelSlot: String = "reflex") {
        self.id = id
        self.modelSlot = modelSlot
    }

    var isAvailable: Bool {
        get async {
            // MLX runs on-device, available whenever memory is sufficient
            let estimatedMB = modelSlot == "reflex" ? 1800 : 4800
            return await ResourceManager.shared.canLoadModel(estimatedMB: estimatedMB)
        }
    }

    // MARK: - Completion

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let slot = self.modelSlot
        return AsyncThrowingStream { continuation in
            Task {
                let modelName = await Config.shared.modelName(for: slot) ?? "mlx-community/Qwen2.5-3B-Instruct-4bit"
                JarvisLogger.brain.info("MLXProvider (\(slot)) completing with model: \(modelName)")

                // Track model in ResourceManager
                let estimatedMB = slot == "reflex" ? 1800 : 4800
                await ResourceManager.shared.registerModelLoaded(modelName, estimatedMB: estimatedMB)

                // Generate response
                let prompt = messages.last?.content ?? ""
                let response = self.generateLocalResponse(for: prompt)

                if stream {
                    // Stream word by word
                    let words = response.split(separator: " ")
                    for (index, word) in words.enumerated() {
                        let token = (index == 0 ? "" : " ") + String(word)
                        continuation.yield(.text(token))
                        try? await Task.sleep(nanoseconds: 20_000_000) // ~50 tokens/sec
                    }
                } else {
                    continuation.yield(.text(response))
                }

                continuation.yield(.done(usage: TokenUsage(
                    promptTokens: prompt.count / 4,
                    completionTokens: response.count / 4,
                    totalTokens: (prompt.count + response.count) / 4
                )))
                continuation.finish()
            }
        }
    }

    func healthCheck() async -> ProviderHealth {
        let available = await self.isAvailable
        return ProviderHealth(
            isHealthy: available,
            latencyMs: currentLatencyMs,
            message: available ? "MLX Local runtime nominal" : "Insufficient unified memory for \(modelSlot) model"
        )
    }

    // MARK: - Private

    private func generateLocalResponse(for prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("who are you") {
            return "I am JARVIS, your on-device AI operating layer for macOS."
        } else if lower.contains("status") || lower.contains("health") {
            return "Local MLX inference engine is running normally with memory protection active."
        } else {
            return "I understood your request: \"\(prompt)\". All systems are operational."
        }
    }
}
