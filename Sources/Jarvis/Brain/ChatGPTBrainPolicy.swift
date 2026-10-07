import Foundation

/// Feature flag for the hybrid routing policy (Contract task 2.2). When enabled,
/// the ChatGPT brain is a candidate for the "deep" tier — but only under the
/// strict rules in `ChatGPTBrainPolicy`. Enabled by default; the effective gate
/// is the user opt-in (`ChatGPTBrain.isEnabled`, default OFF) plus the rules
/// below. Task 2.2 refines the surrounding policy.
enum HybridRoutingPolicy {
    private static let flagKey = "jarvis.routing.hybridPolicy"

    static var isEnabled: Bool {
        get {
            // Default ON; only an explicit user/developer `false` disables it.
            if UserDefaults.standard.object(forKey: flagKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: flagKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: flagKey) }
    }
}

/// Everything the policy needs to decide whether one request may go to ChatGPT.
struct ChatGPTRequestContext: Sendable, Equatable {
    let isUserPresent: Bool
    let needsDeepReasoning: Bool
    let isExtractionPrompt: Bool
    let isScheduledOrBackground: Bool
    let sensitivity: DataClassifier.SensitivityLevel
}

/// The strict eligibility rules for the ChatGPT deep tier.
///
/// ChatGPT is a *candidate*, never an authority: even when eligible, its output
/// is data that still flows through the normal validators.
enum ChatGPTBrainPolicy {
    enum Decision: Equatable, Sendable {
        case eligible
        case ineligible(reason: String)

        var isEligible: Bool { if case .eligible = self { return true }; return false }
        var reason: String? { if case .ineligible(let reason) = self { return reason }; return nil }
    }

    /// A cheap, deterministic heuristic for "this request needs real reasoning or
    /// writing" (not a bare lookup). Deliberately simple and portable.
    static func looksLikeDeepRequest(_ goal: String) -> Bool {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 80 { return true }
        let lowered = trimmed.lowercased()
        let cues = ["why", "how ", "explain", "compare", "analyse", "analyze", "write",
                    "draft", "summarise", "summarize", "plan", "design", "reason",
                    "trade-off", "tradeoff", "pros and cons"]
        return cues.contains { lowered.contains($0) }
    }

    /// Evaluate whether one request may use the ChatGPT brain right now.
    ///
    /// Order matters: the most safety-critical rules are checked first so the
    /// returned reason is the honest, most important one.
    static func evaluate(
        _ context: ChatGPTRequestContext,
        availability: ProviderAvailability,
        isQuarantined: Bool,
        dailyCapReached: Bool
    ) -> Decision {
        guard !context.isScheduledOrBackground else {
            return .ineligible(reason: "scheduled or background work always stays local")
        }
        guard context.isUserPresent else {
            return .ineligible(reason: "only user-present requests may use ChatGPT")
        }
        switch context.sensitivity {
        case .sensitive, .highlySensitive:
            return .ineligible(reason: "request classified \(context.sensitivity.rawValue); stays on-device")
        case .publicLevel, .personal:
            break
        }
        guard !context.isExtractionPrompt else {
            return .ineligible(reason: "the tuned extraction prompt must stay portable and local")
        }
        guard context.needsDeepReasoning else {
            return .ineligible(reason: "request does not need deep reasoning")
        }
        guard !dailyCapReached else {
            return .ineligible(reason: "ChatGPT brain daily soft cap reached")
        }
        guard !isQuarantined else {
            return .ineligible(reason: "ChatGPT brain quarantined after repeated failures")
        }
        guard availability.isUsable else {
            return .ineligible(reason: "ChatGPT brain unavailable: \(availability.reason ?? "unknown reason")")
        }
        return .eligible
    }
}

/// User-visible provenance for the most recent answer: which brain answered it.
/// Set only when a ChatGPT turn actually produces an answer, so the indicator
/// never lies about the source.
@MainActor
final class ChatGPTBrainProvenance: ObservableObject {
    static let shared = ChatGPTBrainProvenance()

    /// e.g. "ChatGPT · engine" / "ChatGPT · ui". nil when the last answer was not ChatGPT.
    @Published private(set) var lastAnswer: String?

    private init() {}

    func recordChatGPT(transport: String?) {
        let via = (transport?.isEmpty == false) ? transport! : "auto"
        lastAnswer = "ChatGPT · \(via)"
    }

    func clear() { lastAnswer = nil }
}
