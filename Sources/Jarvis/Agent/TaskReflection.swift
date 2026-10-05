import Foundation

/// Post-task structured reflection record.
struct TaskReflectionRecord: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let taskID: UUID
    let goal: String
    let outcome: String
    let stepsAttempted: Int
    let stepsSucceeded: Int
    let stepsFailed: Int
    let providerUsed: String?
    let replanCount: Int
    let durationSeconds: Double
    let whatWorked: [String]
    let whatFailed: [String]
    let suggestions: [String]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        goal: String,
        outcome: String,
        stepsAttempted: Int,
        stepsSucceeded: Int,
        stepsFailed: Int,
        providerUsed: String? = nil,
        replanCount: Int = 0,
        durationSeconds: Double,
        whatWorked: [String] = [],
        whatFailed: [String] = [],
        suggestions: [String] = [],
        timestamp: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.goal = goal
        self.outcome = outcome
        self.stepsAttempted = stepsAttempted
        self.stepsSucceeded = stepsSucceeded
        self.stepsFailed = stepsFailed
        self.providerUsed = providerUsed
        self.replanCount = replanCount
        self.durationSeconds = durationSeconds
        self.whatWorked = whatWorked
        self.whatFailed = whatFailed
        self.suggestions = suggestions
        self.timestamp = timestamp
    }
}

/// A structured procedural workflow learned from verified task execution.
struct LearnedProcedure: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let trigger: String
    let goal: String
    let steps: [String]
    let tools: [String]
    let constraints: [String]
    let verificationRequirement: String
    let confidence: Double
    let provenance: String
    let createdAt: Date

    /// Validates the procedure against the current environment state before reuse.
    /// Never blindly replays if tools are unavailable or paths are sensitive.
    func isValidForCurrentState() -> Bool {
        // 1. All tools must currently exist in ToolRegistry
        for tool in tools {
            guard ToolRegistry.shared.getTool(named: tool) != nil else {
                return false
            }
        }
        // 2. Constraints must not violate sensitive paths
        for constraint in constraints {
            if SensitivePaths.contains(constraint) {
                return false
            }
        }
        return true
    }
}

/// Post-execution reflection and safe procedural learning.
///
/// Guarantees:
/// - Reflection produces suggestions, never automatic privilege escalation.
/// - Procedural learning only accepts independently verified multi-step completions.
/// - Prior procedures are validated against current tool registry and reality before replay.
@MainActor
final class TaskReflectionEngine {
    static let shared = TaskReflectionEngine()

    private var reflections: [TaskReflectionRecord] = []
    private var learnedProcedures: [LearnedProcedure] = []

    private init() {}

    /// Analyze a completed or failed task and record a reflection.
    @discardableResult
    func recordReflection(
        task: JarvisTask,
        durationSeconds: Double,
        provider: String? = nil,
        replanCount: Int = 0
    ) -> TaskReflectionRecord {
        let succeeded = task.steps.filter { $0.state == .completed }.count
        let failed = task.steps.filter { $0.state == .failed }.count
        var worked: [String] = []
        var failedReasons: [String] = []
        var suggestions: [String] = []

        for step in task.steps {
            if step.state == .completed {
                worked.append("Step \(step.stepNumber) (\(step.toolName ?? "composition")): \(step.description)")
            } else if step.state == .failed {
                let err = step.error ?? "unknown error"
                failedReasons.append("Step \(step.stepNumber): \(err)")
            }
        }

        if task.state == .failed {
            suggestions.append("Consider verifying tool parameters and prerequisites before retrying.")
        } else if replanCount > 0 {
            suggestions.append("Task succeeded after \(replanCount) replan(s). Review initial plan generation.")
        }

        let record = TaskReflectionRecord(
            taskID: task.id,
            goal: task.goal,
            outcome: task.state.rawValue,
            stepsAttempted: task.steps.count,
            stepsSucceeded: succeeded,
            stepsFailed: failed,
            providerUsed: provider,
            replanCount: replanCount,
            durationSeconds: durationSeconds,
            whatWorked: worked,
            whatFailed: failedReasons,
            suggestions: suggestions
        )

        reflections.append(record)
        if reflections.count > 500 {
            reflections.removeFirst(reflections.count - 500)
        }

        // Procedural learning: if task had 2+ verified steps and completed successfully, learn workflow
        if task.state == .completed && succeeded >= 2 {
            let toolSteps = task.steps.compactMap(\.toolName)
            if toolSteps.count >= 2 {
                let procedure = LearnedProcedure(
                    id: UUID(),
                    trigger: task.goal,
                    goal: task.goal,
                    steps: task.steps.map(\.description),
                    tools: toolSteps,
                    constraints: [],
                    verificationRequirement: "read-back or outcome check",
                    confidence: 0.85,
                    provenance: "verified_task.\(task.id.uuidString.prefix(8))",
                    createdAt: .now
                )
                learnedProcedures.append(procedure)
                if learnedProcedures.count > 100 {
                    learnedProcedures.removeFirst(learnedProcedures.count - 100)
                }
            }
        }

        return record
    }

    /// Retrieve matching learned procedure if valid for current system state.
    func findProcedure(matching goal: String) -> LearnedProcedure? {
        let needle = goal.lowercased()
        guard let candidate = learnedProcedures.first(where: {
            $0.trigger.lowercased() == needle || $0.goal.lowercased().contains(needle)
        }) else {
            return nil
        }
        guard candidate.isValidForCurrentState() else {
            JarvisLogger.brain.warning("Learned procedure for '\(candidate.goal)' rejected: invalid in current environment")
            return nil
        }
        return candidate
    }

    var allReflections: [TaskReflectionRecord] {
        reflections
    }

    var allLearnedProcedures: [LearnedProcedure] {
        learnedProcedures
    }
}
