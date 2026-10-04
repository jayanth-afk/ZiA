import Foundation

/// A compact, task-oriented context package. It contains only what is relevant
/// to the current goal — never the whole transcript, never credentials, and
/// never memory that is merely present but irrelevant.
struct ContextPackage: Sendable, Equatable {
    var goal: String
    var constraints: [String] = []
    var taskState: String?
    var memory: [String] = []
    var failures: [String] = []
    var evidence: [String] = []
    var artifacts: [String] = []

    var isEmpty: Bool {
        taskState == nil && memory.isEmpty && failures.isEmpty && evidence.isEmpty && artifacts.isEmpty
    }

    /// Render a deterministic, bounded text package. Sections that carry no
    /// content are omitted entirely so a simple turn stays cheap.
    func render(maxCharacters: Int = 4_000) -> String {
        var lines: [String] = []
        lines.append("GOAL: \(goal)")
        if !constraints.isEmpty {
            lines.append("CONSTRAINTS: " + constraints.joined(separator: "; "))
        }
        if let taskState {
            lines.append("CURRENT TASK: \(taskState)")
        }
        if !memory.isEmpty {
            lines.append("RELEVANT MEMORY (context only):")
            lines.append(contentsOf: memory.map { "- \($0)" })
        }
        if !evidence.isEmpty {
            lines.append("VERIFIED EVIDENCE:")
            lines.append(contentsOf: evidence.map { "- \($0)" })
        }
        if !failures.isEmpty {
            lines.append("KNOWN FAILURES:")
            lines.append(contentsOf: failures.map { "- \($0)" })
        }
        if !artifacts.isEmpty {
            lines.append("ARTIFACTS:")
            lines.append(contentsOf: artifacts.map { "- \($0)" })
        }
        let rendered = lines.joined(separator: "\n")
        guard rendered.count > maxCharacters, maxCharacters > 0 else { return rendered }
        return String(rendered.prefix(maxCharacters))
    }
}

/// Assembles context packages for complex work. Read-only: it consults
/// authoritative task state, trust-classified memory, and the artifact
/// registry, and never mutates any of them.
@MainActor
final class ContextEngine {
    static let shared = ContextEngine()

    private init() {}

    func assemble(goal: String, taskID: UUID? = nil, memoryLimit: Int = 5) -> ContextPackage {
        var package = ContextPackage(goal: goal)

        // Task state — authoritative, never inferred from the transcript.
        let task = resolveTask(taskID: taskID, goal: goal)
        if let task {
            package.taskState = describe(task)
            package.constraints = ["Task is \(task.state.rawValue) with \(task.steps.count) step(s)."]
            for step in task.steps {
                if let error = step.error, !error.isEmpty {
                    package.failures.append("Step \(step.stepNumber): \(String(error.prefix(200)))")
                }
                if step.verification == .failed || step.verification == .inconclusive || step.verification == .unavailable {
                    package.failures.append("Step \(step.stepNumber) verification \(step.verification!.rawValue)")
                }
            }
            for record in task.resolutionRecords where record.verification == .passed {
                package.evidence.append("Step \(record.stepNumber) (\(record.toolName)): \(String(record.rawOutput.prefix(160)))")
            }
        }

        // Trusted memory only — memory never authorizes; untrusted records are
        // excluded from the package so they cannot influence durable behavior.
        package.memory = ZiaMemoryStore.shared
            .retrieveTrusted(query: goal, limit: memoryLimit)
            .map { String($0.content.prefix(200)) }

        if let task {
            package.artifacts = ArtifactRegistry.shared.artifacts(forTask: task.id).map {
                "\($0.path) (\($0.verified ? "verified" : "unverified"))"
            }
        }

        return package
    }

    private func resolveTask(taskID: UUID?, goal: String) -> JarvisTask? {
        if let taskID, let task = TaskStateMachine.shared.getTask(id: taskID) {
            return task
        }
        let active = TaskStateMachine.shared.activeTasks
        if active.count == 1 { return active.first }
        // Prefer an active task whose goal matches; otherwise the most recent.
        if let match = active.first(where: { $0.goal == goal }) { return match }
        return active.max { $0.updatedAt < $1.updatedAt }
    }

    private func describe(_ task: JarvisTask) -> String {
        let state = task.state.rawValue.lowercased()
        let verified = task.steps.filter { $0.verification == .passed }.count
        return "\"\(String(task.goal.prefix(160)))\" (\(state); \(verified)/\(task.steps.count) steps verified)"
    }
}
