import Foundation

/// A thread-safe rolling latency estimator. `ChatGPTDesktopProvider` is an
/// actor whose `currentLatencyMs` must be `nonisolated`, so the measured samples
/// live here rather than in isolated state.
final class ChatGPTBrainLatency: @unchecked Sendable {
    static let shared = ChatGPTBrainLatency(fallbackMs: 1200, capacity: 20)

    private let lock = NSLock()
    private var samples: [Int] = []
    private let capacity: Int
    private let fallbackMs: Int

    init(fallbackMs: Int, capacity: Int) {
        self.fallbackMs = fallbackMs
        self.capacity = capacity
    }

    func record(_ ms: Int) {
        guard ms >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        samples.append(ms)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Median of recorded samples, or the fallback guess when nothing is measured.
    var median: Int {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return fallbackMs }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
    }
}

/// Opt-in configuration and local usage accounting for the ChatGPT brain.
///
/// The brain is **OFF by default**: no request leaves the machine until the user
/// turns it on AND an Agent Bridge API key is configured.
///
/// The flag lives in `UserDefaults` (not the `@MainActor` `PreferenceStore`) so a
/// provider availability probe can read it **without a MainActor hop** — health
/// probes run while the main runloop may be pumped, and awaiting MainActor there
/// is a known deadlock hazard in this codebase.
///
/// Usage is personal, user-initiated, human-scale only — never bulk or
/// background. `dailySoftCap` bounds a single day's requests and is shown to the
/// user in Settings.
enum ChatGPTBrain {
    /// Deadline for the first streamed token before falling through to the next provider.
    static let firstTokenDeadlineSeconds: TimeInterval = 15
    /// Total deadline for a single ChatGPT turn.
    static let totalDeadlineSeconds: TimeInterval = 60
    /// Daily soft cap for human-scale, user-initiated use.
    static let dailySoftCap = 50

    private static let allowKey = "jarvis.chatgpt.allowBrain"
    private static let countKey = "jarvis.chatgpt.requestsToday"
    private static let dayKey = "jarvis.chatgpt.requestsDay"

    /// "Allow ChatGPT as a brain" — DEFAULT OFF.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: allowKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowKey) }
    }

    /// Requests sent to ChatGPT today (local counter, resets when the day changes).
    static func requestsToday(now: Date = .now, calendar: Calendar = .current) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: dayKey) == dayString(now, calendar: calendar) else { return 0 }
        return defaults.integer(forKey: countKey)
    }

    /// Record one request and return the new count for today.
    @discardableResult
    static func recordRequest(now: Date = .now, calendar: Calendar = .current) -> Int {
        let defaults = UserDefaults.standard
        let day = dayString(now, calendar: calendar)
        let current = defaults.string(forKey: dayKey) == day ? defaults.integer(forKey: countKey) : 0
        let next = current + 1
        defaults.set(day, forKey: dayKey)
        defaults.set(next, forKey: countKey)
        return next
    }

    /// Whether the daily soft cap has been reached.
    static func isDailyCapReached(now: Date = .now, calendar: Calendar = .current) -> Bool {
        requestsToday(now: now, calendar: calendar) >= dailySoftCap
    }

    /// A user-facing status line for Settings, with the exact reason when the
    /// brain cannot answer.
    static func statusLine(availability: ProviderAvailability, transport: String?) async -> String {
        if !isEnabled {
            return "Off — turn on to let ChatGPT answer when a request needs deep reasoning."
        }
        switch availability {
        case .available:
            let used = requestsToday()
            let via = transport.map { " via \($0)" } ?? ""
            return "Available\(via) · \(used)/\(dailySoftCap) requests today"
        case .unverified(let reason):
            return "Not verified — \(reason)"
        case .unavailable(let reason):
            return "Unavailable — \(reason)"
        }
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
