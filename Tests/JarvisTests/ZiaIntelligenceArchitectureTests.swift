import Foundation
import Testing
@testable import Jarvis

@Suite struct ZiaIntelligenceArchitectureTests {

    // MARK: - 1. Deterministic Routing (Brain 0)

    @Test @MainActor func deterministicRouting_openApp_routesToReflex() async {
        let decision = await BrainRouter.shared.decide(for: "Open Safari")
        #expect(decision.tier == .reflex)
        #expect(decision.isDeterministic)
        #expect(decision.suggestedProviderID == "deterministic")
    }

    @Test @MainActor func deterministicRouting_mathExpression_routesToReflexAndEvaluates() async {
        let decision = await BrainRouter.shared.decide(for: "What is 17 × 38?")
        #expect(decision.tier == .reflex)
        #expect(decision.isDeterministic)

        let result = DirectAnswerRouter.shared.evaluateDirectAnswer("What is 17 × 38?")
        #expect(result == "Result: 646")

        let result2 = DirectAnswerRouter.shared.evaluateDirectAnswer("calculate 10 + 25")
        #expect(result2 == "Result: 35")
    }

    @Test @MainActor func deterministicRouting_identityQuery_returnsZia() {
        let result = DirectAnswerRouter.shared.evaluateDirectAnswer("who are you")
        #expect(result?.contains("ZiA") == true)
        #expect(result?.contains("intelligent desktop assistant") == true)
    }

    // MARK: - 2. Fast Normal Reasoning (Brain 1)

    @Test @MainActor func fastReasoning_everydayConversation_routesToFast() async {
        let decision = await BrainRouter.shared.decide(for: "What is the difference between REST and GraphQL?")
        // Should select .fast (or .strong if fast unavailable in test environment)
        #expect(decision.tier == .fast || decision.tier == .strong)
        #expect(!decision.isDeterministic)
    }

    @Test @MainActor func fastReasoning_summarization_routesToFast() async {
        let decision = await BrainRouter.shared.decide(for: "Summarize this paragraph for me.")
        #expect(decision.tier == .fast || decision.tier == .strong)
    }

    // MARK: - 3. Strong Reasoning (Brain 2)

    @Test @MainActor func strongReasoning_complexCodingAndDebugging_routesToStrong() async {
        let decision = await BrainRouter.shared.decide(for: "Explain this 150-line algorithm and find the bug.")
        #expect(decision.tier == .strong)
        #expect(decision.suggestedProviderID == "groq-strong")
    }

    @Test @MainActor func strongReasoning_refactoring_routesToStrong() async {
        let decision = await BrainRouter.shared.decide(for: "Refactor this function and fix the stack trace crash in swift.")
        #expect(decision.tier == .strong)
    }

    // MARK: - 4. Deep Reasoning (Brain 3)

    @Test @MainActor func deepReasoning_architectureRedesign_routesToDeepOrStrong() async {
        let decision = await BrainRouter.shared.decide(for: "Understand the entire ZiA architecture and propose a fundamentally better architecture.")
        #expect(decision.tier == .deep || decision.tier == .strong)
    }

    // MARK: - 5. Privacy-Sensitive Routing (Brain 4 / Local Fallback)

    @Test @MainActor func privacyRouting_sensitiveContent_routesToLocalFallback() async {
        let decision = await BrainRouter.shared.decide(for: "My secret token is ghp_1234567890abcdefghijklmnopqrstuvwxyz, analyze it")
        #expect(decision.tier == .localFallback)
        #expect(decision.suggestedProviderID == "mlx-normal")
        #expect(decision.reason.contains("sensitive") || decision.reason.contains("local"))
    }

    // MARK: - 6. Memory Supersession

    @Test func memorySupersession_oldDecisionExcludedFromRetrieval() throws {
        let store = ZiaMemoryStore(storageURL: nil)

        // Store original decision
        let oldRecord = try store.write(MemoryDraft(
            kind: .episodic,
            trust: .taskResult,
            content: "We decided to use Groq 20B for normal conversations.",
            source: "architecture_meeting",
            retentionLevel: .critical
        ))

        // Initial retrieval returns oldRecord
        let initial = store.retrieveTrusted(query: "normal conversations")
        #expect(initial.contains(where: { $0.id == oldRecord.id }))

        // Supersede with updated decision
        let newRecord = try store.supersede(
            oldID: oldRecord.id,
            with: MemoryDraft(
                kind: .episodic,
                trust: .taskResult,
                content: "We decided to upgrade normal conversations to Groq 120B.",
                source: "architecture_review",
                retentionLevel: .critical
            )
        )

        // Retrieval now excludes superseded record and returns new record
        let updated = store.retrieveTrusted(query: "normal conversations")
        #expect(updated.contains(where: { $0.id == newRecord.id }))
        #expect(!updated.contains(where: { $0.id == oldRecord.id }), "Superseded record must be excluded from trusted retrieval")
    }

    // MARK: - 7. Canonical Identity Contract

    @Test func canonicalIdentityContract_embedsZiaAndDestinationRules() {
        let visualPrompt = ZiaIdentity.systemPrompt(for: .strong, destination: .visual)
        #expect(visualPrompt.contains("ZiA"))
        #expect(visualPrompt.contains("Visual Output Mode"))
        #expect(visualPrompt.contains("Never claim an action succeeded unless verified"))

        let voicePrompt = ZiaIdentity.systemPrompt(for: .fast, destination: .voice)
        #expect(voicePrompt.contains("ZiA"))
        #expect(voicePrompt.contains("Voice Output Mode"))
        #expect(voicePrompt.contains("1 to 3 spoken sentences"))
        #expect(voicePrompt.contains("Avoid markdown"))
    }

    // MARK: - 8. Spoken Response Layer

    @Test func spokenResponseLayer_cleansMarkdownAndCodeForSpeech() {
        let rawMarkdown = """
        ### Solution
        Here is the **code** you need:
        ```swift
        func test() { print("hello") }
        ```
        Check [Documentation](https://example.com/docs) for details.
        - Step 1: Open Terminal
        - Step 2: Run `swift build`
        """

        let cleaned = SpokenResponseLayer.cleanForSpeech(rawMarkdown)
        #expect(!cleaned.contains("###"))
        #expect(!cleaned.contains("```"))
        #expect(!cleaned.contains("**"))
        #expect(!cleaned.contains("https://"))
        #expect(!cleaned.contains("- Step 1"))
        #expect(cleaned.contains("(code snippet omitted)"))
        #expect(cleaned.contains("Step 1: Open Terminal"))
        #expect(cleaned.contains("swift build"))
    }

    // MARK: - 9. Context Compiler Multi-Tier Budgets

    @Test @MainActor func contextCompiler_respectsTierBudgets() {
        let fastMessages = ContextCompiler.shared.compile(
            goal: "What is concurrency?",
            tier: .fast,
            destination: .voice
        )
        #expect(fastMessages.first?.role == .system)
        #expect(fastMessages.first?.content.contains("ZiA") == true)
        #expect(fastMessages.last?.role == .user)

        let strongMessages = ContextCompiler.shared.compile(
            goal: "Refactor async task worker",
            tier: .strong,
            destination: .visual
        )
        #expect(strongMessages.first?.content.contains("Strong") == true)
    }

    // MARK: - 10. Provider Manager Fleet Integration

    @Test @MainActor func providerManager_fleetTiersConfigured() {
        let pm = ProviderManager.shared
        #expect(pm.groqFast.id == "groq")
        #expect(pm.groqStrong.id == "groq-strong")

        let codingChain = pm.getFallbackChain(for: .coding)
        #expect(codingChain.first?.id == "chatgpt-desktop")
        #expect(codingChain.contains(where: { $0.id == "groq-strong" }))

        let strongChain = pm.getFallbackChain(for: BrainTier.strong)
        #expect(strongChain.first?.id == "groq-strong")
    }
}
