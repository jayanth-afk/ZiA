import Foundation

/// Manages the PREVIEW -> COMMIT lifecycle for destructive actions in JARVIS.
/// Guarantees that irreversible operations (e.g. empty trash, sleep mac) cannot be
/// triggered inadvertently by single-shot spoken or typed commands.
final class DestructiveActionManager: @unchecked Sendable {
    static let shared = DestructiveActionManager()

    struct PendingAction: Sendable {
        let id: String
        let intent: String
        let previewDescription: String
        let createdAt: Date
        let action: @Sendable () async throws -> String
    }

    private let lock = NSLock()
    private var _pendingAction: PendingAction?

    var pendingAction: PendingAction? {
        lock.lock()
        defer { lock.unlock() }
        return _pendingAction
    }

    private init() {}

    /// Register a pending destructive action and return its user-facing PREVIEW description.
    @discardableResult
    func requestPreview(
        intent: String,
        description: String,
        action: @escaping @Sendable () async throws -> String
    ) -> String {
        let id = UUID().uuidString
        let pending = PendingAction(
            id: id,
            intent: intent,
            previewDescription: description,
            createdAt: Date(),
            action: action
        )
        lock.lock()
        _pendingAction = pending
        lock.unlock()
        JarvisLogger.security.warning("Destructive action preview created for intent: '\(intent)'")
        return "PREVIEW: \(description) Say 'confirm \(intent)' or 'commit' to execute, or 'cancel' to abort."
    }

    private func popPendingAction(matching intent: String?) throws -> (action: @Sendable () async throws -> String, intent: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = _pendingAction else {
            throw JarvisError.actionFailed(action: intent ?? "destructive", reason: "No pending destructive action to commit.")
        }

        if let expected = intent,
           !pending.intent.localizedCaseInsensitiveContains(expected) &&
           !expected.localizedCaseInsensitiveContains(pending.intent) {
            throw JarvisError.actionFailed(action: pending.intent, reason: "Pending action '\(pending.intent)' does not match confirmation for '\(expected)'.")
        }

        // Enforce 60-second confirmation window
        guard Date().timeIntervalSince(pending.createdAt) < 60.0 else {
            _pendingAction = nil
            throw JarvisError.actionFailed(action: pending.intent, reason: "Confirmation window expired (60s limit).")
        }

        let executable = pending.action
        let targetIntent = pending.intent
        _pendingAction = nil
        return (executable, targetIntent)
    }

    /// Explicitly commit and execute the pending destructive action.
    func commit(intent: String? = nil) async throws -> String {
        let (executable, targetIntent) = try popPendingAction(matching: intent)
        JarvisLogger.security.info("Destructive action committed: '\(targetIntent)'")
        return try await executable()
    }

    /// Check if a destructive intent has an active pending confirmation within the 60-second window.
    func isConfirmed(intent: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = _pendingAction else { return false }
        guard Date().timeIntervalSince(pending.createdAt) < 60.0 else {
            _pendingAction = nil
            return false
        }
        let cleanIntent = intent.hasSuffix(".commit") ? String(intent.dropLast(".commit".count)) : intent
        return pending.intent.localizedCaseInsensitiveContains(cleanIntent) ||
               cleanIntent.localizedCaseInsensitiveContains(pending.intent)
    }

    /// Cancel any pending destructive action.
    @discardableResult
    func cancel() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let pending = _pendingAction {
            let intent = pending.intent
            _pendingAction = nil
            JarvisLogger.security.info("Destructive action cancelled: '\(intent)'")
            return "Cancelled pending action: \(intent)."
        }
        return "No pending destructive action."
    }
}
