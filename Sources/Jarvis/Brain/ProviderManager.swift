import Foundation

/// Structured, observational health of one provider.
struct ProviderStatus: Sendable {
    let id: String
    /// Usable for routing: verified-available OR configured-but-not-yet-probed.
    /// This is NOT the same as "verified" — see `availability`/`isVerified`.
    let isAvailable: Bool
    /// Truthful verified availability (N1). A configured API key is
    /// `.unverified(reason:)`, never `.available`.
    let availability: ProviderAvailability
    /// `true` only when the provider is verified-available right now.
    let isVerified: Bool
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
    /// ChatGPT transport the bridge reported for the chosen answer, when known.
    var transport: String? = nil
    /// Verified availability (N1) of the chosen provider, when known.
    var availability: String? = nil
    /// Why the ChatGPT deep tier was skipped for this request (never silent).
    var fallbackReason: String? = nil
}

/// Aggregate provider health used by HealthService and degraded-mode decisions.
struct ProviderHealthSummary: Sendable {
    let statuses: [ProviderStatus]
    /// Providers usable for routing (verified + configured-unprobed).
    let availableCount: Int
    /// Providers verified-available only (`availability == .available`). This is
    /// the honest "N are actually confirmed" number.
    let verifiedCount: Int
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
    let groqFast = GroqProvider(id: "groq", modelSlot: "fast")
    let groqStrong = GroqProvider(id: "groq-strong", modelSlot: "strong")
    let cerebras = CerebrasProvider()
    var groq: GroqProvider { groqFast }
    let openrouter = OpenRouterProvider()
    let chatgptDesktop = ChatGPTDesktopProvider()
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

    /// Fast availability caching to avoid redundant probes within the same turn/request.
    private var availabilityCache: [String: (available: Bool, timestamp: ContinuousClock.Instant)] = [:]
    private let availabilityCacheTTL: Duration = .seconds(2)

    /// Verified availability (N1): results of bounded probes, cached for ~10 min
    /// so probes never run on a request hot path.
    private var verifiedAvailabilityCache = ProviderAvailabilityCache()

    func isProviderAvailable(_ provider: any LLMProvider) async -> Bool {
        if let entry = availabilityCache[provider.id], entry.timestamp.duration(to: .now) < availabilityCacheTTL {
            return entry.available
        }
        let available = await provider.isAvailable
        availabilityCache[provider.id] = (available, .now)
        return available
    }

    func invalidateAvailability(for providerID: String) {
        availabilityCache[providerID] = nil
        verifiedAvailabilityCache.invalidate(providerID)
    }

    /// Truthful availability for reporting WITHOUT a network probe (the hot
    /// path). Uses a fresh cached probe when one exists; otherwise derives an
    /// honest non-network state — a configured key-based provider reports
    /// `.unverified`, never `.available`.
    func reportedAvailability(for provider: any LLMProvider) async -> ProviderAvailability {
        if let cached = verifiedAvailabilityCache.value(for: provider.id) { return cached }
        return await provider.verifiedAvailability(probe: false)
    }

    /// Run bounded availability probes for every provider and cache the results
    /// (TTL ~10 min). This is the ONLY path that may touch the network, so it is
    /// never called from a request hot path — only diagnostics/benchmark/health
    /// refresh opt in. Also folds in known-good state observed by real turns.
    @discardableResult
    func refreshVerifiedAvailability(now: Date = .now) async -> [String: ProviderAvailability] {
        var result: [String: ProviderAvailability] = [:]
        for provider in allProviders {
            // A provider that served a real turn is verified-available until the
            // next failure invalidates it; do not re-probe something already known-good.
            let availability: ProviderAvailability
            if let cached = verifiedAvailabilityCache.value(for: provider.id, now: now),
               cached.isAvailable {
                availability = cached
            } else {
                availability = await provider.verifiedAvailability(probe: true)
                verifiedAvailabilityCache.store(availability, for: provider.id, now: now)
            }
            result[provider.id] = availability
        }
        return result
    }

    /// All registered providers in deterministic order.
    var allProviders: [any LLMProvider] {
        [claude, gemini, openai, groqFast, groqStrong, openrouter, chatgptDesktop, localNormal, localReflex]
    }

    /// Record an observed provider failure. Trips the circuit breaker once the
    /// consecutive-failure threshold is reached. Returns the new failure count.
    @discardableResult
    func recordFailure(providerID: String, error: String, now: Date = .now) -> Int {
        invalidateAvailability(for: providerID)
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
        availabilityCache[providerID] = (true, .now)
        // A real completed turn is genuine verification of availability.
        verifiedAvailabilityCache.store(.available, for: providerID)
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
            let availability = await reportedAvailability(for: provider)
            statuses.append(ProviderStatus(
                id: provider.id,
                isAvailable: availability.isUsable,
                availability: availability,
                isVerified: availability.isAvailable,
                failureCount: failureCounts[provider.id] ?? 0,
                lastError: lastErrors[provider.id],
                capabilities: provider.capabilities))
        }
        let availableCount = statuses.filter(\.isAvailable).count
        let verifiedCount = statuses.filter(\.isVerified).count
        let hasLocalFallback = statuses.contains { $0.id.hasPrefix("mlx") && $0.isAvailable }
        return ProviderHealthSummary(statuses: statuses, availableCount: availableCount,
                                     verifiedCount: verifiedCount,
                                     totalCount: statuses.count, hasLocalFallback: hasLocalFallback,
                                     quarantined: quarantinedProviderIDs())
    }

    /// Deterministic routing decision for an intent category. Considers both
    /// circuit-breaker state and live provider availability so the decision is
    /// itself truthful; execution does not silently reinterpret an unavailable
    /// provider as healthy.
    func routingDecision(for category: IntentClassifier.IntentCategory) async -> RoutingDecision {
        await routingDecision(for: category, context: nil)
    }

    /// Deterministic routing decision with the hybrid ChatGPT policy applied when
    /// a request context is supplied. The ChatGPT deep tier is skipped (with a
    /// recorded reason) unless every policy rule passes.
    func routingDecision(
        for category: IntentClassifier.IntentCategory,
        context: ChatGPTRequestContext?
    ) async -> RoutingDecision {
        let chain = getFallbackChain(for: category)
        let chainIDs = chain.map(\.id)
        var skippedQuarantined: [String] = []
        var skippedUnavailable: [String] = []
        var skippedPolicy: [String] = []
        var chatgptFallbackReason: String?
        var chosen: (any LLMProvider)?
        var chosenAvailability: ProviderAvailability?

        for provider in chain {
            if isQuarantined(provider.id) {
                skippedQuarantined.append(provider.id)
                continue
            }
            if let context, HybridRoutingPolicy.isEnabled, provider.id == "chatgpt-desktop" {
                let availability = await reportedAvailability(for: provider)
                let decision = ChatGPTBrainPolicy.evaluate(
                    context, availability: availability,
                    isQuarantined: false,
                    dailyCapReached: ChatGPTBrain.isDailyCapReached())
                if !decision.isEligible {
                    chatgptFallbackReason = decision.reason
                    skippedPolicy.append(provider.id)
                    continue
                }
            }
            if await !isProviderAvailable(provider) {
                skippedUnavailable.append(provider.id)
                continue
            }
            chosen = provider
            chosenAvailability = await reportedAvailability(for: provider)
            break
        }

        guard let chosen else {
            var reasons: [String] = []
            if !skippedPolicy.isEmpty {
                reasons.append("policy: \(chatgptFallbackReason ?? skippedPolicy.joined(separator: ", "))")
            }
            if !skippedQuarantined.isEmpty {
                reasons.append("quarantined: \(skippedQuarantined.joined(separator: ", "))")
            }
            if !skippedUnavailable.isEmpty {
                reasons.append("unavailable: \(skippedUnavailable.joined(separator: ", "))")
            }
            let detail = reasons.isEmpty ? "no providers configured" : reasons.joined(separator: "; ")
            return RoutingDecision(category: category.rawValue, chain: chainIDs, chosen: nil,
                                   reason: "no healthy provider for \(category.rawValue) (\(detail))",
                                   degraded: true, fallbackReason: chatgptFallbackReason)
        }

        let skipped = chainIDs.filter {
            $0 != chosen.id && (skippedQuarantined.contains($0) || skippedUnavailable.contains($0)
                                || skippedPolicy.contains($0))
        }
        let degraded = chosen.id.hasPrefix("mlx") || !skipped.isEmpty
        let reason: String
        if skipped.isEmpty {
            reason = "first healthy provider for \(category.rawValue)"
        } else {
            reason = "selected \(chosen.id) for \(category.rawValue); skipped \(skipped.joined(separator: ", "))"
        }
        return RoutingDecision(category: category.rawValue, chain: chainIDs, chosen: chosen.id,
                               reason: reason, degraded: degraded,
                               availability: chosenAvailability?.label,
                               fallbackReason: chatgptFallbackReason)
    }

    /// Select the best available provider for an intent category and execute with fallback.
    func executeWithFallback(
        messages: [Message],
        category: IntentClassifier.IntentCategory
    ) async throws -> String {
        try await executeWithStreamingFallback(messages: messages, category: category, onChunk: nil)
    }

    /// Execute with fallback, applying the hybrid ChatGPT policy when a request
    /// context is supplied.

    /// Select the best available provider for an intent category and execute with streaming fallback.
    /// Delivers real-time incremental tokens to `onChunk` as they arrive from the active provider.
    func executeWithStreamingFallback(
        messages: [Message],
        category: IntentClassifier.IntentCategory,
        context: ChatGPTRequestContext? = nil,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let decision = await routingDecision(for: category, context: context)
        JarvisLogger.brain.info("Routing decision: chosen=\(decision.chosen ?? "none"), reason=\(decision.reason), degraded=\(decision.degraded)")
        if let fallbackReason = decision.fallbackReason {
            JarvisLogger.brain.info("ChatGPT deep tier skipped: \(fallbackReason)")
        }

        let chain = getFallbackChain(for: category)

        for provider in chain {
            // Circuit breaker: skip a quarantined provider and record WHY, so a
            // fallback is never silent. Quarantine never bypasses authority —
            // it only reorders intelligence sourcing.
            if isQuarantined(provider.id) {
                JarvisLogger.brain.warning("Skipping \(provider.id): \(self.quarantineReason(provider.id) ?? "quarantined")")
                continue
            }
            // Hybrid policy: the ChatGPT deep tier must earn every eligible rule.
            if let context, HybridRoutingPolicy.isEnabled, provider.id == "chatgpt-desktop" {
                let availability = await reportedAvailability(for: provider)
                let policy = ChatGPTBrainPolicy.evaluate(
                    context, availability: availability,
                    isQuarantined: false,
                    dailyCapReached: ChatGPTBrain.isDailyCapReached())
                if !policy.isEligible {
                    JarvisLogger.brain.info("Skipping ChatGPT brain: \(policy.reason ?? "ineligible")")
                    continue
                }
            }
            let available = await isProviderAvailable(provider)
            guard available else { continue }

            EventBus.shared.publish(ProviderSelectedEvent(
                provider: provider.id,
                reason: decision.chosen == provider.id ? decision.reason : "Fallback after prior provider failure for \(category.rawValue)"
            ))

            let callStart = ContinuousClock.now
            do {
                var responseText = ""
                // Data minimization: credentials are redacted and size is
                // bounded before text leaves the device for an external
                // provider. Local providers receive the context unmodified.
                let dispatchMessages = ContextSanitizer.sanitizedForDispatch(
                    messages, isLocal: provider.id.hasPrefix("mlx"))
                let stream = await provider.complete(messages: dispatchMessages, tools: nil, stream: onChunk != nil)

                for try await chunk in stream {
                    switch chunk {
                    case .text(let text):
                        responseText += text
                        onChunk?(text)
                    case .error(let errorMsg):
                        throw JarvisError.providerError(provider: provider.id, message: errorMsg)
                    default:
                        break
                    }
                }

                let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let elapsed = callStart.duration(to: .now)
                    let ms = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
                    JarvisLogger.brain.info("Provider \(provider.id) completed in \(Int(ms))ms")
                    recordSuccess(providerID: provider.id)
                    // User-visible provenance: which brain actually answered.
                    if provider.id == "chatgpt-desktop" {
                        let transport = await self.chatgptDesktop.lastTransport()
                        ChatGPTBrainProvenance.shared.recordChatGPT(transport: transport)
                    } else {
                        ChatGPTBrainProvenance.shared.clear()
                    }
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

        // Truthful reporting: every provider in the ladder was unavailable or failed
        throw JarvisError.providerError(
            provider: "fallback-exhausted",
            message: "All providers failed to respond for \(category.rawValue)."
        )
    }

    /// Select the best available provider for a specific BrainTier and execute with streaming fallback.
    /// Returns the verified response and the provider ID that actually succeeded.
    func executeWithStreamingFallback(
        messages: [Message],
        tier: BrainTier,
        context: ChatGPTRequestContext? = nil,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> (response: String, providerID: String) {
        let chain = getFallbackChain(for: tier)

        for provider in chain {
            if isQuarantined(provider.id) {
                JarvisLogger.brain.warning("Skipping \(provider.id): \(self.quarantineReason(provider.id) ?? "quarantined")")
                continue
            }
            if let context, HybridRoutingPolicy.isEnabled, provider.id == "chatgpt-desktop" {
                let availability = await reportedAvailability(for: provider)
                let policy = ChatGPTBrainPolicy.evaluate(
                    context, availability: availability,
                    isQuarantined: false,
                    dailyCapReached: ChatGPTBrain.isDailyCapReached())
                if !policy.isEligible {
                    JarvisLogger.brain.info("Skipping ChatGPT brain: \(policy.reason ?? "ineligible")")
                    continue
                }
            }
            let available = await isProviderAvailable(provider)
            guard available else { continue }

            EventBus.shared.publish(ProviderSelectedEvent(
                provider: provider.id,
                reason: "Direct routing execution for tier \(tier.rawValue)"
            ))

            let callStart = ContinuousClock.now
            do {
                var responseText = ""
                let dispatchMessages = ContextSanitizer.sanitizedForDispatch(
                    messages, isLocal: provider.id.hasPrefix("mlx"))
                let stream = await provider.complete(messages: dispatchMessages, tools: nil, stream: onChunk != nil)

                for try await chunk in stream {
                    switch chunk {
                    case .text(let text):
                        responseText += text
                        onChunk?(text)
                    case .error(let errorMsg):
                        throw JarvisError.providerError(provider: provider.id, message: errorMsg)
                    default:
                        break
                    }
                }

                let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let elapsed = callStart.duration(to: .now)
                    let ms = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
                    JarvisLogger.brain.info("Provider \(provider.id) completed tier [\(tier.rawValue)] in \(Int(ms))ms")
                    recordSuccess(providerID: provider.id)
                    if provider.id == "chatgpt-desktop" {
                        let transport = await self.chatgptDesktop.lastTransport()
                        ChatGPTBrainProvenance.shared.recordChatGPT(transport: transport)
                    } else {
                        ChatGPTBrainProvenance.shared.clear()
                    }
                    return (responseText, provider.id)
                }

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

        throw JarvisError.providerError(
            provider: "fallback-exhausted",
            message: "All providers failed to respond for tier \(tier.rawValue)."
        )
    }

    /// Determines the fallback cascade for a given intent category.
    func getFallbackChain(for category: IntentClassifier.IntentCategory) -> [any LLMProvider] {
        let defaultChain: [any LLMProvider]
        switch category {
        case .coding:
            defaultChain = [chatgptDesktop, groqStrong, claude, openai, openrouter, localNormal, localReflex]
        case .deepReasoning:
            defaultChain = [chatgptDesktop, groqStrong, claude, gemini, openai, openrouter, localNormal, localReflex]
        case .webSearch:
            defaultChain = [chatgptDesktop, groqFast, groqStrong, openrouter, gemini, localNormal, localReflex]
        case .conversation, .systemQuery:
            defaultChain = [chatgptDesktop, groqFast, groqStrong, claude, gemini, openai, openrouter, localNormal, localReflex]
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

    /// Determines the fallback cascade for a specific target BrainTier.
    func getFallbackChain(for tier: BrainTier) -> [any LLMProvider] {
        let prefs = PreferenceStore.shared.current
        if prefs.localOnly {
            return [localNormal, localReflex]
        }

        let defaultChain: [any LLMProvider]
        switch tier {
        case .reflex:
            return []
        case .fast:
            defaultChain = [groqFast, groqStrong, localNormal, localReflex]
        case .strong:
            defaultChain = [groqStrong, chatgptDesktop, claude, openai, openrouter, localNormal, localReflex]
        case .deep:
            defaultChain = [chatgptDesktop, groqStrong, claude, gemini, openai, openrouter, localNormal, localReflex]
        case .localFallback:
            defaultChain = [localNormal, localReflex]
        }

        if !prefs.preferredProviders.isEmpty {
            let preferred = defaultChain.filter { prefs.preferredProviders.contains($0.id) }
            let remaining = defaultChain.filter { !prefs.preferredProviders.contains($0.id) }
            return preferred + remaining
        }
        return defaultChain
    }
}
