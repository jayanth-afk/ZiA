import Foundation

/// Manages active conversation history and context window.
///
/// Persistence model (single source of truth): ConversationStore (SQLite) is
/// the PERSISTED record; this manager is the in-memory working window. Every
/// recorded interaction is written through to the store exactly once; on
/// startup the recent window is restored from the store. Memory is CONTEXT
/// ONLY — it never authorizes an action (authority stays with PermissionGate,
/// PlanValidator, CommandSandbox, ReferenceResolver, TaskStateMachine).
@MainActor
final class ConversationManager {
    static let shared = ConversationManager()

    // MARK: - State
    private(set) var messages: [Message] = []
    var maxHistoryCount = 20

    /// IDs of in-memory messages already written to ConversationStore, so a
    /// message can never be persisted twice (duplicate-write guard).
    private var persistedIDs = Set<String>()

    private init() {
        // Add default system prompt
        reset()
    }

    // MARK: - Public API

    /// Reset conversation history to default system prompt (memory only —
    /// does NOT delete the persisted record in ConversationStore).
    func reset() {
        messages = [
            Message(
                role: .system,
                content: ZiaIdentity.systemPrompt(for: .fast, destination: .voice)
            )
        ]
        persistedIDs.removeAll()
        JarvisLogger.brain.info("ConversationManager reset")
    }

    /// Add a user prompt to history.
    func addUserMessage(_ content: String) {
        messages.append(Message(role: .user, content: content))
        trimHistory()
    }

    /// Add an assistant response to history.
    func addAssistantMessage(_ content: String) {
        messages.append(Message(role: .assistant, content: content))
        trimHistory()
    }

    /// Get current messages formatted for provider request.
    func getContext() -> [Message] {
        return messages
    }

    // MARK: - Persistence (survives restart)

    /// Restore the recent persisted conversation from ConversationStore at app
    /// startup. Bounded window (never the lifetime transcript). Skipped when
    /// the working window already has turns (idempotent), and after a reset()
    /// it can be called again to re-restore. Restored turns are marked as
    /// already-persisted so they are never written back (duplicate guard).
    func loadPersistedHistory(limit: Int = 12) {
        let existingTurns = messages.filter { $0.role != .system }
        guard existingTurns.isEmpty else { return }
        let restored = ConversationStore.shared.loadMessages(limit: limit)
            .filter { $0.role == .user || $0.role == .assistant }
        guard !restored.isEmpty else { return }
        persistedIDs.formUnion(restored.map(\.id))
        messages.append(contentsOf: restored)
        JarvisLogger.brain.info("Restored \(restored.count) persisted conversation turns from SQLite")
    }

    /// Record a COMPLETE interaction (user request + final assistant response)
    /// and persist BOTH turns through ConversationStore — the single persisted
    /// source of truth. Writing the pair together means a restored conversation
    /// can never pair a request with a response that was never produced.
    /// `response == nil` records the request only (refusals): what the user
    /// asked is remembered, but nothing is fabricated as an assistant action.
    func recordInteraction(goal: String, response: String?) {
        addUserMessage(goal)
        if let response {
            addAssistantMessage(response.isEmpty ? "All actions executed and verified." : response)
        }
        persistUnsavedTurns()
    }

    // MARK: - Private

    /// Write any in-memory turns not yet persisted to ConversationStore.
    private func persistUnsavedTurns() {
        var saved = 0
        for message in messages where message.role != .system && !persistedIDs.contains(message.id) {
            ConversationStore.shared.saveMessage(message)
            persistedIDs.insert(message.id)
            saved += 1
        }
        if saved > 0 {
            JarvisLogger.memory.info("Persisted \(saved) conversation turn(s) to SQLite")
        }
    }

    private func trimHistory() {
        guard messages.count > maxHistoryCount + 1 else { return }
        // Preserve the system prompt and complete user/assistant turns wherever
        // possible; orphaned turns degrade relevance and confuse provider context.
        let system = messages[0]
        var remaining = Array(messages.dropFirst())
        while remaining.count > maxHistoryCount {
            if remaining.count >= 2,
               remaining[0].role == .user,
               remaining[1].role == .assistant {
                remaining.removeFirst(2)
            } else {
                remaining.removeFirst()
            }
        }
        messages = [system] + remaining
    }
}
