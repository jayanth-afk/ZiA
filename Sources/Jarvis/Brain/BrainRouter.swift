import Foundation

/// Master router connecting DeterministicRouter -> IntentClassifier -> Local / Cloud Providers.
/// Measures microsecond latency at every stage using PipelineTimer.
@MainActor
final class BrainRouter {
    static let shared = BrainRouter()

    private init() {}

    // MARK: - Public API

    /// Route a transcript through the JARVIS brain pipeline.
    func route(_ transcript: String) async throws -> String {
        let timer = PipelineTimer(id: UUID().uuidString)

        // Step 1: Deterministic router (0ms latency, zero LLM)
        timer.mark(.deterministicRouterStart)
        if let match = DeterministicRouter.shared.match(transcript) {
            timer.mark(.deterministicRouterHit)

            // Execute deterministic action (PermissionGate enforced inside
            // ActionEngine with the match's declared impact)
            let result = try await ActionEngine.shared.execute(
                intent: match.intent,
                isDeterministic: true,
                impact: match.impact,
                action: match.action
            )

            timer.mark(.responseDelivered)
            return result
        }

        timer.mark(.deterministicRouterMiss)

        // Step 2: Fast Intent Classification (~80ms Reflex model)
        timer.mark(.intentStart)
        let classification = try await IntentClassifier.shared.classify(transcript)
        timer.mark(.intentComplete)

        // Step 3: Provider Selection & Context Building
        timer.mark(.routerDecision)
        ConversationManager.shared.addUserMessage(transcript)
        let rawContext = ConversationManager.shared.getContext()
        let preparedContext = ContextBuilder.shared.buildContext(messages: rawContext)

        // Step 4: Provider Execution with automated Fallback Chain
        timer.mark(.providerStart)
        let fullResponse = try await ProviderManager.shared.executeWithFallback(
            messages: preparedContext,
            category: classification.category
        )

        ConversationManager.shared.addAssistantMessage(fullResponse)
        timer.mark(.responseDelivered)

        JarvisLogger.brain.info("BrainRouter completed query via \(classification.suggestedProvider): '\(fullResponse)'")
        return fullResponse
    }
}
