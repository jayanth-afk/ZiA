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
    /// Consecutive failures since the last success (drives the circuit breaker).
    let failureCount: Int
    let lastError: String?
    let capabilities: Set<Capability>

    // MARK: Operational health (observational only, never routing authority)

    /// Total successful turns observed for this provider.
    let successCount: Int
    /// Last time a turn actually completed.
    let lastSuccessAt: Date?
    /// Last time a turn failed.
    let lastFailureAt: Date?
    /// Latency of the most recent successful turn, in milliseconds.
    let lastLatencyMs: Int?
    /// When a rate-limit cooldown expires, if the provider is currently throttled.
    let rateLimitedUntil: Date?

    /// Whether this provider is cooling down after a rate limit right now.
    var isRateLimited: Bool { rateLimitedUntil != nil }
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
    /// Providers currently cooling down after a rate limit (temporary).
    let rateLimited: [String]

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
    let sambanova = SambaNovaProvider()
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
    /// Rate-limit cooldown state: provider id -> time until it is throttled.
    /// Deliberately separate from `quarantines`: a throttle is temporary and must
    /// never be treated as a proven failure.
    private var rateLimitCooldowns: [String: Date] = [:]
    /// Operational health accounting (observational only). Populated from real
    /// turns so health can explain outcomes without becoming a telemetry store.
    private var successCounts: [String: Int] = [:]
    private var lastSuccessTimes: [String: Date] = [:]
    private var lastFailureTimes: [String: Date] = [:]
    private var lastLatencies: [String: Int] = [:]

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

    // MARK: - Rate limiting

    /// Record a provider rate limit. This is a *temporary* condition: it sets a
    /// cooldown for exactly the server-requested duration and does NOT count
    /// toward the consecutive-failure quarantine — a healthy provider must not be
    /// punished for a momentary throttle. Returns the cooldown applied, seconds.
    @discardableResult
    func recordRateLimit(providerID: String, retryAfter: TimeInterval?, now: Date = .now) -> TimeInterval {
        let cooldown = ProviderRateLimit.cooldown(for: retryAfter)
        rateLimitCooldowns[providerID] = now.addingTimeInterval(cooldown)
        JarvisLogger.brain.warning(
            "Provider \(providerID) rate-limited; cooling down \(Int(cooldown))s (retryAfter=\(retryAfter.map { String(Int($0)) } ?? "none"))")
        return cooldown
    }

    /// Whether a provider is cooling down after a rate limit. Expired cooldowns
    /// are cleared lazily so recovery needs no timer.
    func isRateLimited(_ providerID: String, now: Date = .now) -> Bool {
        guard let until = rateLimitCooldowns[providerID] else { return false }
        if until <= now {
            rateLimitCooldowns[providerID] = nil
            return false
        }
        return true
    }

    func rateLimitReason(_ providerID: String) -> String? {
        guard let until = rateLimitCooldowns[providerID] else { return nil }
        return "rate-limited for \(max(0, Int(until.timeIntervalSinceNow)))s"
    }

    func clearRateLimit(_ providerID: String) { rateLimitCooldowns[providerID] = nil }

    func rateLimitedProviderIDs(now: Date = .now) -> [String] {
        allProviders.map(\.id).filter { isRateLimited($0, now: now) }
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
        [claude, gemini, openai, groqFast, groqStrong, cerebras, sambanova, openrouter, chatgptDesktop, localNormal, localReflex]
    }

    /// Record an observed provider failure. Trips the circuit breaker once the
    /// consecutive-failure threshold is reached. Returns the new failure count.
    @discardableResult
    func recordFailure(providerID: String, error: String, now: Date = .now) -> Int {
        invalidateAvailability(for: providerID)
        let count = (failureCounts[providerID] ?? 0) + 1
        failureCounts[providerID] = count
        lastErrors[providerID] = error
        lastFailureTimes[providerID] = now
        if count >= Self.quarantineFailureThreshold {
            quarantines[providerID] = now.addingTimeInterval(Self.quarantineCooldownSeconds)
            JarvisLogger.brain.warning("Provider \(providerID) quarantined after \(count) consecutive failures")
            EventBus.shared.publish(ProviderFailedEvent(
                provider: providerID, error: error, fallbackProvider: "quarantined"))
            NotificationPolicy.shared.providerDegraded(detail: "Provider \(providerID) quarantined after \(count) consecutive failures")
        }
        return count
    }

    func recordSuccess(providerID: String, latencyMs: Int? = nil) {
        availabilityCache[providerID] = (true, .now)
        // A real completed turn is genuine verification of availability.
        verifiedAvailabilityCache.store(.available, for: providerID)
        failureCounts[providerID] = 0
        lastErrors[providerID] = nil
        successCounts[providerID, default: 0] += 1
        lastSuccessTimes[providerID] = .now
        if let latencyMs { lastLatencies[providerID] = latencyMs }
        // A successful turn proves the throttle cleared early.
        rateLimitCooldowns[providerID] = nil
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
                capabilities: provider.capabilities,
                successCount: successCounts[provider.id] ?? 0,
                lastSuccessAt: lastSuccessTimes[provider.id],
                lastFailureAt: lastFailureTimes[provider.id],
                lastLatencyMs: lastLatencies[provider.id],
                rateLimitedUntil: rateLimitCooldowns[provider.id]))
        }
        let availableCount = statuses.filter(\.isAvailable).count
        let verifiedCount = statuses.filter(\.isVerified).count
        let hasLocalFallback = statuses.contains { $0.id.hasPrefix("mlx") && $0.isAvailable }
        return ProviderHealthSummary(statuses: statuses, availableCount: availableCount,
                                     verifiedCount: verifiedCount,
                                     totalCount: statuses.count, hasLocalFallback: hasLocalFallback,
                                     quarantined: quarantinedProviderIDs(),
                                     rateLimited: rateLimitedProviderIDs())
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
        var skippedRateLimited: [String] = []
        var skippedBudget: [String] = []
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
            if isRateLimited(provider.id) {
                skippedRateLimited.append(provider.id)
                continue
            }
            if !BudgetPolicy.shared.eligibility(forProviderID: provider.id).isAllowed {
                skippedBudget.append(provider.id)
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
            if !skippedRateLimited.isEmpty {
                reasons.append("rate-limited: \(skippedRateLimited.joined(separator: ", "))")
            }
            if !skippedBudget.isEmpty {
                reasons.append("budget: \(skippedBudget.joined(separator: ", "))")
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
            $0 != chosen.id && (skippedQuarantined.contains($0) || skippedRateLimited.contains($0)
                                || skippedBudget.contains($0)
                                || skippedUnavailable.contains($0) || skippedPolicy.contains($0))
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
        let result = try await executeFallbackChain(
            getFallbackChain(for: category),
            messages: messages,
            context: context,
            onChunk: onChunk,
            label: "category \(category.rawValue)",
            requirements: requirements(for: category))
        return result.response
    }

    /// Select the best available provider for a specific BrainTier and execute with streaming fallback.
    /// Returns the verified response and the provider ID that actually succeeded.
    func executeWithStreamingFallback(
        messages: [Message],
        tier: BrainTier,
        context: ChatGPTRequestContext? = nil,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> (response: String, providerID: String) {
        try await executeFallbackChain(
            getFallbackChain(for: tier),
            messages: messages,
            context: context,
            onChunk: onChunk,
            label: "tier \(tier.rawValue)",
            requirements: requirements(for: tier))
    }

    // MARK: - Capability-aware selection (§6)

    /// Static registry descriptor for every registered worker, in fleet order.
    var providerDescriptors: [ProviderDescriptor] {
        allProviders.map { ProviderDescriptor.default(for: $0.id) }
    }

    /// Requirements implied by a brain tier. This is the bridge between the
    /// existing tier decision (BrainRouter) and the suitability scorer.
    func requirements(for tier: BrainTier) -> TaskRequirements {
        switch tier {
        case .reflex:
            return TaskRequirements(complexity: .trivial)
        case .fast:
            return TaskRequirements(complexity: .standard)
        case .strong:
            return TaskRequirements(complexity: .complex)
        case .deep:
            return TaskRequirements(complexity: .deep)
        case .localFallback:
            return TaskRequirements(complexity: .standard, privacy: .localOnly)
        }
    }

    /// Requirements implied by an intent category.
    func requirements(for category: IntentClassifier.IntentCategory) -> TaskRequirements {
        switch category {
        case .coding:
            return TaskRequirements(complexity: .complex)
        case .deepReasoning:
            return TaskRequirements(complexity: .deep)
        case .webSearch, .conversation, .systemQuery:
            return TaskRequirements(complexity: .standard)
        }
    }

    /// Capability-aware ranking of a fallback chain. Returns the workers that
    /// are *eligible* under the requirements, ordered by suitability (best
    /// first). If nothing is eligible the baseline chain is returned unchanged
    /// so policy denials still surface their real reason downstream.
    func rankProviders(for chain: [any LLMProvider],
                       requirements: TaskRequirements,
                       broker: ProviderResourceBroker = .shared) async -> [any LLMProvider] {
        let snapshot = await broker.snapshot()
        var contexts: [String: ProviderScoreContext] = [:]
        for provider in chain {
            var context = ProviderScoreContext()
            context.isUnhealthy = isQuarantined(provider.id) || isRateLimited(provider.id)
            if let state = snapshot.provider(provider.id) {
                context.inFlight = state.inFlight
                context.maxConcurrent = state.maxConcurrent
                context.requestsRemaining = state.observedRequestsRemaining
                context.tokensRemaining = state.observedTokensRemaining
            }
            contexts[provider.id] = context
        }
        let descriptors = chain.map { ProviderDescriptor.default(for: $0.id) }
        let ranked = ProviderSuitabilityScorer.rank(descriptors, requirements: requirements, contexts: contexts)
        for verdict in ranked where !verdict.isEligible {
            JarvisLogger.brain.info("Suitability: \(verdict.explanation)")
        }
        let eligibleIDs = ranked.filter(\.isEligible).map(\.providerID)
        let eligible = eligibleIDs.compactMap { id in chain.first { $0.id == id } }
        guard !eligible.isEmpty else {
            JarvisLogger.brain.info("Capability ranking found no eligible worker; using baseline chain")
            return chain
        }
        if let best = eligible.first {
            JarvisLogger.brain.info("Capability ranking selected \(best.id) for \(requirements.complexity.rawValue) task")
        }
        return eligible
    }

    /// Core fallback executor shared by the category and tier entry points.
    ///
    /// Applies, in order: quarantine, rate-limit cooling, budget eligibility (a
    /// `paid` provider is skipped unless spending is authorised), the hybrid
    /// ChatGPT policy, and availability — then records usage and returns the
    /// first provider that produced non-empty output.
    ///
    /// Internal (not private) so tests can inject fake providers and verify the
    /// fallback and streaming-commitment invariants deterministically.
    func executeFallbackChain(
        _ chain: [any LLMProvider],
        messages: [Message],
        context: ChatGPTRequestContext? = nil,
        onChunk: (@Sendable (String) -> Void)? = nil,
        label: String = "chain",
        priority: Int = TaskPriority.interactive,
        broker: ProviderResourceBroker = .shared,
        requirements: TaskRequirements? = nil
    ) async throws -> (response: String, providerID: String) {
        let estimatedTokens = Self.estimatedTokens(for: messages)
        // Capability-aware ordering: eligibility (capability/privacy/context/
        // quota/health) and suitability (strength/latency/cost/capacity). When
        // no requirements are supplied the caller's order is used verbatim.
        var orderedChain = chain
        if let requirements {
            orderedChain = await rankProviders(for: chain, requirements: requirements, broker: broker)
        }
        for provider in orderedChain {
            if isQuarantined(provider.id) {
                JarvisLogger.brain.warning("Skipping \(provider.id): \(self.quarantineReason(provider.id) ?? "quarantined")")
                continue
            }
            if isRateLimited(provider.id) {
                JarvisLogger.brain.warning("Skipping \(provider.id): \(self.rateLimitReason(provider.id) ?? "rate-limited")")
                continue
            }
            let budget = BudgetPolicy.shared.eligibility(forProviderID: provider.id)
            if !budget.isAllowed {
                JarvisLogger.brain.info("Skipping \(provider.id): \(budget.reason ?? "budget blocked")")
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
            guard await isProviderAvailable(provider) else { continue }

            // Resource arbitration (§1/§2): the scheduler must never dispatch
            // cloud work blind. Acquire a bounded, priority-aware reservation
            // BEFORE any request leaves the process. A denied admission
            // (budget/window/queue-full) reroutes to the next eligible worker
            // instead of silently exceeding a limit.
            let request = ProviderResourceRequest(
                providerID: provider.id,
                priority: priority,
                estimatedTokens: estimatedTokens,
                estimatedCostUSD: 0,
                spentTodayUSD: UsageManager.shared.dailySpentUSD,
                dailyLimitUSD: Config.shared.dailyBudgetUSD)
            let reservation: ProviderReservation
            do {
                reservation = try await broker.acquire(request)
            } catch {
                // Cancellation is terminal — never a reason to try another worker.
                if Task.isCancelled { throw CancellationError() }
                JarvisLogger.brain.info("Resource broker deferred \(provider.id): \(error.localizedDescription)")
                continue
            }
            // State can change while waiting for a slot: never hold capacity
            // for a worker that has since been quarantined or throttled.
            if isQuarantined(provider.id) || isRateLimited(provider.id) {
                await broker.release(reservation)
                continue
            }

            do {
                let outcome = try await attemptProvider(
                    provider, messages: messages, context: context, onChunk: onChunk, label: label)
                await broker.release(reservation)
                if let outcome { return outcome }
                // nil → the worker produced nothing usable; try the next one.
            } catch {
                await broker.release(reservation)
                throw error
            }
        }

        throw JarvisError.providerError(
            provider: "fallback-exhausted",
            message: "All providers failed to respond for \(label)."
        )
    }

    /// Run one provider attempt under an already-granted reservation.
    ///
    /// Returns the committed answer, or nil when the worker produced nothing
    /// usable (the caller should try the next worker). Throws only when the turn
    /// must end — notably a mid-stream failure AFTER visible output, where
    /// switching workers would concatenate two answers (partial-stream safety).
    private func attemptProvider(
        _ provider: any LLMProvider,
        messages: [Message],
        context: ChatGPTRequestContext?,
        onChunk: (@Sendable (String) -> Void)?,
        label: String
    ) async throws -> (response: String, providerID: String)? {
        try Task.checkCancellation()
        EventBus.shared.publish(ProviderSelectedEvent(
            provider: provider.id,
            reason: "Executing \(label) with \(provider.id)"))

        let callStart = ContinuousClock.now
        // Streaming commitment: once any of this worker's text has reached the
        // caller, switching workers would concatenate two answers.
        var emittedVisibleText = false
        do {
            var responseText = ""
            var usage: TokenUsage?
            // Data minimization: credentials are redacted and size is bounded
            // before text leaves the device for an external provider. Local
            // providers receive the context unmodified.
            let dispatchMessages = ContextSanitizer.sanitizedForDispatch(
                messages, isLocal: provider.id.hasPrefix("mlx"))
            let stream = await provider.complete(messages: dispatchMessages, tools: nil, stream: onChunk != nil)

            for try await chunk in stream {
                switch chunk {
                case .text(let text):
                    responseText += text
                    if !text.isEmpty { emittedVisibleText = true }
                    onChunk?(text)
                case .done(let u):
                    usage = u
                case .rateLimited(let retryAfter):
                    throw JarvisError.providerRateLimited(provider: provider.id, retryAfter: retryAfter)
                case .error(let errorMsg):
                    throw JarvisError.providerError(provider: provider.id, message: errorMsg)
                case .toolCall:
                    break
                }
            }

            // A cancelled turn is terminal: never reinterpret the resulting
            // silence as an empty provider response and fall back.
            try Task.checkCancellation()

            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let elapsed = callStart.duration(to: .now)
                let ms = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
                JarvisLogger.brain.info("Provider \(provider.id) completed \(label) in \(Int(ms))ms")
                if let usage { UsageManager.shared.recordUsage(provider: provider.id, usage: usage) }
                recordSuccess(providerID: provider.id, latencyMs: Int(ms))
                // User-visible provenance: which brain actually answered.
                if provider.id == "chatgpt-desktop" {
                    let transport = await self.chatgptDesktop.lastTransport()
                    ChatGPTBrainProvenance.shared.recordChatGPT(transport: transport)
                } else {
                    ChatGPTBrainProvenance.shared.clear()
                }
                return (responseText, provider.id)
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
            return nil
        } catch {
            // Cancellation (§9/§24): terminal, never a provider failure, never a
            // fallback. Recording it would wrongly trip the circuit breaker and
            // a fallback would answer a request the user already cancelled.
            if error is CancellationError || Task.isCancelled {
                JarvisLogger.brain.info("Provider \(provider.id) attempt cancelled; no fallback")
                throw CancellationError()
            }
            // Rate limiting is a temporary condition, not a proven failure:
            // cool the worker down for the server-requested duration instead
            // of counting it toward the hard-failure circuit breaker.
            if let je = error as? JarvisError, case .providerRateLimited(_, let retryAfter) = je {
                let cooldown = recordRateLimit(providerID: provider.id, retryAfter: retryAfter)
                JarvisLogger.brain.warning("Provider \(provider.id) rate-limited; cooling down \(Int(cooldown))s")
                EventBus.shared.publish(ProviderFailedEvent(
                    provider: provider.id,
                    error: error.localizedDescription,
                    fallbackProvider: "next-in-chain"
                ))
            } else {
                JarvisLogger.brain.warning("Provider \(provider.id) failed: \(error.localizedDescription)")
                recordFailure(providerID: provider.id, error: error.localizedDescription)
                EventBus.shared.publish(ProviderFailedEvent(
                    provider: provider.id,
                    error: error.localizedDescription,
                    fallbackProvider: "next-in-chain"
                ))
            }
            // Streaming commitment: if the caller already saw part of THIS
            // worker's answer, a silent switch would produce a mixed
            // response ("one ZiA answer" violated). End the turn truthfully.
            if emittedVisibleText {
                throw JarvisError.providerError(
                    provider: provider.id,
                    message: "\(provider.id) failed mid-stream after partial output; not falling back to avoid a mixed answer")
            }
            return nil
        }
    }

    /// Rough input-size estimate (~4 chars/token), used ONLY for a configured or
    /// observed tokens-per-minute window. It is an estimate, never presented or
    /// recorded as a real token count.
    static func estimatedTokens(for messages: [Message]) -> Int {
        messages.reduce(0) { $0 + max(1, $1.content.count / 4) }
    }

    /// Determines the fallback cascade for a given intent category.
    func getFallbackChain(for category: IntentClassifier.IntentCategory) -> [any LLMProvider] {
        let defaultChain: [any LLMProvider]
        switch category {
        case .coding:
            defaultChain = [chatgptDesktop, groqStrong, cerebras, sambanova, claude, openai, openrouter, localNormal, localReflex]
        case .deepReasoning:
            defaultChain = [chatgptDesktop, groqStrong, cerebras, sambanova, claude, gemini, openai, openrouter, localNormal, localReflex]
        case .webSearch:
            defaultChain = [chatgptDesktop, groqFast, groqStrong, cerebras, sambanova, openrouter, gemini, localNormal, localReflex]
        case .conversation, .systemQuery:
            defaultChain = [chatgptDesktop, groqFast, groqStrong, cerebras, sambanova, claude, gemini, openai, openrouter, localNormal, localReflex]
        }

        let prefs = PreferenceStore.shared.current
        if prefs.localOnly {
            return [localNormal, localReflex]
        }
        // Cost ordering: free → reserve → paid → local. Local always trails.
        let ordered = BudgetPolicy.normalizedByCost(defaultChain)
        if !prefs.preferredProviders.isEmpty {
            let preferred = ordered.filter { prefs.preferredProviders.contains($0.id) }
            let remaining = ordered.filter { !prefs.preferredProviders.contains($0.id) }
            return preferred + remaining
        }
        return ordered
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
            defaultChain = [groqFast, groqStrong, cerebras, localNormal, localReflex]
        case .strong:
            defaultChain = [groqStrong, cerebras, sambanova, chatgptDesktop, claude, openai, openrouter, localNormal, localReflex]
        case .deep:
            defaultChain = [chatgptDesktop, groqStrong, cerebras, sambanova, claude, gemini, openai, openrouter, localNormal, localReflex]
        case .localFallback:
            defaultChain = [localNormal, localReflex]
        }

        // Cost ordering: free → reserve → paid → local. Local always trails.
        let ordered = BudgetPolicy.normalizedByCost(defaultChain)
        if !prefs.preferredProviders.isEmpty {
            let preferred = ordered.filter { prefs.preferredProviders.contains($0.id) }
            let remaining = ordered.filter { !prefs.preferredProviders.contains($0.id) }
            return preferred + remaining
        }
        return ordered
    }
}
