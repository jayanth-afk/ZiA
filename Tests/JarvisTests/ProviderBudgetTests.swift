import Foundation
import Testing
@testable import Jarvis

/// A scripted provider for deterministic fallback tests. It yields exactly the
/// chunks it is given, so a test can make a worker emit partial text and then
/// fail (or fail before emitting anything).
actor FakeProvider: LLMProvider {
    nonisolated let id: String
    nonisolated let capabilities: Set<Capability> = [.textGeneration]
    nonisolated let currentLatencyMs = 1
    private let chunks: [StreamChunk]

    init(id: String, chunks: [StreamChunk]) {
        self.id = id
        self.chunks = chunks
    }

    var isAvailable: Bool { get async { true } }
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability { .available }

    func complete(messages: [Message], tools: [ToolDefinition]?, stream: Bool)
        -> AsyncThrowingStream<StreamChunk, any Error> {
        complete(messages: messages, tools: tools, stream: stream, options: [:])
    }

    func complete(messages: [Message], tools: [ToolDefinition]?, stream: Bool,
                  options: [String: any Sendable])
        -> AsyncThrowingStream<StreamChunk, any Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

// MARK: - Budget policy

@MainActor
@Suite(.serialized) struct BudgetPolicyTests {
    private func profile(_ id: String) -> ProviderCostProfile { BudgetPolicy.defaultProfile(for: id) }

    @Test func localAndFreeAreAlwaysAllowed() {
        let p = BudgetPolicy.shared
        p.resetToSafeDefaults()
        #expect(p.eligibility(for: profile("mlx-normal")).isAllowed)
        #expect(p.eligibility(for: profile("groq-strong")).isAllowed)
        #expect(p.eligibility(for: profile("chatgpt-desktop")).isAllowed)
    }

    @Test func paidIsBlockedByDefaultAndUnblockedByExplicitOptIn() {
        let p = BudgetPolicy.shared
        p.resetToSafeDefaults()
        #expect(!p.paidUsageAllowed, "the default must be: paid cloud spending disabled")
        #expect(!p.eligibility(for: profile("openai")).isAllowed)
        #expect(p.eligibility(for: profile("openai")).reason?.contains("disabled") == true)

        p.setPaidUsageAllowed(true)
        #expect(p.eligibility(for: profile("openai"), spentTodayUSD: 0).isAllowed)
        p.resetToSafeDefaults()
        #expect(!p.paidUsageAllowed)
    }

    @Test func paidIsBlockedWhenDailyBudgetExhausted() {
        let p = BudgetPolicy.shared
        p.setPaidUsageAllowed(true)
        let limited = p.eligibility(for: profile("openai"), spentTodayUSD: 1_000_000)
        #expect(!limited.isAllowed)
        #expect(limited.reason?.contains("budget exhausted") == true)
        p.resetToSafeDefaults()
    }

    @Test func trialIsReserveGated() {
        let p = BudgetPolicy.shared
        p.resetToSafeDefaults()
        #expect(profile("cerebras").costClass == .trial)
        #expect(profile("cerebras").reserveOnly)
        #expect(p.eligibility(for: profile("cerebras")).isAllowed)
        p.setReserveAllowed(false)
        #expect(!p.eligibility(for: profile("cerebras")).isAllowed)
        p.resetToSafeDefaults()
    }

    @Test func sambaNovaIsPaidAndEligibleOnlyWhenAuthorised() {
        let p = BudgetPolicy.shared
        p.resetToSafeDefaults()
        #expect(profile("sambanova").costClass == .paid)
        #expect(!p.eligibility(for: profile("sambanova")).isAllowed,
                "SambaNova is entitlement-driven; it must not be used without explicit paid authorisation")
    }

    @Test func unknownProviderDefaultsToFree() {
        #expect(profile("some-future-provider").costClass == .free)
    }

    @Test func costOrderingPutsFreeFirstReserveNextPaidThenLocal() {
        let ordered = BudgetPolicy.normalizedByCost([
            MLXProvider(id: "mlx-normal", modelSlot: "normal"),
            ClaudeProvider(),
            CerebrasProvider(),
            GroqProvider(id: "groq-strong", modelSlot: "strong")
        ]).map(\.id)
        #expect(ordered == ["groq-strong", "cerebras", "anthropic", "mlx-normal"])
    }
}

// MARK: - Fallback + commitment (dependency-injected, deterministic)

@MainActor
@Suite(.serialized) struct ProviderFallbackTests {

    @Test func fallsBackWhenProviderFailsBeforeEmittingAnything() async throws {
        let pm = ProviderManager.shared
        let a = FakeProvider(id: "fake-pre-a", chunks: [.error("boom")])
        let b = FakeProvider(id: "fake-pre-b", chunks: [.text("world"), .done(usage: .zero)])

        let collected = LockedValue<String>("")
        let result = try await pm.executeFallbackChain(
            [a, b],
            messages: [Message(role: .user, content: "hi")],
            onChunk: { text in collected.mutate { $0 += text } })

        #expect(result.response == "world")
        #expect(result.providerID == "fake-pre-b")
        #expect(collected.value == "world")
    }

    @Test func doesNotMixTwoWorkersWhenFirstFailsAfterPartialOutput() async {
        let pm = ProviderManager.shared
        let a = FakeProvider(id: "fake-partial-a", chunks: [.text("Hello "), .error("boom")])
        let b = FakeProvider(id: "fake-partial-b", chunks: [.text("world"), .done(usage: .zero)])

        let collected = LockedValue<String>("")
        await #expect(throws: (any Error).self) {
            _ = try await pm.executeFallbackChain(
                [a, b],
                messages: [Message(role: .user, content: "hi")],
                onChunk: { text in collected.mutate { $0 += text } })
        }
        // The second worker's text must NEVER appear after the first streamed.
        #expect(collected.value == "Hello ")
        #expect(!collected.value.contains("world"))
    }

    @Test func rateLimitedWorkerIsCooledDownAndFallsThrough() async throws {
        let pm = ProviderManager.shared
        pm.clearRateLimit("fake-rl-a")
        let a = FakeProvider(id: "fake-rl-a", chunks: [.rateLimited(retryAfter: 5)])
        let b = FakeProvider(id: "fake-rl-b", chunks: [.text("ok"), .done(usage: .zero)])

        let result = try await pm.executeFallbackChain(
            [a, b],
            messages: [Message(role: .user, content: "hi")])

        #expect(result.response == "ok")
        #expect(pm.isRateLimited("fake-rl-a"), "the throttled worker must be cooling down")
        #expect(pm.failureCount(for: "fake-rl-a") == 0,
                "a throttle must not be counted as a hard failure")
        pm.clearRateLimit("fake-rl-a")
    }

    @Test func paidWorkerIsSkippedWhileSpendingIsDisabled() async {
        let pm = ProviderManager.shared
        let policy = BudgetPolicy.shared
        policy.resetToSafeDefaults()
        let paid = FakeProvider(id: "openai", chunks: [.text("expensive"), .done(usage: .zero)])

        await #expect(throws: (any Error).self) {
            _ = try await pm.executeFallbackChain(
                [paid],
                messages: [Message(role: .user, content: "hi")])
        }

        policy.setPaidUsageAllowed(true)
        let result = try? await pm.executeFallbackChain(
            [paid],
            messages: [Message(role: .user, content: "hi")])
        #expect(result?.response == "expensive")
        policy.resetToSafeDefaults()
    }

    @Test func sambaNovaIsRegisteredInTheFleet() {
        #expect(ProviderManager.shared.allProviders.contains { $0.id == "sambanova" })
    }
}
