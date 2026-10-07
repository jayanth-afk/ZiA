import Foundation

// MARK: - Cost classification

/// How a provider's usage is paid for. This is the axis the spending guard
/// reasons about — never a dollar figure we invented.
enum ProviderCostClass: String, Sendable, CaseIterable {
    /// On-device inference. Zero marginal cost.
    case local
    /// Metered cloud, but backed by a free quota/tier. No accidental spend.
    case free
    /// Finite promotional/trial credit. Real value, but already granted — treat
    /// as a *reserve* resource and prefer it only when free options are gone.
    case trial
    /// Spends real money. Eligible only when paid usage is explicitly authorised.
    case paid

    /// Cost rank used to order a fallback chain: free → reserve → paid → local.
    var rank: Int {
        switch self {
        case .free: return 0
        case .trial: return 1
        case .paid: return 2
        case .local: return 3
        }
    }
}

/// A quota figure that is only ever `.known` when ZiA actually observed it.
/// Unknown must stay unknown — never invent a remaining count (§10).
enum QuotaValue: Sendable, Equatable {
    case known(Double)
    case unknown

    var isKnown: Bool {
        if case .known = self { return true }
        return false
    }

    var value: Double? {
        if case .known(let v) = self { return v }
        return nil
    }
}

/// Observed quota state for one provider. Defaults to fully unknown. Populated
/// only from provider-reported signals (headers/retry-after/billing API), never
/// inferred from a single failure.
struct ProviderQuota: Sendable, Equatable {
    var requestsRemaining: QuotaValue = .unknown
    var creditRemainingUSD: QuotaValue = .unknown
    var resetAt: Date?
    var lastUpdated: Date?

    static let unknown = ProviderQuota()
}

/// Static cost metadata for one provider. Prices are optional because most
/// providers do not publish a stable per-token number we can trust — unknown
/// prices stay unknown rather than being fabricated.
struct ProviderCostProfile: Sendable, Equatable {
    let id: String
    let costClass: ProviderCostClass
    /// Trial providers flagged reserve-only should be preserved for meaningful
    /// work and skipped for trivial requests (handled by chain ordering).
    let reserveOnly: Bool
    let inputUSDPer1M: Double?
    let outputUSDPer1M: Double?

    init(id: String, costClass: ProviderCostClass, reserveOnly: Bool = false,
         inputUSDPer1M: Double? = nil, outputUSDPer1M: Double? = nil) {
        self.id = id
        self.costClass = costClass
        self.reserveOnly = reserveOnly
        self.inputUSDPer1M = inputUSDPer1M
        self.outputUSDPer1M = outputUSDPer1M
    }
}

// MARK: - Eligibility

enum BudgetEligibility: Sendable, Equatable {
    case allowed
    case blocked(reason: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var reason: String? {
        if case .blocked(let r) = self { return r }
        return nil
    }
}

// MARK: - Budget policy

/// The hard spending guard. Default safety: **paid cloud spending is disabled.**
///
/// A routing bug (or a future edit) must never be able to consume unbounded
/// money. Every provider is classified once; selection asks this policy whether
/// the class is currently spend-authorised. Providers whose cost is unknown are
/// treated as their declared class, and paid classes fail closed.
@MainActor
final class BudgetPolicy {
    static let shared = BudgetPolicy()

    /// Paid cloud providers are only eligible after the user explicitly opts in.
    private(set) var paidUsageAllowed: Bool = false
    /// Finite trial credit is a reserve resource. It is usable by default but is
    /// ordered after free providers, so it is never spent on trivial work.
    private(set) var reserveAllowed: Bool = true

    private init() {}

    func setPaidUsageAllowed(_ allowed: Bool) {
        paidUsageAllowed = allowed
        JarvisLogger.brain.info("Paid cloud usage \(allowed ? "enabled" : "disabled") by policy")
    }

    func setReserveAllowed(_ allowed: Bool) {
        reserveAllowed = allowed
        JarvisLogger.brain.info("Trial/reserve provider usage \(allowed ? "enabled" : "disabled") by policy")
    }

    /// Reset to the safe defaults (used by tests and by a "reset settings" path).
    func resetToSafeDefaults() {
        paidUsageAllowed = false
        reserveAllowed = true
    }

    /// Decide whether a provider may be selected right now given its cost class,
    /// today's spend, and the current authorisation.
    func eligibility(for profile: ProviderCostProfile, spentTodayUSD: Double? = nil) -> BudgetEligibility {
        switch profile.costClass {
        case .local, .free:
            return .allowed
        case .trial:
            return reserveAllowed
                ? .allowed
                : .blocked(reason: "finite trial credit; reserve usage is disabled")
        case .paid:
            guard paidUsageAllowed else {
                return .blocked(reason: "paid cloud spending is disabled (enable it explicitly to use this provider)")
            }
            let spent = spentTodayUSD ?? UsageManager.shared.dailySpentUSD
            let limit = Config.shared.dailyBudgetUSD
            if spent >= limit {
                return .blocked(reason: "daily budget exhausted ($\(String(format: "%.2f", spent)) of $\(String(format: "%.2f", limit)))")
            }
            return .allowed
        }
    }

    func eligibility(forProviderID id: String, spentTodayUSD: Double? = nil) -> BudgetEligibility {
        eligibility(for: Self.defaultProfile(for: id), spentTodayUSD: spentTodayUSD)
    }

    // MARK: - Default registry

    /// Cost classification for the built-in fleet. Unknown ids default to
    /// `.free` (no accidental spend attributed to a provider we don't know),
    /// while every paid provider in the fleet is declared explicitly.
    static func defaultProfile(for id: String) -> ProviderCostProfile {
        switch id {
        // NOTE: the Claude provider's runtime id is "anthropic" (its keychain
        // service); map both spellings so it can never be mistaken for free.
        case "anthropic", "claude":
            return ProviderCostProfile(id: id, costClass: .paid)
        case "openai":
            return ProviderCostProfile(id: id, costClass: .paid)
        case "sambanova":
            // Entitlement-driven account; only usable once paid spending is
            // authorised. Registered, but ineligible by default.
            return ProviderCostProfile(id: id, costClass: .paid)
        case "cerebras":
            // Finite promotional credit → reserve resource.
            return ProviderCostProfile(id: id, costClass: .trial, reserveOnly: true)
        case "groq", "groq-strong":
            return ProviderCostProfile(id: id, costClass: .free)
        case "gemini":
            return ProviderCostProfile(id: id, costClass: .free)
        case "openrouter":
            return ProviderCostProfile(id: id, costClass: .free)
        case "chatgpt-desktop":
            // The user's own subscription; no marginal API spend for ZiA.
            return ProviderCostProfile(id: id, costClass: .free)
        case let local where local.hasPrefix("mlx"):
            return ProviderCostProfile(id: id, costClass: .local)
        default:
            return ProviderCostProfile(id: id, costClass: .free)
        }
    }

    /// Stable-partition a provider chain by cost rank (free → reserve → paid →
    /// local), preserving relative order within each rank. Local models always
    /// end up last (resilience layer).
    static func normalizedByCost(_ providers: [any LLMProvider]) -> [any LLMProvider] {
        providers.enumerated()
            .sorted { lhs, rhs in
                let l = defaultProfile(for: lhs.element.id).costClass.rank
                let r = defaultProfile(for: rhs.element.id).costClass.rank
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
