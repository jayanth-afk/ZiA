import Foundation
import Testing
@testable import Jarvis

/// C4: the ChatGPT deep tier is a policy-gated candidate. Every route (eligible
/// and each ineligibility) is covered, plus routing integration and provenance.
@Suite(.serialized) struct ChatGPTBrainPolicyTests {

    private func context(
        userPresent: Bool = true,
        deep: Bool = true,
        extraction: Bool = false,
        background: Bool = false,
        sensitivity: DataClassifier.SensitivityLevel = .publicLevel
    ) -> ChatGPTRequestContext {
        ChatGPTRequestContext(
            isUserPresent: userPresent,
            needsDeepReasoning: deep,
            isExtractionPrompt: extraction,
            isScheduledOrBackground: background,
            sensitivity: sensitivity)
    }

    private func evaluate(
        _ ctx: ChatGPTRequestContext,
        availability: ProviderAvailability = .available,
        quarantined: Bool = false,
        capped: Bool = false
    ) -> ChatGPTBrainPolicy.Decision {
        ChatGPTBrainPolicy.evaluate(ctx, availability: availability,
                                    isQuarantined: quarantined, dailyCapReached: capped)
    }

    // MARK: - Eligible route

    @Test func eligibleForUserPresentDeepPublicRequest() {
        #expect(evaluate(context()).isEligible)
    }

    @Test func personalDataIsStillEligible() {
        #expect(evaluate(context(sensitivity: .personal)).isEligible)
    }

    // MARK: - Every ineligibility route

    @Test func scheduledOrBackgroundIsNeverEligible() {
        let decision = evaluate(context(background: true))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("background") == true)
    }

    @Test func nonUserPresentIsNeverEligible() {
        let decision = evaluate(context(userPresent: false))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("user-present") == true)
    }

    @Test func sensitiveDataNeverLeaves() {
        let decision = evaluate(context(sensitivity: .sensitive))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("on-device") == true)
    }

    @Test func highlySensitiveDataNeverLeaves() {
        let decision = evaluate(context(sensitivity: .highlySensitive))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("HIGHLY_SENSITIVE") == true)
    }

    @Test func extractionPromptAlwaysStaysLocal() {
        let decision = evaluate(context(extraction: true))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("extraction prompt") == true)
    }

    @Test func shallowRequestIsNotEligible() {
        let decision = evaluate(context(deep: false))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("deep reasoning") == true)
    }

    @Test func dailyCapBlocksFurtherRequests() {
        let decision = evaluate(context(), capped: true)
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("daily soft cap") == true)
    }

    @Test func quarantineBlocksFurtherRequests() {
        let decision = evaluate(context(), quarantined: true)
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("quarantined") == true)
    }

    @Test func unavailableBrainIsNotEligibleAndCarriesReason() {
        let decision = evaluate(context(), availability: .unavailable(reason: "Agent Bridge not responding"))
        #expect(!decision.isEligible)
        #expect(decision.reason?.contains("Agent Bridge not responding") == true)
    }

    @Test func safetyRulesOutrankDepth() {
        // A sensitive background extraction request reports the most important
        // reason first (background), never a shallow one.
        let decision = evaluate(context(deep: false, extraction: true, background: true, sensitivity: .highlySensitive))
        #expect(decision.reason?.contains("background") == true)
    }

    // MARK: - Depth heuristic

    @Test func depthHeuristicDetectsReasoningRequestsButNotLookups() {
        #expect(ChatGPTBrainPolicy.looksLikeDeepRequest("Explain how hybrid routing trades off latency and quality"))
        #expect(ChatGPTBrainPolicy.looksLikeDeepRequest("write a short poem about the sea"))
        #expect(!ChatGPTBrainPolicy.looksLikeDeepRequest("what time is it"))
    }

    // MARK: - Routing integration

    @Test @MainActor func routingRecordsWhyTheDeepTierWasSkipped() async {
        let previous = HybridRoutingPolicy.isEnabled
        HybridRoutingPolicy.isEnabled = true
        defer { HybridRoutingPolicy.isEnabled = previous }

        let background = await ProviderManager.shared.routingDecision(
            for: .conversation, context: context(background: true))
        #expect(background.chosen != "chatgpt-desktop")
        #expect(background.fallbackReason?.contains("background") == true)
        #expect(background.reason.contains("policy:") || background.fallbackReason != nil)

        let sensitive = await ProviderManager.shared.routingDecision(
            for: .conversation, context: context(sensitivity: .highlySensitive))
        #expect(sensitive.chosen != "chatgpt-desktop")
        #expect(sensitive.fallbackReason?.contains("on-device") == true)
    }

    // MARK: - Provenance

    @Test @MainActor func provenanceRecordsTransportAndClears() {
        let provenance = ChatGPTBrainProvenance.shared
        provenance.recordChatGPT(transport: "engine")
        #expect(provenance.lastAnswer == "ChatGPT · engine")
        provenance.recordChatGPT(transport: nil)
        #expect(provenance.lastAnswer == "ChatGPT · auto")
        provenance.clear()
        #expect(provenance.lastAnswer == nil)
    }
}
