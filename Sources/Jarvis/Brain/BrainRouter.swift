import Foundation

/// Structured response from the unified ZiA intelligence pipeline.
struct UnifiedZiAResponse: Sendable {
    /// Full, formatted response text for visual display.
    let content: String
    /// Natural, clean spoken response text for speech synthesis (TTS).
    let spokenContent: String
    /// The brain tier that executed the reasoning.
    let tier: BrainTier
    /// The provider ID that served the turn.
    let providerID: String
    /// End-to-end execution latency in milliseconds.
    let executionTimeMs: Double
    /// The explainable routing decision.
    let decision: BrainRoutingDecision

    init(
        content: String,
        spokenContent: String? = nil,
        tier: BrainTier,
        providerID: String,
        executionTimeMs: Double,
        decision: BrainRoutingDecision
    ) {
        self.content = content
        self.spokenContent = spokenContent ?? SpokenResponseLayer.cleanForSpeech(content)
        self.tier = tier
        self.providerID = providerID
        self.executionTimeMs = executionTimeMs
        self.decision = decision
    }
}

/// Explainable routing decision describing which brain was chosen and WHY.
struct BrainRoutingDecision: Sendable, Equatable {
    let tier: BrainTier
    let suggestedProviderID: String
    let reason: String
    let isDeterministic: Bool
    let requiresPlanning: Bool
    let escalated: Bool

    init(
        tier: BrainTier,
        suggestedProviderID: String,
        reason: String,
        isDeterministic: Bool,
        requiresPlanning: Bool,
        escalated: Bool = false
    ) {
        self.tier = tier
        self.suggestedProviderID = suggestedProviderID
        self.reason = reason
        self.isDeterministic = isDeterministic
        self.requiresPlanning = requiresPlanning
        self.escalated = escalated
    }
}

/// Master Multi-Dimensional Brain Router for ZiA.
///
/// Implements the Target Brain Fleet:
///   Brain 0 — Deterministic Local Reflex Layer (zero-LLM)
///   Brain 1 — Fast Normal Reasoning (Groq 20B candidate)
///   Brain 2 — Strong Reasoning (Groq 120B candidate)
///   Brain 3 — Premium Deep Reasoning (ChatGPT Desktop / Agent Bridge)
///   Brain 4 — Local MLX Model (offline & privacy fallback)
///
/// Routing considers:
/// - Deterministic nature (system commands, calculator, direct answer)
/// - Task continuity (continuation of active goals)
/// - Privacy sensitivity (sensitive content stays on-device)
/// - Complexity & reasoning depth (coding, debugging, architecture)
/// - Provider health and availability
@MainActor
final class BrainRouter {
    static let shared = BrainRouter()

    private init() {}

    // MARK: - Public API

    /// Analyze a user request and determine the optimal BrainTier.
    func decide(
        for transcript: String,
        environment: TaskEnvironmentContext? = nil
    ) async -> BrainRoutingDecision {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BrainRoutingDecision(
                tier: .reflex,
                suggestedProviderID: "deterministic",
                reason: "empty input",
                isDeterministic: true,
                requiresPlanning: false
            )
        }

        // 1. Emergency stop check (Immediate deterministic halt)
        if EmergencyInterrupt.shared.checkForEmergency(in: trimmed) {
            return BrainRoutingDecision(
                tier: .reflex,
                suggestedProviderID: "deterministic",
                reason: "emergency stop keyword detected",
                isDeterministic: true,
                requiresPlanning: false
            )
        }

        // 2. Deterministic reflex rules (open app, volume, mute, web search prefix)
        if DeterministicRouter.shared.match(trimmed) != nil {
            return BrainRoutingDecision(
                tier: .reflex,
                suggestedProviderID: "deterministic",
                reason: "matches deterministic system action pattern (zero-LLM reflex)",
                isDeterministic: true,
                requiresPlanning: false
            )
        }

        // 3. Deterministic direct answers (time, date, identity, calculator)
        if DirectAnswerRouter.shared.evaluateDirectAnswer(trimmed) != nil {
            return BrainRoutingDecision(
                tier: .reflex,
                suggestedProviderID: "deterministic",
                reason: "resolved by deterministic direct answer / local calculator",
                isDeterministic: true,
                requiresPlanning: false
            )
        }

        // 4. Privacy Sensitivity Check (DataClassifier)
        let sensitivity = DataClassifier.shared.classify(trimmed)
        let isLocalOnly = PreferenceStore.shared.current.localOnly || sensitivity == .sensitive || sensitivity == .highlySensitive
        if isLocalOnly {
            return BrainRoutingDecision(
                tier: .localFallback,
                suggestedProviderID: "mlx-normal",
                reason: sensitivity == .sensitive || sensitivity == .highlySensitive
                    ? "data sensitivity classified as \(sensitivity.rawValue); constrained to local processing"
                    : "user preference set to localOnly",
                isDeterministic: false,
                requiresPlanning: false
            )
        }

        // 5. Task Continuity Check
        if let continuity = TaskContinuity.query(for: trimmed) {
            if continuity == .continueTask, TaskStateMachine.shared.isPersistenceAvailable {
                return BrainRoutingDecision(
                    tier: .reflex,
                    suggestedProviderID: "deterministic",
                    reason: "task continuity query resumes authoritative active task",
                    isDeterministic: true,
                    requiresPlanning: true
                )
            }
        }

        // 6. Deep Architecture / Complex Reasoning Signals
        let lower = trimmed.lowercased()
        let isArchitectureOrSystemDesign = lower.contains("architecture")
            || lower.contains("redesign")
            || lower.contains("fundamentally better")
            || lower.contains("trade-off")
            || lower.contains("tradeoff")
            || lower.contains("system-wide")
            || lower.contains("deeply about")

        // 7. Coding & Technical Debugging Signals
        let isCodingTask = lower.contains("function")
            || lower.contains("algorithm")
            || lower.contains("bug")
            || lower.contains("fix the")
            || lower.contains("stack trace")
            || lower.contains("refactor")
            || lower.contains("swift")
            || lower.contains("python")
            || lower.contains("compile")
            || lower.contains("crash")

        // 8. Intent Engine Classification
        let ziaIntent = IntentEngine.classify(trimmed)

        // ── TIER SELECTION LOGIC ──

        // Candidate 3: Premium ChatGPT Reasoning (Brain 3)
        // For deep architecture, high ambiguity, and profound multi-step analysis
        if isArchitectureOrSystemDesign {
            let chatgptProvider = ProviderManager.shared.chatgptDesktop
            let isAvailable = await ProviderManager.shared.isProviderAvailable(chatgptProvider)
            let isQuarantined = ProviderManager.shared.isQuarantined(chatgptProvider.id)

            if isAvailable && !isQuarantined && !ChatGPTBrain.isDailyCapReached() {
                return BrainRoutingDecision(
                    tier: .deep,
                    suggestedProviderID: "chatgpt-desktop",
                    reason: "deep architectural analysis requires premium reasoning brain",
                    isDeterministic: false,
                    requiresPlanning: false
                )
            } else {
                let groqStrong = ProviderManager.shared.groqStrong
                return BrainRoutingDecision(
                    tier: .strong,
                    suggestedProviderID: groqStrong.id,
                    reason: "deep architecture task: premium brain unavailable, falling back to strong brain (120B)",
                    isDeterministic: false,
                    requiresPlanning: false,
                    escalated: true
                )
            }
        }

        // Candidate 2: Strong Reasoning (Brain 2 - Groq 120B)
        // For complex coding, debugging, multi-step planning, algorithms
        if isCodingTask || ziaIntent.kind == .codingTask || ziaIntent.kind == .multiStepProject || trimmed.count > 500 {
            let groqStrong = ProviderManager.shared.groqStrong
            let isStrongAvailable = await ProviderManager.shared.isProviderAvailable(groqStrong)
            if isStrongAvailable && !ProviderManager.shared.isQuarantined(groqStrong.id) {
                return BrainRoutingDecision(
                    tier: .strong,
                    suggestedProviderID: groqStrong.id,
                    reason: "complex coding or multi-step reasoning task routed to strong brain (120B)",
                    isDeterministic: false,
                    requiresPlanning: false
                )
            }
        }

        // Candidate 1: Fast Normal Reasoning (Brain 1 - Groq 20B)
        // For everyday conversations, explanations, summaries, low-latency turns
        let groqFast = ProviderManager.shared.groqFast
        let isFastAvailable = await ProviderManager.shared.isProviderAvailable(groqFast)
        if isFastAvailable && !ProviderManager.shared.isQuarantined(groqFast.id) {
            return BrainRoutingDecision(
                tier: .fast,
                suggestedProviderID: groqFast.id,
                reason: "standard conversational / reasoning turn routed to fast brain (20B) for ultra-low latency",
                isDeterministic: false,
                requiresPlanning: false
            )
        }

        // If Groq Fast is unavailable, try Groq Strong
        let groqStrong = ProviderManager.shared.groqStrong
        if await ProviderManager.shared.isProviderAvailable(groqStrong) && !ProviderManager.shared.isQuarantined(groqStrong.id) {
            return BrainRoutingDecision(
                tier: .strong,
                suggestedProviderID: groqStrong.id,
                reason: "fast brain unavailable; escalating to strong brain",
                isDeterministic: false,
                requiresPlanning: false,
                escalated: true
            )
        }

        // Candidate 4: Local MLX Fallback (Brain 4)
        return BrainRoutingDecision(
            tier: .localFallback,
            suggestedProviderID: "mlx-normal",
            reason: "cloud reasoning brains unavailable; routed to resilient on-device MLX fallback",
            isDeterministic: false,
            requiresPlanning: false
        )
    }

    /// Primary routing method returning unified response with spoken & visual formats.
    func routeUnified(
        _ transcript: String,
        destination: OutputDestination = .visual,
        environment: TaskEnvironmentContext? = nil,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> UnifiedZiAResponse {
        let startTime = CFAbsoluteTimeGetCurrent()
        let decision = await decide(for: transcript, environment: environment)
        JarvisLogger.brain.info("BrainRouter selected tier [\(decision.tier.rawValue)] provider [\(decision.suggestedProviderID)]: \(decision.reason)")

        // Brain 0: Deterministic Reflex Path
        if decision.tier == .reflex {
            let response = try await AgentLoop.shared.run(goal: transcript)
            onChunk?(response)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return UnifiedZiAResponse(
                content: response,
                tier: .reflex,
                providerID: "deterministic",
                executionTimeMs: elapsed,
                decision: decision
            )
        }

        // Direct Reasoning Dispatch via ContextCompiler & ProviderManager Fallback Ladder
        let messages = ContextCompiler.shared.compile(
            goal: transcript,
            tier: decision.tier,
            destination: destination,
            environment: environment
        )

        let isDeep = decision.tier == .deep
        let sensitivity = DataClassifier.shared.classify(transcript)
        let requestContext = ChatGPTRequestContext(
            isUserPresent: true,
            needsDeepReasoning: isDeep,
            isExtractionPrompt: false,
            isScheduledOrBackground: false,
            sensitivity: sensitivity
        )

        var finalResponse = ""
        var actualProvider = decision.suggestedProviderID

        // Track whether the caller already saw part of an answer. If it did, a
        // fallback would append a SECOND answer to the first, violating the "one
        // ZiA response" invariant. In that case we surface the failure truthfully
        // instead of emitting a mixed response.
        let emittedVisibleText = LockedValue<Bool>(false)
        let trackedChunk: (@Sendable (String) -> Void)?
        if let onChunk {
            trackedChunk = { @Sendable text in
                if !text.isEmpty { emittedVisibleText.value = true }
                onChunk(text)
            }
        } else {
            trackedChunk = nil
        }

        do {
            let result = try await ProviderManager.shared.executeWithStreamingFallback(
                messages: messages,
                tier: decision.tier,
                context: requestContext,
                onChunk: trackedChunk
            )
            finalResponse = result.response
            actualProvider = result.providerID
        } catch {
            if emittedVisibleText.value {
                // Partial output already reached the user; do not append a second answer.
                JarvisLogger.brain.warning("Primary tier [\(decision.tier.rawValue)] failed after partial output: \(error.localizedDescription). Not falling back (would mix answers).")
                throw error
            }
            // Automatic escalation/fallback if primary attempt throws
            JarvisLogger.brain.warning("Primary tier [\(decision.tier.rawValue)] failed: \(error.localizedDescription). Falling back through AgentLoop.")
            finalResponse = try await AgentLoop.shared.run(goal: transcript)
            onChunk?(finalResponse)
            actualProvider = "agent-loop-fallback"
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        return UnifiedZiAResponse(
            content: finalResponse,
            tier: decision.tier,
            providerID: actualProvider,
            executionTimeMs: elapsed,
            decision: decision
        )
    }

    /// Stream unified response tokens incrementally.
    func routeStream(
        _ transcript: String,
        destination: OutputDestination = .visual,
        environment: TaskEnvironmentContext? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.routeUnified(
                        transcript,
                        destination: destination,
                        environment: environment,
                        onChunk: { chunk in
                            continuation.yield(chunk)
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Backward-compatible route method returning raw response string.
    func route(_ transcript: String) async throws -> String {
        let response = try await routeUnified(transcript)
        return response.content
    }
}
