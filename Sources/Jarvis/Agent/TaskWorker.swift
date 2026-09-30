import Foundation

/// Asynchronous background worker that executes a single JarvisTask.
/// Runs completely off the MainActor (Guardrail 1).
/// Adheres to Guardrail 3 & 8: First-class cancellation and emergency stop propagation.
actor TaskWorker: Identifiable {
    let id: UUID
    private(set) var currentTaskId: UUID?
    private(set) var isBusy: Bool = false
    private var executionTask: Task<Void, Error>?

    init(id: UUID = UUID()) {
        self.id = id
    }

    // MARK: - Public API

    /// Execute a task asynchronously in the background.
    func execute(task: JarvisTask) async throws {
        guard !isBusy else {
            throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Worker \(id) is already busy")
        }

        self.isBusy = true
        self.currentTaskId = task.id

        let stateMachine = TaskStateMachine.shared
        try stateMachine.transition(taskId: task.id, to: .running)

        var currentStepIndex: Int?
        do {
            try Task.checkCancellation()

            // Execute each step sequentially
            for (index, step) in task.steps.enumerated() {
            currentStepIndex = index
                try Task.checkCancellation()

                try stateMachine.updateStep(
                    taskId: task.id,
                    stepIndex: index,
                    state: .running
                )

                // Execute tool if step has one
                if let toolName = step.toolName {
                    JarvisLogger.actions.info("Worker [\(self.id.uuidString.prefix(6))] executing step \(step.stepNumber): \(toolName)")

                    // Convert arguments from [String: String] to [String: any Sendable]
                    var args: [String: any Sendable] = [:]
                    for (k, v) in step.arguments {
                        args[k] = v
                    }

                    // ToolExecutor is @MainActor, execute on MainActor
                    let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)

                    try Task.checkCancellation()

                    // Step verified (ToolExecutor ran execute -> observe -> verify
                    // and returned; reaching here means verification passed)
                    try stateMachine.updateStep(
                        taskId: task.id,
                        stepIndex: index,
                        state: .completed,
                        output: result.output
                    )
                    try? stateMachine.markStepVerification(
                        taskId: task.id, stepIndex: index, outcome: .passed)
                    _ = try? stateMachine.appendResolutionRecord(StepResolutionRecord(
                        stepNumber: index + 1, toolName: toolName, rawOutput: result.output,
                        completedAt: Date(), verification: .passed), for: task.id)
                    currentStepIndex = nil
                } else {
                    // Pure thinking / cognitive step
                    try stateMachine.updateStep(
                        taskId: task.id,
                        stepIndex: index,
                        state: .completed,
                        output: "Step completed"
                    )
                    try? stateMachine.markStepVerification(
                        taskId: task.id, stepIndex: index, outcome: .notApplicable)
                    currentStepIndex = nil
                }
            }

            try Task.checkCancellation()

            // Verify overall task
            try stateMachine.transition(taskId: task.id, to: .verifying)
            try stateMachine.transition(taskId: task.id, to: .completed)

            JarvisLogger.actions.info("Worker [\(self.id.uuidString.prefix(6))] successfully completed task [\(task.id.uuidString.prefix(8))]")
            self.isBusy = false
            self.currentTaskId = nil

        } catch is CancellationError {
            JarvisLogger.actions.warning("Worker [\(self.id.uuidString.prefix(6))] task cancelled: [\(task.id.uuidString.prefix(8))]")
            _ = try? stateMachine.transition(taskId: task.id, to: .cancelled, error: "Task cancelled")
            self.isBusy = false
            self.currentTaskId = nil
            throw CancellationError()

        } catch {
            JarvisLogger.actions.error("Worker [\(self.id.uuidString.prefix(6))] task error: \(error.localizedDescription)")
            if let index = currentStepIndex, task.steps.indices.contains(index) {
                let originalStep = task.steps[index]
                let verificationOutcome = (error as? ToolVerificationFailure)?.outcome ?? .unavailable
                _ = try? stateMachine.updateStep(
                    taskId: task.id, stepIndex: index, state: .failed, error: error.localizedDescription)
                _ = try? stateMachine.markStepVerification(
                    taskId: task.id, stepIndex: index, outcome: verificationOutcome)
                if let toolName = originalStep.toolName, let verificationFailure = error as? ToolVerificationFailure {
                    _ = try? stateMachine.appendResolutionRecord(StepResolutionRecord(
                        stepNumber: index + 1, toolName: toolName, rawOutput: verificationFailure.observed,
                        completedAt: Date(), verification: verificationOutcome), for: task.id)
                }
            }
            _ = try? stateMachine.transition(taskId: task.id, to: .failed, error: error.localizedDescription)
            self.isBusy = false
            self.currentTaskId = nil
            throw error
        }
    }

    /// Cancel the currently executing task immediately.
    func cancel() {
        executionTask?.cancel()
        executionTask = nil
        isBusy = false
        currentTaskId = nil
    }
}
