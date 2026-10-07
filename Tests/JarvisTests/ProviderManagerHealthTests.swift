import Foundation
import Testing
@testable import Jarvis

/// Rate limiting must be a *temporary* cooldown, distinct from the hard-failure
/// quarantine: a healthy provider that gets throttled should be routed around
/// for as long as the server asks, then recovered automatically — never
/// punished as if it had failed. These tests pin that separation plus the
/// enriched operational health fields.
@MainActor
@Suite(.serialized) struct ProviderManagerHealthTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func rateLimitSetsAndExpiresCooldown() {
        let pm = ProviderManager.shared
        pm.clearRateLimit("groq")
        let applied = pm.recordRateLimit(providerID: "groq", retryAfter: 30, now: t0)
        #expect(applied == 30)
        #expect(pm.isRateLimited("groq", now: t0.addingTimeInterval(10)))
        #expect(pm.isRateLimited("groq", now: t0.addingTimeInterval(29)))
        // Past the cooldown the provider recovers with no timer.
        #expect(!pm.isRateLimited("groq", now: t0.addingTimeInterval(31)))
        #expect(pm.rateLimitReason("groq") == nil)
        pm.clearRateLimit("groq")
    }

    @Test func rateLimitUsesServerHintAndReportsReason() {
        let pm = ProviderManager.shared
        pm.recordRateLimit(providerID: "groq", retryAfter: 120, now: .now)
        #expect(pm.isRateLimited("groq"))
        #expect(pm.rateLimitReason("groq")?.contains("rate-limited") == true)
        pm.clearRateLimit("groq")
    }

    @Test func missingHintFallsBackToDefaultCooldown() {
        let pm = ProviderManager.shared
        pm.clearRateLimit("groq")
        let applied = pm.recordRateLimit(providerID: "groq", retryAfter: nil, now: t0)
        #expect(applied == ProviderRateLimit.defaultCooldown)
        pm.clearRateLimit("groq")
    }

    @Test func rateLimitDoesNotCountAsFailure() {
        let pm = ProviderManager.shared
        let before = pm.failureCount(for: "groq")
        for _ in 0..<5 { pm.recordRateLimit(providerID: "groq", retryAfter: 1, now: .now) }
        #expect(pm.failureCount(for: "groq") == before,
                "a throttle must never increment the hard-failure counter")
        #expect(!pm.isQuarantined("groq"), "a throttle must never trip the circuit breaker")
        pm.clearRateLimit("groq")
    }

    @Test func healthSnapshotExposesRateLimitAndOperationalFields() async {
        let pm = ProviderManager.shared
        pm.recordRateLimit(providerID: "groq", retryAfter: 60, now: .now)

        let summary = await pm.healthSnapshot()
        #expect(summary.rateLimited.contains("groq"))

        guard let status = summary.statuses.first(where: { $0.id == "groq" }) else {
            Issue.record("groq provider status missing"); return
        }
        #expect(status.isRateLimited)
        #expect(status.rateLimitedUntil != nil)
        // Operational fields exist and are internally consistent.
        #expect(status.successCount >= 0)
        #expect(status.failureCount >= 0)
        pm.clearRateLimit("groq")
    }

    @Test func routingDecisionSkipsRateLimitedProvider() async {
        let pm = ProviderManager.shared
        pm.clearRateLimit("groq")
        defer { pm.clearRateLimit("groq") }
        pm.recordRateLimit(providerID: "groq", retryAfter: 60, now: .now)

        let decision = await pm.routingDecision(for: .conversation)
        #expect(decision.chosen != "groq",
                "a rate-limited provider must not be selected while cooling down")
    }
}
