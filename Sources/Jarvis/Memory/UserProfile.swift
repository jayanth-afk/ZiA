import Foundation

/// Memory classification category adhering to user privacy controls.
enum MemoryCategory: String, Sendable, Codable, CaseIterable {
    case explicit = "EXPLICIT"   // User explicitly said "remember this" — always retained
    case inferred = "INFERRED"   // Extracted from conversation context — user can disable
    case temporary = "TEMPORARY" // Session-only, automatically purged on app restart
}

/// A discrete fact or preference remembered about the user.
struct UserFact: Identifiable, Sendable, Codable {
    let id: UUID
    let content: String
    let category: MemoryCategory
    let confidence: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        content: String,
        category: MemoryCategory = .explicit,
        confidence: Double = 1.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

/// User profile storing user preferences, facts, and memories.
/// Runs on MainActor with direct access to AppState and Config.
@MainActor
final class UserProfile {
    static let shared = UserProfile()

    private var facts: [UUID: UserFact] = [:]

    private init() {
        facts = Dictionary(
            uniqueKeysWithValues: ConversationStore.shared.loadUserFacts().map { ($0.id, $0) })
    }

    // MARK: - Public API

    /// Remember a new fact about the user with category gating.
    @discardableResult
    func remember(content: String, category: MemoryCategory = .explicit, confidence: Double = 1.0) -> UserFact? {
        // If inferred memory is disabled, do not retain inferred facts
        if category == .inferred && !Config.shared.inferredMemoryEnabled {
            JarvisLogger.memory.info("Inferred memory disabled in Config; skipping fact: '\(content)'")
            return nil
        }

        let fact = UserFact(content: content, category: category, confidence: confidence)
        facts[fact.id] = fact
        if category != .temporary {
            ConversationStore.shared.saveUserFact(fact)
        }
        JarvisLogger.memory.info("Remembered [\(category.rawValue)]: '\(content)'")
        return fact
    }

    /// Forget a specific fact by ID.
    @discardableResult
    func forget(id: UUID) -> Bool {
        let removed = facts.removeValue(forKey: id) != nil
        if removed {
            ConversationStore.shared.deleteUserFact(id: id)
            JarvisLogger.memory.info("Forgot fact with ID: \(id)")
        }
        return removed
    }

    /// Forget all facts containing a matching substring.
    @discardableResult
    func forget(matching query: String) -> Int {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let lower = query.lowercased()
        let matchingIds = facts.values
            .filter { $0.content.lowercased().contains(lower) }
            .map { $0.id }

        for id in matchingIds {
            facts.removeValue(forKey: id)
            ConversationStore.shared.deleteUserFact(id: id)
        }

        JarvisLogger.memory.info("Forgot \(matchingIds.count) facts matching '\(query)'")
        return matchingIds.count
    }

    /// Retrieve all stored facts.
    var allFacts: [UserFact] {
        facts.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Retrieve facts filtered by category.
    func facts(in category: MemoryCategory) -> [UserFact] {
        return facts.values.filter { $0.category == category }
    }

    /// Purges all temporary (session-only) facts. Called on app launch/restart.
    func purgeTemporaryFacts() {
        facts = facts.filter { $0.value.category != .temporary }
        JarvisLogger.memory.info("Purged temporary session memories")
    }

    /// Reset all memories.
    func clearAll() {
        facts.removeAll()
        ConversationStore.shared.deleteAllUserFacts()
        JarvisLogger.memory.info("Cleared all user profile memories")
    }

    /// Formats all stored memories into a human-readable list for "What do you remember about me?".
    func summary() -> String {
        let currentFacts = allFacts
        guard !currentFacts.isEmpty else {
            return "I don't have any saved facts about you yet."
        }

        var lines = ["Here is what I remember about you:"]
        for fact in currentFacts {
            lines.append("• [\(fact.category.rawValue)] \(fact.content)")
        }
        return lines.joined(separator: "\n")
    }
}
