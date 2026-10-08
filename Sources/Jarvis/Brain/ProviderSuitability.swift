import Foundation

// MARK: - Task requirements

/// How hard the work is. Drives which strength of worker is appropriate so a
/// trivial turn never consumes a 120B model and a deep task never lands on a
/// reflex engine.
enum TaskComplexity: String, Sendable, CaseIterable, Comparable {
    case trivial
    case standard
    case complex
    case deep

    private var order: Int {
        switch self {
        case .trivial: return 0
        case .standard: return 1
        case .complex: return 2
        case .deep: return 3
        }
    }

    static func < (lhs: TaskComplexity, rhs: TaskComplexity) -> Bool { lhs.order < rhs.order }
}

/// Where the work is allowed to run.
enum PrivacyRequirement: String, Sendable, Equatable {
    /// No constraint — any eligible worker, subject to cost policy.
    case any
    /// Must run on-device (sensitive data or explicit local-only preference).
    case localOnly
}

/// What a task needs from a worker. Deliberately small and explicit; the
/// scheduler fills it from the BrainTier / category / task metadata.
struct TaskRequirements: Sendable, Equatable {
    var complexity: TaskComplexity = .standard
    var requiredCapabilities: Set<Capability> = [.textGeneration]
    var privacy: PrivacyRequirement = .any
    var needsStructuredOutput: Bool = false
    var estimatedContextTokens: Int = 0
    var priority: Int = TaskPriority.normal

    init(complexity: TaskComplexity = .standard,
         requiredCapabilities: Set<Capability> = [.textGeneration],
         privacy: PrivacyRequirement = .any,
         needsStructuredOutput: Bool = false,
         estimatedContextTokens: Int = 0,
         priority: Int = TaskPriority.normal) {
        self.complexity = complexity
        self.requiredCapabilities = requiredCapabilities
        self.privacy = privacy
        self.needsStructuredOutput = needsStructuredOutput
        self.estimatedContextTokens = estimatedContextTokens
        self.priority = priority
    }
}

// MARK: - Provider descriptor (registry metadata)

/// Static, truthful metadata about one worker. This is the registry entry the
/// scheduler reasons over — it is *not* live health (that comes from
/// `ProviderManager` and the broker). Strength ratings are 0–3 ordinal and are
/// deliberately coarse: they steer routing without inventing benchmark scores.
struct ProviderDescriptor: Sendable, Equatable {
    let id: String
    let modelID: String
    let capabilities: Set<Capability>
    let costClass: ProviderCostClass
    let contextWindowTokens: Int
    let typicalLatencyMs: Int
    /// Ordinal 0–3: general reasoning strength.
    let reasoningStrength: Int
    /// Ordinal 0–3: coding ability.
    let codingStrength: Int
    /// True for on-device workers (privacy-safe).
    let isLocal: Bool
    /// Reserve-only workers (e.g. finite trial credit) are preferred only when
    /// free options are unsuitable.
    let reserveOnly: Bool
    /// Premium reasoning tier (the intentional lead worker for complex/deep
    /// work). Encodes the existing architecture's intent explicitly rather than
    /// hiding it in chain order.
    let isPremium: Bool

    init(id: String, modelID: String, capabilities: Set<Capability>,
         costClass: ProviderCostClass, contextWindowTokens: Int,
         typicalLatencyMs: Int, reasoningStrength: Int, codingStrength: Int,
         isLocal: Bool = false, reserveOnly: Bool = false, isPremium: Bool = false) {
        self.id = id
        self.modelID = modelID
        self.capabilities = capabilities
        self.costClass = costClass
        self.contextWindowTokens = contextWindowTokens
        self.typicalLatencyMs = typicalLatencyMs
        self.reasoningStrength = min(max(reasoningStrength, 0), 3)
        self.codingStrength = min(max(codingStrength, 0), 3)
        self.isLocal = isLocal
        self.reserveOnly = reserveOnly
        self.isPremium = isPremium
    }

    /// Registry default for a provider id. Unknown ids are treated as a modest
    /// free cloud worker — never as a strong or local one.
    static func `default`(for id: String) -> ProviderDescriptor {
        switch id {
        case "groq":
            return ProviderDescriptor(id: id, modelID: "openai/gpt-oss-20b",
                capabilities: [.textGeneration, .toolCalling], costClass: .free,
                contextWindowTokens: 131_072, typicalLatencyMs: 150,
                reasoningStrength: 1, codingStrength: 1)
        case "groq-strong":
            return ProviderDescriptor(id: id, modelID: "openai/gpt-oss-120b",
                capabilities: [.textGeneration, .toolCalling], costClass: .free,
                contextWindowTokens: 131_072, typicalLatencyMs: 400,
                reasoningStrength: 3, codingStrength: 3)
        case "cerebras":
            return ProviderDescriptor(id: id, modelID: "gpt-oss-120b",
                capabilities: [.textGeneration, .toolCalling], costClass: .trial,
                contextWindowTokens: 131_072, typicalLatencyMs: 200,
                reasoningStrength: 3, codingStrength: 3, reserveOnly: true)
        case "sambanova":
            return ProviderDescriptor(id: id, modelID: "gpt-oss-120b",
                capabilities: [.textGeneration, .toolCalling], costClass: .paid,
                contextWindowTokens: 131_072, typicalLatencyMs: 300,
                reasoningStrength: 3, codingStrength: 2)
        case "chatgpt-desktop":
            return ProviderDescriptor(id: id, modelID: "chatgpt-desktop",
                capabilities: [.textGeneration, .longContext, .structuredOutput], costClass: .free,
                contextWindowTokens: 128_000, typicalLatencyMs: 2_000,
                reasoningStrength: 3, codingStrength: 3, isPremium: true)
        case "anthropic", "claude":
            return ProviderDescriptor(id: id, modelID: "claude",
                capabilities: [.textGeneration, .toolCalling, .longContext], costClass: .paid,
                contextWindowTokens: 200_000, typicalLatencyMs: 800,
                reasoningStrength: 3, codingStrength: 3)
        case "openai":
            return ProviderDescriptor(id: id, modelID: "gpt",
                capabilities: [.textGeneration, .toolCalling], costClass: .paid,
                contextWindowTokens: 128_000, typicalLatencyMs: 700,
                reasoningStrength: 3, codingStrength: 3)
        case "gemini":
            return ProviderDescriptor(id: id, modelID: "gemini",
                capabilities: [.textGeneration, .vision, .longContext], costClass: .free,
                contextWindowTokens: 1_000_000, typicalLatencyMs: 600,
                reasoningStrength: 2, codingStrength: 2)
        case "openrouter":
            return ProviderDescriptor(id: id, modelID: "openrouter",
                capabilities: [.textGeneration], costClass: .free,
                contextWindowTokens: 32_000, typicalLatencyMs: 500,
                reasoningStrength: 2, codingStrength: 2)
        case let mlx where mlx.hasPrefix("mlx"):
            let isReflex = mlx.contains("reflex")
            return ProviderDescriptor(id: id,
                modelID: isReflex ? "mlx-reflex" : "mlx-normal",
                capabilities: [.textGeneration], costClass: .local,
                contextWindowTokens: isReflex ? 4_096 : 8_192,
                typicalLatencyMs: isReflex ? 200 : 800,
                reasoningStrength: isReflex ? 0 : 1, codingStrength: isReflex ? 0 : 1,
                isLocal: true)
        default:
            return ProviderDescriptor(id: id, modelID: id,
                capabilities: [.textGeneration], costClass: .free,
                contextWindowTokens: 32_000, typicalLatencyMs: 500,
                reasoningStrength: 1, codingStrength: 1)
        }
    }
}

// MARK: - Live scoring context

/// Live facts the scheduler has at decision time. Health/capacity/quota are
/// observational inputs; they never grant authority.
struct ProviderScoreContext: Sendable, Equatable {
    /// Excluded outright (quarantined, rate-limited, or unusable).
    var isUnhealthy: Bool = false
    /// Current in-flight requests on the provider (from the broker).
    var inFlight: Int = 0
    /// Current concurrency ceiling (from the broker).
    var maxConcurrent: Int = 4
    /// Server-reported remaining requests, when known.
    var requestsRemaining: Double? = nil
    /// Server-reported remaining tokens, when known.
    var tokensRemaining: Double? = nil

    init() {}
}

// MARK: - Suitability result

/// A scored, explainable verdict for one worker.
struct ProviderSuitability: Sendable, Equatable {
    let providerID: String
    let score: Int
    let isEligible: Bool
    let exclusionReason: String?
    let reasons: [String]

    /// One-line explanation the scheduler can log.
    var explanation: String {
        if !isEligible { return "\(providerID): ineligible — \(exclusionReason ?? "unknown")" }
        return "\(providerID): score \(score) [\(reasons.joined(separator: ", "))]"
    }
}

// MARK: - Scorer

/// Deterministic, explainable capability-aware scoring (§6).
///
/// Hard constraints (capability, privacy, context window, structured output,
/// quota exhaustion, health) mark a worker **ineligible** rather than merely
/// scoring low — an ineligible worker must never be chosen no matter how well
/// it scores on other axes. Soft preferences (complexity fit, latency, cost,
/// current capacity) adjust the score. No floating point, no randomness, no
/// clock: identical inputs always produce an identical ranking.
enum ProviderSuitabilityScorer {

    // Hard-constraint keys (documentation only).
    static let capabilityWeight = 40
    static let contextFitWeight = 10
    static let structuredWeight = 15

    /// Latency sensitivity in tenths (deep work cares less about latency).
    private static func latencyFactor(for complexity: TaskComplexity) -> Int {
        switch complexity {
        case .trivial: return 15
        case .standard: return 10
        case .complex: return 7
        case .deep: return 4
        }
    }

    static func score(provider: ProviderDescriptor,
                      requirements: TaskRequirements,
                      context: ProviderScoreContext) -> ProviderSuitability {
        var reasons: [String] = []

        // ── Hard constraints ──────────────────────────────────────────────
        if context.isUnhealthy {
            return ProviderSuitability(providerID: provider.id, score: Int.min,
                isEligible: false, exclusionReason: "unhealthy or throttled", reasons: [])
        }
        let missing = requirements.requiredCapabilities.subtracting(provider.capabilities)
        if !missing.isEmpty {
            let names = missing.map(\.rawValue).sorted().joined(separator: ", ")
            return ProviderSuitability(providerID: provider.id, score: Int.min,
                isEligible: false, exclusionReason: "missing capabilities: \(names)", reasons: [])
        }
        if requirements.privacy == .localOnly && !provider.isLocal {
            return ProviderSuitability(providerID: provider.id, score: Int.min,
                isEligible: false, exclusionReason: "privacy requires local execution", reasons: [])
        }
        if provider.contextWindowTokens < requirements.estimatedContextTokens {
            return ProviderSuitability(providerID: provider.id, score: Int.min,
                isEligible: false, exclusionReason: "context window too small", reasons: [])
        }
        if requirements.needsStructuredOutput && !provider.capabilities.contains(.structuredOutput) {
            // Not fatal on its own: most workers can be prompted for JSON. Penalise.
            reasons.append("no native structured output (-10)")
        }
        if context.requestsRemaining == 0 {
            return ProviderSuitability(providerID: provider.id, score: Int.min,
                isEligible: false, exclusionReason: "server-reported quota exhausted", reasons: [])
        }
        if context.tokensRemaining == 0 {
            return ProviderSuitability(providerID: provider.id, score: Int.min,
                isEligible: false, exclusionReason: "server-reported token quota exhausted", reasons: [])
        }

        var score = 0
        score += capabilityWeight
        reasons.append("capabilities match (+\(capabilityWeight))")

        // ── Complexity fit ────────────────────────────────────────────────
        switch requirements.complexity {
        case .trivial:
            if provider.reasoningStrength <= 1 { score += 25; reasons.append("right-sized for trivial (+25)") }
            if provider.reasoningStrength >= 3 { score -= 15; reasons.append("over-powered for trivial (-15)") }
        case .standard:
            if provider.reasoningStrength >= 1 { score += 15; reasons.append("adequate strength (+15)") }
        case .complex:
            if provider.reasoningStrength >= 2 { score += 30; reasons.append("strong reasoning (+30)") }
            if provider.reasoningStrength == 0 { score -= 25; reasons.append("too weak for complex (-25)") }
        case .deep:
            if provider.reasoningStrength >= 3 { score += 40; reasons.append("top-tier reasoning (+40)") }
            if provider.reasoningStrength <= 1 { score -= 30; reasons.append("too weak for deep (-30)") }
        }

        // ── Context fit ───────────────────────────────────────────────────
        if requirements.estimatedContextTokens > 0 {
            score += contextFitWeight
            reasons.append("context fits (+\(contextFitWeight))")
        }
        if requirements.needsStructuredOutput && provider.capabilities.contains(.structuredOutput) {
            score += structuredWeight
            reasons.append("structured output (+\(structuredWeight))")
        } else if requirements.needsStructuredOutput {
            score -= 10
        }

        // ── Premium tier ──────────────────────────────────────────────────
        if provider.isPremium, requirements.complexity >= .complex {
            score += 12
            reasons.append("premium reasoning tier (+12)")
        }

        // ── Latency (weighted by complexity: deep work tolerates latency) ──
        let latencyBase = max(0, 20 - provider.typicalLatencyMs / 100)
        let latencyScore = latencyBase * latencyFactor(for: requirements.complexity) / 10
        score += latencyScore
        if latencyScore > 0 { reasons.append("latency \(provider.typicalLatencyMs)ms (+\\(latencyScore))") }

        // ── Cost / reserve placement ──────────────────────────────────────
        // Mirrors the established cost order: free → reserve(trial) → paid →
        // local. Local is the resilience layer, so it trails even paid workers;
        // it leads only when privacy forces it (a hard constraint above).
        switch provider.costClass {
        case .free: break
        case .trial: score -= 25; reasons.append("finite trial credit is a reserve (-25)")
        case .paid: score -= 60; reasons.append("paid (policy-gated) (-60)")
        case .local: score -= 70; reasons.append("local, resilience fallback (-70)")
        }

        // ── Current capacity ──────────────────────────────────────────────
        if context.inFlight >= context.maxConcurrent {
            score -= 30
            reasons.append("at capacity; would queue (-30)")
        } else if context.inFlight == 0 {
            score += 5
            reasons.append("idle capacity (+5)")
        }

        return ProviderSuitability(providerID: provider.id, score: score,
                                   isEligible: true, exclusionReason: nil, reasons: reasons)
    }

    /// Rank workers: eligible first by score (descending), then stable by input
    /// order. Ineligible workers are returned last (still listed for diagnostics).
    static func rank(_ providers: [ProviderDescriptor],
                     requirements: TaskRequirements,
                     contexts: [String: ProviderScoreContext]) -> [ProviderSuitability] {
        let scored = providers.enumerated().map { index, provider -> (Int, ProviderSuitability) in
            (index, score(provider: provider, requirements: requirements,
                          context: contexts[provider.id] ?? ProviderScoreContext()))
        }
        return scored.sorted { lhs, rhs in
            if lhs.1.isEligible != rhs.1.isEligible { return lhs.1.isEligible }
            if lhs.1.isEligible {
                if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            }
            return lhs.0 < rhs.0
        }.map(\.1)
    }
}
