import Foundation

/// Tracks AI token usage and daily expenditures against configured budgets.
@MainActor
final class UsageManager {
    static let shared = UsageManager()

    private(set) var dailySpentUSD: Double = 0.0
    private(set) var totalTokensToday: Int = 0
    private var lastResetDate: Date = .now

    /// Cost per million tokens ($/1M), resolved by the provider's *runtime* id.
    ///
    /// Rule 10: never invent a price. Providers whose published price we do not
    /// actually know contribute 0 to the spend total rather than a fabricated
    /// number. Local inference has no marginal cost.
    private func rates(for provider: String) -> (input: Double, output: Double) {
        if provider.hasPrefix("mlx") { return (0, 0) }
        switch provider {
        case "anthropic": return (3.0, 15.0)
        case "openai": return (2.5, 10.0)
        case "gemini": return (0.10, 0.40)
        case "groq", "groq-strong": return (0.59, 0.79)
        // Priced only from known figures; otherwise unknown (0, not invented).
        // Trial/promotional (cerebras), entitlement (sambanova), free-model
        // (openrouter) and the user's own desktop app (chatgpt-desktop) have no
        // dependable per-token ZiA cost here.
        default: return (0, 0)
        }
    }

    private init() {}

    // MARK: - Public API

    /// Record token usage for a provider and compute cost.
    func recordUsage(provider: String, usage: TokenUsage) {
        checkDailyReset()

        totalTokensToday += usage.totalTokens
        let rates = rates(for: provider)
        let cost = (Double(usage.promptTokens) / 1_000_000.0 * rates.input) +
                   (Double(usage.completionTokens) / 1_000_000.0 * rates.output)

        dailySpentUSD += cost
        let currentTotal = self.dailySpentUSD
        JarvisLogger.brain.info("Usage: \(usage.totalTokens) tokens from \(provider) (Cost: $\(String(format: "%.4f", cost)), Day: $\(String(format: "%.4f", currentTotal)))")

        if isBudgetExceeded() {
            JarvisLogger.security.warning("Daily budget exceeded! Limit: $\(Config.shared.dailyBudgetUSD), Spent: $\(currentTotal)")
        }
    }

    /// Check if daily expenditure has exceeded configured limit.
    func isBudgetExceeded() -> Bool {
        checkDailyReset()
        return dailySpentUSD >= Config.shared.dailyBudgetUSD
    }

    /// Reset daily usage counters.
    func resetDailyUsage() {
        dailySpentUSD = 0.0
        totalTokensToday = 0
        lastResetDate = .now
    }

    // MARK: - Private

    private func checkDailyReset() {
        if !Calendar.current.isDateInToday(lastResetDate) {
            resetDailyUsage()
        }
    }
}
