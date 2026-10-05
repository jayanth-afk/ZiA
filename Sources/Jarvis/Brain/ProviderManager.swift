import Foundation

/// Structured, observational health of one provider.
struct ProviderStatus: Sendable {
    let id: String
    let isAvailable: Bool
    let failureCount: Int
    let lastError: String?
    let capabilities: Set<Capability>
}

/// The intelligence router's decision for one request: which provider chain it
/// will try, which one it selected, and WHY — so a fallback is never silent.
struct RoutingDecision: Sendable, Equatable {
    let category: String
    let chain: [String]
    let chosen: String?
    let reason: String
    let degraded: Bool
}

/// Aggregate provider health used by HealthService and degraded-mode decisions.
struct ProviderHealthSummary: Sendable {
    let statuses: [ProviderStatus]
    let availableCount: Int
    let totalCount: Int
    let hasLocalFallback: Bool
    /// Providers currently quarantined (consecutive failures past threshold).
    let quarantined: [String]

    /// Degraded means no cloud provider is available but a local model is — Zia
    /// keeps working, with lower capability, and says so instead of failing.
    var isDegraded: Bool { availableCount > 0 && !statuses.contains { $0.isAvailable && !$0.id.hasPrefix("mlx") } }
    var isUnavailable: Bool { availableCount == 0 }
}

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

    /// Observational failure accounting. Never consulted for routing or
    /// authority; it exists so health/degraded-mode can explain WHY a provider
    /// was passed over (no silent fallbacks).
    private var failureCounts: [String: Int] = [:]
    private var lastErrors: [String: String] = [:]
    /// Circuit-breaker state: provider id -> time until which it is quarantined.
    private var quarantines: [String: Date] = [:]

    /// Consecutive failures before a provider is quarantined.
    static let quarantineFailureThreshold = 3
    /// How long a quarantined provider is skipped before being retried.
    static let quarantineCooldownSeconds: TimeInterval = 60

    private init() {}

    // MARK: - Circuit breaker

    /// Whether a provider is currently quarantined. Expired quarantines are
    /// cleared lazily so recovery needs no timer.
    func isQuarantined(_ providerID: String, now: Date = .now) -> Bool {
        guard let until = quarantines[providerID] else { return false }
        if until <= now {
            quarantines[providerID] = nil
            return false
        }
        return true
    }

    func quarantineReason(_ providerID: String) -> String? {
        guard let until = quarantines[providerID] else { return nil }
        let seconds = max(0, Int(until.timeIntervalSinceNow))
        return "quarantined for \(seconds)s after \(failureCounts[providerID] ?? 0) consecutive failures: \(lastErrors[providerID] ?? "unknown error")"
    }

    func clearQuarantine(_ providerID: String) {
        quarantines[providerID] = nil
    }

    func quarantinedProviderIDs(now: Date = .now) -> [String] {
        allProviders.map(\.id).filter { isQuarantined($0, now: now) }
    }

    // MARK: - Public API

    /// All registered providers in deterministic order.
    var allProviders: [any LLMProvider] {
        [claude, gemini, openai, groq, openrouter, localNormal, localReflex]
    }

    /// Record an observed provider failure. Trips the circuit breaker once the
    /// consecutive-failure threshold is reached. Returns the new failure count.
    @discardableResult
    func recordFailure(providerID: String, error: String, now: Date = .now) -> Int {
        let count = (failureCounts[providerID] ?? 0) + 1
        failureCounts[providerID] = count
        lastErrors[providerID] = error
        if count >= Self.quarantineFailureThreshold {
            quarantines[providerID] = now.addingTimeInterval(Self.quarantineCooldownSeconds)
            JarvisLogger.brain.warning("Provider \(providerID) quarantined after \(count) consecutive failures")
            EventBus.shared.publish(ProviderFailedEvent(
                provider: providerID, error: error, fallbackProvider: "quarantined"))
            NotificationPolicy.shared.providerDegraded(detail: "Provider \(providerID) quarantined after \(count) consecutive failures")
        }
        return count
    }

    func recordSuccess(providerID: String) {
        failureCounts[providerID] = 0
        lastErrors[providerID] = nil
        if quarantines[providerID] != nil {
            quarantines[providerID] = nil
            JarvisLogger.brain.info("Provider \(providerID) recovered and left quarantine")
        }
    }

    func failureCount(for providerID: String) -> Int { failureCounts[providerID] ?? 0 }
    func lastError(for providerID: String) -> String? { lastErrors[providerID] }

    /// Structured availability/health of every registered provider.
    func healthSnapshot() async -> ProviderHealthSummary {
        var statuses: [ProviderStatus] = []
        for provider in allProviders {
            let available = await provider.isAvailable
            statuses.append(ProviderStatus(
                id: provider.id,
                isAvailable: available,
                failureCount: failureCounts[provider.id] ?? 0,
                lastError: lastErrors[provider.id],
                capabilities: provider.capabilities))
        }
        let availableCount = statuses.filter(\.isAvailable).count
        let hasLocalFallback = statuses.contains { $0.id.hasPrefix("mlx") && $0.isAvailable }
        return ProviderHealthSummary(statuses: statuses, availableCount: availableCount,
                                     totalCount: statuses.count, hasLocalFallback: hasLocalFallback,
                                     quarantined: quarantinedProviderIDs())
    }

    /// Deterministic routing decision for an intent category. Considers both
    /// circuit-breaker state and live provider availability so the decision is
    /// itself truthful; execution does not silently reinterpret an unavailable
    /// provider as healthy.
    func routingDecision(for category: IntentClassifier.IntentCategory) async -> RoutingDecision {
        let chain = getFallbackChain(for: category)
        let chainIDs = chain.map(\.id)
        var skippedQuarantined: [String] = []
        var skippedUnavailable: [String] = []
        var chosen: (any LLMProvider)?

        for provider in chain {
            if isQuarantined(provider.id) {
                skippedQuarantined.append(provider.id)
                continue
            }
            if await !provider.isAvailable {
                skippedUnavailable.append(provider.id)
                continue
            }
            chosen = provider
            break
        }

        guard let chosen else {
            var reasons: [String] = []
            if !skippedQuarantined.isEmpty {
                reasons.append("quarantined: \(skippedQuarantined.joined(separator: ", "))")
            }
            if !skippedUnavailable.isEmpty {
                reasons.append("unavailable: \(skippedUnavailable.joined(separator: ", "))")
            }
            let detail = reasons.isEmpty ? "no providers configured" : reasons.joined(separator: "; ")
            return RoutingDecision(category: category.rawValue, chain: chainIDs, chosen: nil,
                                   reason: "no healthy provider for \(category.rawValue) (\(detail))",
                                   degraded: true)
        }

        let skipped = chainIDs.filter {
            $0 != chosen.id && (skippedQuarantined.contains($0) || skippedUnavailable.contains($0))
        }
        let degraded = chosen.id.hasPrefix("mlx") || !skipped.isEmpty
        let reason: String
        if skipped.isEmpty {
            reason = "first healthy provider for \(category.rawValue)"
        } else {
            reason = "selected \(chosen.id) for \(category.rawValue); skipped \(skipped.joined(separator: ", "))"
        }
        return RoutingDecision(category: category.rawValue, chain: chainIDs, chosen: chosen.id,
                               reason: reason, degraded: degraded)
    }

    /// Select the best available provider for an intent category and execute with fallback.
    func executeWithFallback(
        messages: [Message],
        category: IntentClassifier.IntentCategory
    ) async throws -> String {
        let decision = await routingDecision(for: category)
        JarvisLogger.brain.info("Routing decision: chosen=\(decision.chosen ?? "none"), reason=\(decision.reason), degraded=\(decision.degraded)")

        let chain = getFallbackChain(for: category)

        for provider in chain {
            // Circuit breaker: skip a quarantined provider and record WHY, so a
            // fallback is never silent. Quarantine never bypasses authority —
            // it only reorders intelligence sourcing.
            if isQuarantined(provider.id) {
                JarvisLogger.brain.warning("Skipping \(provider.id): \(self.quarantineReason(provider.id) ?? "quarantined")")
                continue
            }
            let available = await provider.isAvailable
            guard available else { continue }

            EventBus.shared.publish(ProviderSelectedEvent(
                provider: provider.id,
                reason: decision.chosen == provider.id ? decision.reason : "Fallback after prior provider failure for \(category.rawValue)"
            ))

            do {
                var responseText = ""
                // Data minimization: credentials are redacted and size is
                // bounded before text leaves the device for an external
                // provider. Local providers receive the context unmodified.
                let dispatchMessages = ContextSanitizer.sanitizedForDispatch(
                    messages, isLocal: provider.id.hasPrefix("mlx"))
                let stream = await provider.complete(messages: dispatchMessages, tools: nil, stream: false)

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

                if !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    recordSuccess(providerID: provider.id)
                    return responseText
                }

                // A silent successful transport is not a successful provider turn.
                // Count it so health, circuit-breaking, and audit state remain truthful.
                let emptyResponse = "provider returned an empty response"
                recordFailure(providerID: provider.id, error: emptyResponse)
                EventBus.shared.publish(ProviderFailedEvent(
                    provider: provider.id,
                    error: emptyResponse,
                    fallbackProvider: "next-in-chain"
                ))
            } catch {
                JarvisLogger.brain.warning("Provider \(provider.id) failed: \(error.localizedDescription)")
                recordFailure(providerID: provider.id, error: error.localizedDescription)
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
        let defaultChain: [any LLMProvider]
        switch category {
        case .coding:
            defaultChain = [claude, openai, openrouter, localNormal, localReflex]
        case .deepReasoning:
            defaultChain = [claude, gemini, openai, openrouter, localNormal, localReflex]
        case .webSearch:
            defaultChain = [groq, openrouter, gemini, localNormal, localReflex]
        case .conversation, .systemQuery:
            defaultChain = [localNormal, groq, openrouter, openai, localReflex]
        }

        let prefs = PreferenceStore.shared.current
        if prefs.localOnly {
            return [localNormal, localReflex]
        }
        if !prefs.preferredProviders.isEmpty {
            let preferred = defaultChain.filter { prefs.preferredProviders.contains($0.id) }
            let remaining = defaultChain.filter { !prefs.preferredProviders.contains($0.id) }
            return preferred + remaining
        }
        return defaultChain
    }
}
