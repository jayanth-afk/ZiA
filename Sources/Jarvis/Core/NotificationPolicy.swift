import Foundation

enum NotificationImportance: Int, Sendable, Comparable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3

    static func < (lhs: NotificationImportance, rhs: NotificationImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Central notification policy. Decides WHETHER to notify (importance,
/// preference, throttle) and leaves delivery to `NotificationSender`. Never
/// spams: identical keys are throttled, low-importance events are suppressed,
/// and the user's completion/failure preferences are respected.
@MainActor
final class NotificationPolicy {
    static let shared = NotificationPolicy()

    /// Minimum interval between notifications sharing the same key.
    static let minimumInterval: TimeInterval = 30

    private var lastSent: [String: Date] = [:]

    private init() {}

    /// Deliver a notification if policy allows. Returns true when delivered.
    @discardableResult
    func notify(key: String, title: String, body: String,
                importance: NotificationImportance, now: Date = .now) -> Bool {
        guard importance > .low else { return false }

        let prefs = PreferenceStore.shared.current
        if key.hasPrefix("task.completed") && !prefs.notifyOnCompletion { return false }
        if key.hasPrefix("task.failed") && !prefs.notifyOnFailure { return false }

        prune(now: now)
        if let last = lastSent[key], now.timeIntervalSince(last) < Self.minimumInterval {
            return false
        }
        lastSent[key] = now
        NotificationSender.shared.sendNotification(title: title, body: body)
        JarvisLogger.app.info("Notification [\(importance.rawValue)] \(key)")
        return true
    }

    func taskCompleted(goal: String, verified: Bool) {
        notify(key: "task.completed", title: "Task complete",
               body: "\(String(goal.prefix(120)))" + (verified ? "" : " (unverified)"),
               importance: verified ? .normal : .high)
    }

    func taskFailed(goal: String, reason: String) {
        notify(key: "task.failed.\(String(goal.prefix(40)))", title: "Task failed",
               body: "\(String(goal.prefix(80))): \(String(reason.prefix(160)))",
               importance: .high)
    }

    func scheduleFired(title: String) {
        notify(key: "schedule.\(title)", title: "Scheduled task started",
               body: title, importance: .normal)
    }

    func providerDegraded(detail: String) {
        notify(key: "provider.degraded", title: "Intelligence degraded",
               body: detail, importance: .high)
    }

    func requiresAttention(taskID: String, reason: String) {
        notify(key: "task.attention.\(taskID)", title: "Zia needs your input",
               body: reason, importance: .critical)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-3600)
        lastSent = lastSent.filter { $0.value > cutoff }
    }
}
