import Foundation
import Testing
@testable import Jarvis

/// Capability-aware selection must be deterministic, explainable, and must never
/// place an ineligible worker first. Hard constraints (capability, privacy,
/// context, quota, health) are exclusions; the rest are soft preferences.
@Suite struct ProviderSuitabilityScorerTests {

    private func descriptor(_ id: String) -> ProviderDescriptor { .default(for: id) }

    private func verdict(_ id: String, _ requirements: TaskRequirements,
                         _ context: ProviderScoreContext = ProviderScoreContext()) -> ProviderSuitability {
        ProviderSuitabilityScorer.score(provider: descriptor(id), requirements: requirements, context: context)
    }

    // MARK: - Hard constraints

    @Test func missingCapabilityIsIneligible() {
        let req = TaskRequirements(requiredCapabilities: [.textGeneration, .vision])
        let groq = verdict("groq", req)
        #expect(!groq.isEligible)
        #expect(groq.exclusionReason?.contains("missing capabilities") == true)
        // gemini has vision.
        #expect(verdict("gemini", req).isEligible)
    }

    @Test func privacyLocalOnlyExcludesCloudWorkers() {
        let req = TaskRequirements(privacy: .localOnly)
        #expect(!verdict("groq-strong", req).isEligible)
        #expect(verdict("mlx-normal", req).isEligible)
        #expect(verdict("mlx-reflex", req).isEligible)
    }

    @Test func contextTooSmallIsIneligible() {
        let req = TaskRequirements(estimatedContextTokens: 200_000)
        #expect(!verdict("groq", req).isEligible)          // 131k window
        #expect(verdict("anthropic", req).isEligible)       // 200k window
    }

    @Test func quotaExhaustedIsIneligible() {
        var context = ProviderScoreContext()
        context.requestsRemaining = 0
        #expect(!verdict("groq", TaskRequirements(), context).isEligible)
    }

    @Test func unhealthyIsIneligible() {
        var context = ProviderScoreContext()
        context.isUnhealthy = true
        #expect(!verdict("groq", TaskRequirements(), context).isEligible)
    }

    // MARK: - Soft preferences

    @Test func trivialTaskPrefersTheLightweightWorker() {
        let req = TaskRequirements(complexity: .trivial)
        let fast = verdict("groq", req).score            // 20B, ~150ms
        let strong = verdict("groq-strong", req).score   // 120B, ~400ms
        #expect(fast > strong, "a trivial turn must not prefer the 120B worker")
        #expect(verdict("groq", req).isEligible && verdict("groq-strong", req).isEligible)
    }

    @Test func complexTaskPrefersStrongOverReflex() {
        let req = TaskRequirements(complexity: .complex)
        #expect(verdict("groq-strong", req).score > verdict("mlx-reflex", req).score)
    }

    @Test func deepTaskPrefersPremiumTier() {
        let req = TaskRequirements(complexity: .deep)
        #expect(verdict("chatgpt-desktop", req).score > verdict("groq", req).score)
    }

    @Test func costOrderIsFreeThenReserveThenPaidThenLocal() {
        let req = TaskRequirements(complexity: .standard)
        let ranked = ProviderSuitabilityScorer.rank(
            [descriptor("mlx-normal"), descriptor("sambanova"), descriptor("cerebras"), descriptor("groq")],
            requirements: req, contexts: [:])
        let ids = ranked.map(\.providerID)
        #expect(ids == ["groq", "cerebras", "sambanova", "mlx-normal"],
                "expected free → reserve → paid → local, got \(ids)")
    }

    @Test func atCapacityRanksBelowIdle() {
        let req = TaskRequirements(complexity: .standard)
        var busy = ProviderScoreContext(); busy.inFlight = 4; busy.maxConcurrent = 4
        var idle = ProviderScoreContext(); idle.inFlight = 0; idle.maxConcurrent = 4
        let busyScore = verdict("groq", req, busy).score
        let idleScore = verdict("groq", req, idle).score
        #expect(idleScore > busyScore)
    }

    @Test func structuredOutputBonusApplies() {
        let req = TaskRequirements(complexity: .standard, needsStructuredOutput: true)
        // chatgpt-desktop declares structuredOutput; groq does not.
        #expect(verdict("chatgpt-desktop", req).reasons.contains { $0.contains("structured") })
        #expect(verdict("groq", req).reasons.contains { $0.contains("no native structured") })
    }

    // MARK: - Ranking / determinism

    @Test func rankingIsDeterministic() {
        let req = TaskRequirements(complexity: .complex)
        let providers = [descriptor("groq"), descriptor("groq-strong"), descriptor("cerebras"), descriptor("mlx-normal")]
        let first = ProviderSuitabilityScorer.rank(providers, requirements: req, contexts: [:]).map(\.providerID)
        let second = ProviderSuitabilityScorer.rank(providers, requirements: req, contexts: [:]).map(\.providerID)
        #expect(first == second)
    }

    @Test func ineligibleWorkersRankLast() {
        let req = TaskRequirements(complexity: .standard, requiredCapabilities: [.textGeneration, .vision])
        let ranked = ProviderSuitabilityScorer.rank(
            [descriptor("groq"), descriptor("gemini")], requirements: req, contexts: [:])
        #expect(ranked.first?.providerID == "gemini", "only the vision-capable worker is eligible")
        #expect(ranked.last?.isEligible == false)
    }

    @Test func explanationIsProducedForBothOutcomes() {
        #expect(verdict("groq", TaskRequirements()).explanation.contains("score"))
        #expect(verdict("groq", TaskRequirements(privacy: .localOnly)).explanation.contains("ineligible"))
    }
}

/// Integration: the manager ranks a real chain with capability awareness.
@MainActor
@Suite(.serialized) struct ProviderManagerCapabilityRoutingTests {

    @Test func localOnlyRequirementYieldsOnlyLocalWorkers() async {
        let pm = ProviderManager.shared
        let chain = pm.getFallbackChain(for: BrainTier.fast)
        let ranked = await pm.rankProviders(
            for: chain,
            requirements: TaskRequirements(complexity: .standard, privacy: .localOnly))
        #expect(!ranked.isEmpty)
        #expect(ranked.allSatisfy { $0.id.hasPrefix("mlx") },
                "a local-only requirement must not surface any cloud worker")
    }

    @Test func standardRequirementKeepsFreeWorkersAheadOfLocal() async {
        let pm = ProviderManager.shared
        let chain = pm.getFallbackChain(for: BrainTier.fast)
        let ranked = await pm.rankProviders(
            for: chain, requirements: TaskRequirements(complexity: .standard))
        guard let firstCloud = ranked.firstIndex(where: { !$0.id.hasPrefix("mlx") }),
              let firstLocal = ranked.firstIndex(where: { $0.id.hasPrefix("mlx") }) else {
            // Free workers may legitimately be absent from this chain; nothing to assert.
            return
        }
        #expect(firstCloud < firstLocal, "free cloud workers must outrank local for non-private work")
    }

    @Test func tierRequirementsMapToExpectedComplexity() {
        let pm = ProviderManager.shared
        #expect(pm.requirements(for: BrainTier.fast).complexity == .standard)
        #expect(pm.requirements(for: BrainTier.strong).complexity == .complex)
        #expect(pm.requirements(for: BrainTier.deep).complexity == .deep)
        #expect(pm.requirements(for: BrainTier.localFallback).privacy == .localOnly)
    }
}
