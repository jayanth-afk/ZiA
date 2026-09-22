import Foundation

/// Master orchestrator for the JARVIS memory subsystem.
/// Unifies conversation persistence, user profile facts, and semantic vector search.
@MainActor
final class MemoryManager {
    static let shared = MemoryManager()

    let profile: UserProfile
    let store: ConversationStore
    let vectorSearch: VectorSearch

    private init(
        profile: UserProfile = .shared,
        store: ConversationStore = .shared,
        vectorSearch: VectorSearch = .shared
    ) {
        self.profile = profile
        self.store = store
        self.vectorSearch = vectorSearch

        // Purge temporary facts from previous session
        profile.purgeTemporaryFacts()
    }

    // MARK: - Public API

    /// Explicitly remember a fact about the user.
    @discardableResult
    func remember(fact: String, category: MemoryCategory = .explicit) -> UserFact? {
        guard let saved = profile.remember(content: fact, category: category) else {
            return nil
        }
        vectorSearch.add(text: fact, metadata: ["type": "fact", "category": category.rawValue])
        return saved
    }

    /// Forget facts matching a query string.
    @discardableResult
    func forget(matching query: String) -> Int {
        return profile.forget(matching: query)
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

    /// Retrieve relevant memory context to inject into prompt generation.
    func retrieveContext(for query: String) -> String {
        let results = vectorSearch.search(query: query, topK: 2, threshold: 0.15)
        guard !results.isEmpty else {
            return ""
        }

        let relevantTexts = results.map { "• \($0.text)" }.joined(separator: "\n")
        return "\n[Relevant Long-Term Memories]:\n\(relevantTexts)\n"
    }

    /// Clear all user memories and conversation history.
    func clearAll() {
        profile.clearAll()
        store.clearHistory()
        vectorSearch.clear()
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
