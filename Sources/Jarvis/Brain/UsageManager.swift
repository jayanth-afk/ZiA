import Foundation

/// Tracks AI token usage and daily expenditures against configured budgets.
@MainActor
final class UsageManager {
    static let shared = UsageManager()

    private(set) var dailySpentUSD: Double = 0.0
    private(set) var totalTokensToday: Int = 0
    private var lastResetDate: Date = .now

    // Approximate cost per million tokens ($/1M)
    private let pricingPer1M: [String: (input: Double, output: Double)] = [
        "anthropic": (input: 3.0, output: 15.0),
        "openai": (input: 2.5, output: 10.0),
        "gemini": (input: 0.10, output: 0.40),
        "groq": (input: 0.59, output: 0.79),
        "mlx-local": (input: 0.0, output: 0.0)
    ]

    private init() {}

    // MARK: - Public API

    /// Record token usage for a provider and compute cost.
    func recordUsage(provider: String, usage: TokenUsage) {
        checkDailyReset()

        totalTokensToday += usage.totalTokens
        let rates = pricingPer1M[provider] ?? (input: 1.0, output: 2.0)
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
