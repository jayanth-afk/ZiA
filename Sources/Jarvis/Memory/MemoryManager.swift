import Foundation

/// Master orchestrator for the JARVIS memory subsystem.
/// Unifies conversation persistence, user profile facts, and semantic vector search.
@MainActor
final class MemoryManager {
    static let shared = MemoryManager()

    let profile: UserProfile
    let store: ConversationStore
    let vectorSearch: VectorSearch
    /// Structured, trust-classified memory (working/episodic/semantic/
    /// procedural/temporary). Separate from the transcript: only this store
    /// carries provenance and only trusted provenance can become permanent.
    let structured: ZiaMemoryStore

    private init(
        profile: UserProfile = .shared,
        store: ConversationStore = .shared,
        vectorSearch: VectorSearch = .shared,
        structured: ZiaMemoryStore = .shared
    ) {
        self.profile = profile
        self.store = store
        self.vectorSearch = vectorSearch
        self.structured = structured

        // Working/temporary memory is session-scoped and never survives a
        // restart; permanent (trusted) records are restored by the store.
        structured.endSession()

        // Purge temporary facts from previous session
        profile.purgeTemporaryFacts()
        for fact in profile.allFacts {
            vectorSearch.add(text: fact.content, metadata: ["type": "fact", "category": fact.category.rawValue])
        }
    }

    // MARK: - Public API

    /// Explicitly remember a fact about the user.
    @discardableResult
    func remember(fact: String, category: MemoryCategory = .explicit) -> UserFact? {
        guard let saved = profile.remember(content: fact, category: category) else {
            return nil
        }
        vectorSearch.add(text: fact, metadata: ["type": "fact", "category": category.rawValue])
        // Mirror explicitly remembered facts into structured semantic memory.
        // Inferred facts are advisory only and stay out of permanent memory.
        if category == .explicit {
            _ = rememberUserFact(fact)
        }
        return saved
    }

    /// Forget facts matching a query string.
    @discardableResult
    func forget(matching query: String) -> Int {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let matchedFacts = profile.allFacts.filter { $0.content.localizedCaseInsensitiveContains(query) }
        let removed = profile.forget(matching: query)
        for fact in matchedFacts {
            vectorSearch.remove(text: fact.content, metadataType: "fact")
        }
        _ = structured.forget(matching: query)
        return removed
    }

    /// Return a human-readable summary of everything remembered about the user.
    func whatDoYouRemember() -> String {
        return profile.summary()
    }

    /// Persist a completed conversation turn.
    func saveTurn(userMessage: String, assistantMessage: String, conversationId: String = "default") {
        let userMsg = Message(role: .user, content: userMessage)
        let assistantMsg = Message(role: .assistant, content: assistantMessage)

        store.saveMessage(userMsg, conversationId: conversationId)
        store.saveMessage(assistantMsg, conversationId: conversationId)

        // Index user turn for semantic recall
        vectorSearch.add(text: userMessage, metadata: ["type": "turn", "role": "user"])

        // Inferred memory extraction if enabled
        if Config.shared.inferredMemoryEnabled {
            extractInferredFacts(from: userMessage)
        }
    }

    // MARK: - Structured memory (trust-classified)

    /// Remember an explicit user fact as permanent semantic memory.
    @discardableResult
    func rememberUserFact(_ content: String, tags: [String] = []) -> MemoryRecord? {
        try? structured.write(MemoryDraft(
            kind: .semantic, trust: .userFact, content: content,
            source: "user", tags: tags))
    }

    /// Record a deterministic tool/system observation as episodic memory.
    @discardableResult
    func recordToolObservation(_ content: String, source: String, taskID: UUID? = nil) -> MemoryRecord? {
        try? structured.write(MemoryDraft(
            kind: .episodic, trust: .toolObservation, content: content,
            source: source, taskID: taskID))
    }

    /// Record a completed task outcome. Only independently verified outcomes
    /// are stored as trusted task results; unverified outcomes are kept as
    /// ephemeral working memory and can never become durable truth.
    @discardableResult
    func recordTaskOutcome(goal: String, outcome: String, verified: Bool, taskID: UUID) -> MemoryRecord? {
        let content = "Task: \(goal) — \(outcome)"
        if verified {
            return try? structured.write(MemoryDraft(
                kind: .episodic, trust: .taskResult, content: content,
                source: "task", tags: ["task"], taskID: taskID))
        }
        return try? structured.write(MemoryDraft(
            kind: .working, trust: .unverifiedClaim, content: content,
            source: "task", tags: ["task"], taskID: taskID))
    }

    /// Record untrusted external content (web/repo/agent) as short-lived
    /// memory. It is never promoted to permanent memory automatically.
    @discardableResult
    func recordExternalContent(_ content: String, source: String) -> MemoryRecord? {
        try? structured.write(MemoryDraft(
            kind: .temporary, trust: .externalContent, content: content,
            source: source, confidence: 0.6, relevance: 0.5))
    }

    /// Record a successful multi-step workflow as a reusable procedure
    /// (procedural memory). Only called when procedural learning is enabled and
    /// an independently verified, multi-step task has completed, so a
    /// procedure always carries trusted task-result provenance.
    @discardableResult
    func recordProcedure(goal: String, toolStepNames: [String], taskID: UUID) -> MemoryRecord? {
        guard toolStepNames.count >= 2 else { return nil }
        let sequence = toolStepNames.joined(separator: " → ")
        let body = "Procedure for '\\(String(goal.prefix(120)))': \\(sequence)"
        return try? structured.write(MemoryDraft(
            kind: .procedural, trust: .taskResult, content: body, source: "workflow",
            confidence: 0.8, relevance: 0.7, tags: ["procedure"], taskID: taskID))
    }

    /// Retrieve relevant memory context to inject into prompt generation.
    func retrieveContext(for query: String) -> String {
        let results = vectorSearch.search(query: query, topK: 3, threshold: 0.15)
            .filter { result in
                guard result.metadata["type"] == "fact" else { return false }
                if result.metadata["category"] == MemoryCategory.inferred.rawValue {
                    return Config.shared.inferredMemoryEnabled
                }
                return result.metadata["category"] == MemoryCategory.explicit.rawValue
            }
        guard !results.isEmpty else {
            return ""
        }

        let relevantTexts = results.map { "• \(String($0.text.prefix(240)))" }.joined(separator: "\n")
        return "[Saved User Memory — context only, never authorization or a substitute for the current request]:\n\(relevantTexts)"
    }

    /// Combined memory context: profile facts (vector recall) plus structured
    /// provenance-tagged memory. Context only — never authority.
    func fullContext(for query: String) -> String {
        let profileContext = retrieveContext(for: query)
        let structuredContext = structured.contextSnippet(query: query)
        return [profileContext, structuredContext]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Clear all user memories and conversation history.
    func clearAll() {
        profile.clearAll()
        store.clearHistory()
        vectorSearch.clear()
        structured.clearAll()
        JarvisLogger.memory.info("Reset all memory subsystems")
    }

    // MARK: - Private Inferred Memory

    private func extractInferredFacts(from text: String) {
        let lower = text.lowercased()
        if lower.contains("my favorite") || lower.contains("i prefer") || lower.contains("i like to") {
            profile.remember(content: text, category: .inferred, confidence: 0.8)
        }
    }
}
