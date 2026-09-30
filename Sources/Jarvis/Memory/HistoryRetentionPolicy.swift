import Foundation

/// Minimal deterministic storage-retention policy for the persisted
/// conversation archive (ConversationStore/SQLite).
///
/// STORAGE RETENTION ≠ INTELLIGENCE CONTEXT WINDOW:
/// The planner/DirectComposer context window (ConversationManager, 12 turns)
/// is deliberately tiny and independent. Retention never deletes anything
/// "because it fell out of the model context" — it bounds the SQLite archive
/// by AGE so storage cannot grow unboundedly, while a newest-message floor
/// guarantees the archive can never be emptied by policy (a long absence
/// must not wipe history).
///
/// Explicit semantics (deterministic, same inputs → same deletions):
/// - Horizon: messages strictly older than `maxAgeDays` are eligible for
///   deletion (default 30 days).
/// - Floor: the newest `floorMessages` messages are ALWAYS kept regardless
///   of age (default 50). Only `total − floor` oldest messages are ever
///   removed in one enforcement.
/// - Deletion is by timestamp only, oldest first; turn pairing and ordering
///   of survivors are untouched.
/// - Enforcement is an explicit startup maintenance step — never part of a
///   read/restore path, and never on the interaction hot path.
///
/// NOTE (decision left to product): 30 days is a deliberately conservative
/// default, not a product decision. Changing `maxAgeDays` (or disabling
/// enforcement) is a one-line change; no settings UI is built for it yet.
@MainActor
enum HistoryRetentionPolicy {
    /// Age horizon: messages older than this are deletion-eligible.
    static var maxAgeDays: Int = 30

    /// Newest-N messages that are never deleted, regardless of age.
    static var floorMessages: Int = 50

    /// Enforce the policy against ConversationStore. Returns the number of
    /// rows deleted (0 when the archive is within the floor).
    @discardableResult
    static func enforce(now: Date = .now) -> Int {
        let total = ConversationStore.shared.totalMessageCount
        guard total > floorMessages else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let deletable = total - floorMessages
        let deleted = ConversationStore.shared.deleteMessages(olderThan: cutoff, limit: deletable)
        if deleted > 0 {
            JarvisLogger.memory.info("History retention deleted \(deleted) message(s) older than \(self.maxAgeDays)d (floor \(self.floorMessages) kept)")
        }
        return deleted
    }
}
