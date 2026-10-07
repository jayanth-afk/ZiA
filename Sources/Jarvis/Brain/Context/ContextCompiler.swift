import Foundation

/// Compiles Canonical ZiA State into the optimal context representation for a given BrainTier.
///
/// Fundamental principle:
/// ZiA owns the canonical state.
/// Models receive a model-specific, budget-bounded compiled context.
/// Semantic meaning is preserved; only the representation and token budget change.
@MainActor
final class ContextCompiler {
    static let shared = ContextCompiler()

    private init() {}

    /// Compile a complete message payload for model dispatch.
    func compile(
        goal: String,
        tier: BrainTier,
        destination: OutputDestination = .visual,
        taskID: UUID? = nil,
        environment: TaskEnvironmentContext? = nil,
        observations: [String] = []
    ) -> [Message] {
        let snapshot = ZiACanonicalState.shared.snapshot(goal: goal, taskID: taskID)
        let systemPrompt = ZiaIdentity.systemPrompt(for: tier, destination: destination)

        var messages: [Message] = []
        messages.append(Message(role: .system, content: systemPrompt))

        // Deterministic / reflex requires no compiled context
        if tier == .reflex {
            messages.append(Message(role: .user, content: goal))
            return messages
        }

        let maxChars = tier.maxContextCharacters
        let memoryLimit = tier.memoryLimit

        // 1. Retrieved trusted memories (never authorization; context only)
        let memories = ZiaMemoryStore.shared.retrieveTrusted(query: goal, limit: memoryLimit)
        var contextBlocks: [String] = []

        if !memories.isEmpty {
            var memBlock = "RELEVANT MEMORY (context only; do not contradict current request):\n"
            for m in memories {
                memBlock += "- [\(m.kind.rawValue)/\(m.trust.label)] \(m.content)\n"
            }
            contextBlocks.append(memBlock.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. Project & Environment context for strong / deep reasoning
        if tier == .strong || tier == .deep {
            let env = environment ?? TaskEnvironmentContext.captureLive()
            if let app = env.currentApp, !app.isEmpty, app != "Jarvis", app != "ZiA", app != "ChatGPT" {
                contextBlocks.append("Active application: \(app)")
            }
            let project = ProjectInspector.inspect(root: FileManager.default.currentDirectoryPath)
            if project.isProject {
                contextBlocks.append("Project: \(project.summary)")
            }
        }

        // 3. Task state & verified evidence
        if let task = snapshot.activeTask {
            var taskDesc = "CURRENT TASK: \"\(task.goal)\" (state: \(task.state.rawValue))\n"
            let verifiedSteps = task.steps.filter { $0.verification == .passed }
            if !verifiedSteps.isEmpty {
                taskDesc += "Verified completed steps: \(verifiedSteps.count)/\(task.steps.count)\n"
            }
            let failedSteps = task.steps.filter { $0.error != nil }
            for f in failedSteps {
                if let err = f.error {
                    taskDesc += "- Step \(f.stepNumber) failed: \(String(err.prefix(120)))\n"
                }
            }
            contextBlocks.append(taskDesc.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 4. Working observations
        let allObservations = snapshot.workingObservations + observations
        if !allObservations.isEmpty {
            let obsBlock = "OBSERVED RESULTS:\n" + allObservations.suffix(3).map { "- \(String($0.prefix(160)))" }.joined(separator: "\n")
            contextBlocks.append(obsBlock)
        }

        // 5. Recent conversation turns (bounded by tier)
        let turnBudget: Int
        switch tier {
        case .reflex: turnBudget = 0
        case .fast, .localFallback: turnBudget = 4
        case .strong: turnBudget = 8
        case .deep: turnBudget = 16
        }

        let relevantHistory = Array(snapshot.conversationTurns.suffix(turnBudget))
        for msg in relevantHistory {
            messages.append(msg)
        }

        // 6. User prompt with prepended context block
        var userContent = ""
        if !contextBlocks.isEmpty {
            let combinedContext = contextBlocks.joined(separator: "\n\n")
            // Ensure context does not exceed tier character budget
            let boundedContext = String(combinedContext.prefix(maxChars))
            userContent = "[Context]\n\(boundedContext)\n\n[Request]\n\(goal)"
        } else {
            userContent = goal
        }

        messages.append(Message(role: .user, content: userContent))
        return messages
    }
}
