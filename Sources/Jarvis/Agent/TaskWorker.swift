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

        let stateMachine = TaskStateMachine.shared
        guard let authoritativeTask = stateMachine.getTask(id: task.id) else {
            throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Task \(task.id) is not in authoritative TaskState")
        }
        guard authoritativeTask.state == .created || authoritativeTask.state == .planning
                || authoritativeTask.state == .failed || authoritativeTask.state == .cancelled else {
            throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Task is already active or terminal (\(authoritativeTask.state.rawValue))")
        }

        let claimedTask: JarvisTask
        if authoritativeTask.state == .cancelled || authoritativeTask.state == .failed {
            claimedTask = try stateMachine.beginContinuation(taskId: authoritativeTask.id)
        } else {
            claimedTask = try stateMachine.transition(taskId: authoritativeTask.id, to: .running)
        }

        self.isBusy = true
        self.currentTaskId = claimedTask.id

        var currentStepIndex: Int?
        do {
            try Task.checkCancellation()

            let currentTask = stateMachine.getTask(id: authoritativeTask.id)
            guard let currentTask else {
                throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Authoritative task disappeared")
            }

            // The passed value may predate a restart or another worker's update.
            // Only the current TaskState snapshot can authorize execution.
            for (index, step) in currentTask.steps.enumerated() {
                guard let latestTask = stateMachine.getTask(id: authoritativeTask.id),
                      latestTask.steps.indices.contains(index) else {
                    throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Authoritative task changed during execution")
                }
                if TaskContinuity.isResolved(latestTask.steps[index], task: latestTask) {
                    continue
                }
                guard latestTask.steps[index].state != .running else {
                    throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Step \(index + 1) is already running and cannot be restarted blindly")
                }

                currentStepIndex = index
                let step = latestTask.steps[index]
                try Task.checkCancellation()

                _ = try stateMachine.beginStepAttempt(taskId: authoritativeTask.id, stepIndex: index)

                // Execute tool if step has one
                if let toolName = step.toolName {
                    JarvisLogger.actions.info("Worker [\(self.id.uuidString.prefix(6))] executing step \(step.stepNumber): \(toolName)")

                    guard let tool = await MainActor.run(body: { ToolRegistry.shared.getTool(named: toolName) }) else {
                        throw JarvisError.actionFailed(action: toolName, reason: "Tool '\(toolName)' is not registered")
                    }
                    let args = try ReferenceResolver.resolveStepArguments(
                        rawArguments: step.arguments,
                        currentStepNumber: step.stepNumber,
                        toolParameterSpecs: tool.parameterSpec,
                        resolutionRecords: stateMachine.resolutionRecords(for: authoritativeTask.id),
                        environmentContext: stateMachine.environmentContext(for: authoritativeTask.id))

                    if toolName == "run_shell", let command = args["command"] as? String {
                        guard await MainActor.run(body: { CommandSandbox.shared.isSafe(command) }) else {
                            throw JarvisError.actionFailed(
                                action: "run_shell",
                                reason: "Resolved command rejected by CommandSandbox: \(command)")
                        }
                    }

                    // ToolExecutor is @MainActor, execute on MainActor
                    let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)

                    try Task.checkCancellation()

                    guard result.success, result.verification?.outcome == .passed else {
                        let outcome = result.verification?.outcome ?? .unavailable
                        throw JarvisError.verificationFailed(
                            action: toolName,
                            expected: "passed verification",
                            actual: outcome.rawValue)
                    }

                    _ = try stateMachine.appendResolutionRecord(StepResolutionRecord(
                        stepNumber: step.stepNumber, toolName: toolName, rawOutput: result.output,
                        completedAt: Date(), verification: .passed), for: authoritativeTask.id)
                    _ = try stateMachine.markStepVerification(
                        taskId: authoritativeTask.id, stepIndex: index, outcome: .passed)

                    try stateMachine.updateStep(
                        taskId: authoritativeTask.id,
                        stepIndex: index,
                        state: .completed,
                        output: result.output
                    )
                    currentStepIndex = nil
                } else {
                    // Pure thinking / cognitive step
                    try stateMachine.updateStep(
                        taskId: authoritativeTask.id,
                        stepIndex: index,
                        state: .completed,
                        output: "Step completed"
                    )
                    try stateMachine.markStepVerification(
                        taskId: authoritativeTask.id, stepIndex: index, outcome: .notApplicable)
                    currentStepIndex = nil
                }
            }

            try Task.checkCancellation()

            guard let finalTask = stateMachine.getTask(id: authoritativeTask.id),
                  !finalTask.steps.isEmpty,
                  finalTask.steps.allSatisfy({ TaskContinuity.isResolved($0, task: finalTask) }) else {
                throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Task steps are not all resolved by authoritative evidence")
            }

            // Verify overall task
            if finalTask.state == .running {
                try stateMachine.transition(taskId: authoritativeTask.id, to: .verifying)
            }
            if stateMachine.getTask(id: authoritativeTask.id)?.state == .verifying {
                try stateMachine.transition(taskId: authoritativeTask.id, to: .completed)
            }

            JarvisLogger.actions.info("Worker [\(self.id.uuidString.prefix(6))] successfully completed task [\(authoritativeTask.id.uuidString.prefix(8))]")
            self.isBusy = false
            self.currentTaskId = nil

        } catch is CancellationError {
            JarvisLogger.actions.warning("Worker [\(self.id.uuidString.prefix(6))] task cancelled: [\(authoritativeTask.id.uuidString.prefix(8))]")
            if stateMachine.getTask(id: authoritativeTask.id)?.state != .cancelled {
                _ = try? stateMachine.transition(taskId: authoritativeTask.id, to: .cancelled, error: "Task cancelled")
            }
            self.isBusy = false
            self.currentTaskId = nil
            throw CancellationError()

        } catch {
            JarvisLogger.actions.error("Worker [\(self.id.uuidString.prefix(6))] task error: \(error.localizedDescription)")
            if let index = currentStepIndex,
               let latestTask = stateMachine.getTask(id: authoritativeTask.id),
               latestTask.steps.indices.contains(index) {
                let originalStep = latestTask.steps[index]
                let verificationOutcome = (error as? ToolVerificationFailure)?.outcome ?? .unavailable
                _ = try? stateMachine.updateStep(
                    taskId: authoritativeTask.id, stepIndex: index, state: .failed, error: error.localizedDescription)
                _ = try? stateMachine.markStepVerification(
                    taskId: authoritativeTask.id, stepIndex: index, outcome: verificationOutcome)
                if let toolName = originalStep.toolName, let verificationFailure = error as? ToolVerificationFailure {
                    _ = try? stateMachine.appendResolutionRecord(StepResolutionRecord(
                        stepNumber: index + 1, toolName: toolName, rawOutput: verificationFailure.observed,
                        completedAt: Date(), verification: verificationOutcome), for: authoritativeTask.id)
                }
            }
            if let latestTask = stateMachine.getTask(id: authoritativeTask.id),
               latestTask.state != .failed && latestTask.state.canTransition(to: .failed) {
                _ = try? stateMachine.transition(taskId: authoritativeTask.id, to: .failed, error: error.localizedDescription)
            }
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
