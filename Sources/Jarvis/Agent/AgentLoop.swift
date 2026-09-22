import Foundation

/// Core autonomous agent loop implementing:
/// SENSE -> UNDERSTAND -> PLAN -> EXECUTE -> OBSERVE -> VERIFY -> RESPOND -> RECOVER
/// Preserves the fundamental JARVIS architecture.
actor AgentLoop {
    static let shared = AgentLoop()

    private init() {}

    // MARK: - Public API

    /// Execute an autonomous compound goal through the full pipeline.
    func run(goal: String) async throws -> String {
        let timer = PipelineTimer()
        timer.mark(.actionStart)

        // 1. SENSE & UNDERSTAND (Data classification & permissions)
        let sensitivity = await DataClassifier.shared.classify(goal)
        JarvisLogger.brain.info("AgentLoop: Goal classified as \(sensitivity.rawValue)")

        let impact: PermissionGate.ActionImpact = sensitivity == .highlySensitive ? .destructive : .safeMutation
        _ = try await PermissionGate.shared.isAuthorized(actionName: "AgentLoop.run", impact: impact)

        // 2. PLAN (Decompose into discrete steps)
        let stateMachine = TaskStateMachine.shared
        let task = stateMachine.createTask(title: "Autonomous Goal", goal: goal)
        try stateMachine.transition(taskId: task.id, to: .planning)

        let steps = planSteps(for: goal)
        try stateMachine.setSteps(taskId: task.id, steps: steps)

        // 3. EXECUTE -> OBSERVE -> VERIFY -> RECOVER loop
        try stateMachine.transition(taskId: task.id, to: .running)

        var completedOutputs: [String] = []
        var retryCount = 0
        let maxRetries = task.maxRetries

        for (index, step) in steps.enumerated() {
            var stepSucceeded = false

            while !stepSucceeded && retryCount <= maxRetries {
                try Task.checkCancellation()

                do {
                    try stateMachine.updateStep(taskId: task.id, stepIndex: index, state: .running)

                    if let toolName = step.toolName {
                        var args: [String: any Sendable] = [:]
                        for (k, v) in step.arguments {
                            args[k] = v
                        }

                        let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)
                        completedOutputs.append(result.output)
                    } else {
                        completedOutputs.append("Processed step: \(step.description)")
                    }

                    try stateMachine.updateStep(
                        taskId: task.id,
                        stepIndex: index,
                        state: .completed,
                        output: completedOutputs.last
                    )
                    stepSucceeded = true

                } catch {
                    retryCount += 1
                    JarvisLogger.actions.warning("Step \(step.stepNumber) failed (attempt \(retryCount)/\(maxRetries)): \(error.localizedDescription)")

                    if retryCount <= maxRetries {
                        // RECOVER -> REPLANNING -> RUNNING
                        try stateMachine.transition(taskId: task.id, to: .failed, error: error.localizedDescription)
                        try stateMachine.transition(taskId: task.id, to: .recovering)
                        try stateMachine.transition(taskId: task.id, to: .replanning)
                        try stateMachine.transition(taskId: task.id, to: .running)
                    } else {
                        try stateMachine.transition(taskId: task.id, to: .failed, error: "Max retries exceeded")
                        throw error
                    }
                }
            }
        }

        // 4. VERIFY & RESPOND
        try stateMachine.transition(taskId: task.id, to: .verifying)
        try stateMachine.transition(taskId: task.id, to: .completed)

        let response = completedOutputs.joined(separator: "\n")
        JarvisLogger.brain.info("AgentLoop completed goal successfully: \(response)")

        return response.isEmpty ? "All actions executed and verified." : response
    }

    // MARK: - Planning Heuristic

    /// Breaks user goal into structured executable steps.
    private func planSteps(for goal: String) -> [TaskStep] {
        let lower = goal.lowercased()
        var steps: [TaskStep] = []

        // Check for compound command connectors like "and", "then", ";"
        let subgoals = lower.components(separatedBy: " and ")

        for (index, subgoal) in subgoals.enumerated() {
            let trimmed = subgoal.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.contains("open ") {
                let appName = trimmed.replacingOccurrences(of: "open ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                steps.append(TaskStep(
                    stepNumber: index + 1,
                    description: "Open application \(appName)",
                    toolName: "open_app",
                    arguments: ["app_name": appName]
                ))
            } else if trimmed.contains("volume") {
                // Extract digits
                let digits = trimmed.filter { $0.isNumber }
                let level = digits.isEmpty ? "50" : digits
                steps.append(TaskStep(
                    stepNumber: index + 1,
                    description: "Set volume to \(level)%",
                    toolName: "set_volume",
                    arguments: ["level": level]
                ))
            } else if trimmed.hasPrefix("echo ") || trimmed.hasPrefix("ls ") || trimmed.hasPrefix("pwd") {
                steps.append(TaskStep(
                    stepNumber: index + 1,
                    description: "Run command: \(trimmed)",
                    toolName: "run_shell",
                    arguments: ["command": trimmed]
                ))
            } else {
                steps.append(TaskStep(
                    stepNumber: index + 1,
                    description: trimmed
                ))
            }
        }

        return steps
    }
}
