import Foundation

/// One Canonical ZiA State.
///
/// Fundamental Architectural Principle:
/// ZiA is stateful. LLMs are stateless reasoning workers.
///
/// This state represents the single authoritative source of truth owned by ZiA.
/// Reasoning models receive compiled, read-only slices tailored to their tier,
/// and never own the canonical state.
@MainActor
final class ZiACanonicalState: ObservableObject {
    static let shared = ZiACanonicalState()

    // MARK: - Identity & Personality
    let assistantName: String = ZiaIdentity.assistantName
    let defaultSystemPrompt: String = ZiaIdentity.systemPrompt(for: .fast, destination: .visual)

    // MARK: - Working Memory
    /// Short-lived context for active reasoning (current hypothesis, active files, uncommitted observations).
    @Published private(set) var activeHypothesis: String?
    @Published private(set) var activeFiles: [String] = []
    @Published private(set) var workingObservations: [String] = []

    // MARK: - Conversational State
    @Published private(set) var currentTopic: String?
    @Published private(set) var conversationMode: String = "general"

    private init() {}

    // MARK: - State Mutation (ZiA Authoritative Operations)

    /// Update current working memory with fresh observations or hypotheses.
    func updateWorkingContext(hypothesis: String? = nil, activeFiles: [String]? = nil, observation: String? = nil) {
        if let hypothesis { self.activeHypothesis = hypothesis }
        if let activeFiles { self.activeFiles = activeFiles }
        if let observation {
            self.workingObservations.append(observation)
            if self.workingObservations.count > 10 {
                self.workingObservations.removeFirst()
            }
        }
    }

    /// Clear transient working memory when a task or session completes.
    func clearWorkingContext() {
        self.activeHypothesis = nil
        self.activeFiles.removeAll()
        self.workingObservations.removeAll()
        self.currentTopic = nil
    }

    /// Record an authoritative decision in memory.
    @discardableResult
    func recordDecision(
        _ content: String,
        source: String = "conversation",
        level: MemoryRetentionLevel = .important,
        supersedes: UUID? = nil
    ) throws -> MemoryRecord {
        let draft = MemoryDraft(
            kind: .episodic,
            trust: .taskResult,
            content: content,
            source: source,
            retentionLevel: level,
            supersedesID: supersedes
        )
        return try ZiaMemoryStore.shared.write(draft)
    }

    /// Authoritative snapshot of the current state for context compilation.
    func snapshot(goal: String, taskID: UUID? = nil) -> Snapshot {
        let activeTask: JarvisTask?
        if let taskID {
            activeTask = TaskStateMachine.shared.getTask(id: taskID)
        } else {
            activeTask = TaskStateMachine.shared.activeTasks.first
        }

        let history = ConversationManager.shared.getContext()
            .filter { $0.role == .user || $0.role == .assistant }

        return Snapshot(
            goal: goal,
            activeTask: activeTask,
            conversationTurns: history,
            activeHypothesis: activeHypothesis,
            activeFiles: activeFiles,
            workingObservations: workingObservations,
            preferences: PreferenceStore.shared.current
        )
    }

    struct Snapshot: Sendable {
        let goal: String
        let activeTask: JarvisTask?
        let conversationTurns: [Message]
        let activeHypothesis: String?
        let activeFiles: [String]
        let workingObservations: [String]
        let preferences: UserPreferences
    }
}
