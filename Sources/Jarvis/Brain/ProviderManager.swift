import Foundation

/// Registry, health supervisor, and fallback router for all AI providers.
/// Rule 10: Zero-API-key local execution always guaranteed via MLX fallback.
@MainActor
final class ProviderManager {
    static let shared = ProviderManager()

    // Registered providers
    let claude = ClaudeProvider()
    let gemini = GeminiProvider()
    let openai = OpenAIProvider()
    let groq = GroqProvider()
    let openrouter = OpenRouterProvider()
    let localNormal = MLXProvider(id: "mlx-normal", modelSlot: "normal")
    let localReflex = MLXProvider(id: "mlx-reflex", modelSlot: "reflex")

    private init() {}

    // MARK: - Public API

    /// Select the best available provider for an intent category and execute with fallback.
    func executeWithFallback(
        messages: [Message],
        category: IntentClassifier.IntentCategory
    ) async throws -> String {
        let chain = getFallbackChain(for: category)

        for provider in chain {
            let available = await provider.isAvailable
            guard available else { continue }

            EventBus.shared.publish(ProviderSelectedEvent(
                provider: provider.id,
                reason: "Matched for \(category.rawValue)"
            ))

            do {
                var responseText = ""
                let stream = await provider.complete(messages: messages, tools: nil, stream: false)

                for try await chunk in stream {
                    switch chunk {
                    case .text(let text):
                        responseText += text
                    case .error(let errorMsg):
                        throw JarvisError.providerError(provider: provider.id, message: errorMsg)
                    default:
                        break
                    }
                }

                if !responseText.isEmpty {
                    return responseText
                }
            } catch {
                JarvisLogger.brain.warning("Provider \(provider.id) failed: \(error.localizedDescription)")
                EventBus.shared.publish(ProviderFailedEvent(
                    provider: provider.id,
                    error: error.localizedDescription,
                    fallbackProvider: "next-in-chain"
                ))
            }
        }

        // Final local fallback
        let fallbackStream = await localNormal.complete(messages: messages, tools: nil, stream: false)
        var fallbackResponse = ""
        for try await chunk in fallbackStream {
            if case .text(let t) = chunk { fallbackResponse += t }
        }

        return fallbackResponse.isEmpty ? "All providers failed to respond." : fallbackResponse
    }

    /// Determines the fallback cascade for a given intent category.
    func getFallbackChain(for category: IntentClassifier.IntentCategory) -> [any LLMProvider] {
        switch category {
        case .coding:
            return [claude, openai, openrouter, localNormal, localReflex]
        case .deepReasoning:
            return [claude, gemini, openai, openrouter, localNormal, localReflex]
        case .webSearch:
            return [groq, openrouter, gemini, localNormal, localReflex]
        case .conversation, .systemQuery:
            return [localNormal, groq, openrouter, openai, localReflex]
        }
    }
}
