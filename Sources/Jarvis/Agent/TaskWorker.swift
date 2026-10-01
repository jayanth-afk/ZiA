import Foundation

/// Asynchronous background worker that executes a single JarvisTask.
/// Runs completely off the MainActor (Guardrail 1).
/// Adheres to Guardrail 3 & 8: First-class cancellation and emergency stop propagation.
///
/// Restart-safety contract: when a task arrives with already-independently-
/// verified steps (restored from durable TaskState after a process
/// interruption), those steps are NOT re-executed. Verified work is marked
/// completed from its recorded evidence exactly as
/// `TaskStateMachine.beginContinuation` does, and execution resumes at the
/// first unresolved step. Verified work is never re-run and never lost.
actor TaskWorker: Identifiable {
    let id: UUID
    private(set) var currentTaskId: UUID?
    private(set) var isBusy: Bool = false
    private var executionTask: Task<Void, Error>?
    /// Injectable authoritative owner (SelfTest restart seam). Production
    /// always uses the shared TaskStateMachine singleton.
    private let stateMachine: TaskStateMachine

    init(id: UUID = UUID(), stateMachine: TaskStateMachine = .shared) {
        self.id = id
        self.stateMachine = stateMachine
    }

    // MARK: - Public API

    /// Execute a task asynchronously in the background.
    func execute(task: JarvisTask) async throws {
        guard !isBusy else {
            throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Worker \(id) is already busy")
        }

        let stateMachine = self.stateMachine
        guard let currentTask = stateMachine.getTask(id: task.id) else {
            throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Task is not in authoritative TaskState")
        }
        let claimedTask: JarvisTask
        switch currentTask.state {
        case .created, .planning:
            claimedTask = try stateMachine.transition(taskId: task.id, to: .running)
        case .failed, .cancelled:
            claimedTask = try stateMachine.beginContinuation(taskId: task.id)
        default:
            throw JarvisError.actionFailed(
                action: "TaskWorker.execute",
                reason: "Task is already active or terminal (\(currentTask.state.rawValue))")
        }
        self.isBusy = true
        self.currentTaskId = claimedTask.id

        var currentStepIndex: Int?
        do {
            try Task.checkCancellation()

            // Restart-safety: every step that carries independent verified
            // evidence (step verification .passed AND a matching passed
            // resolution record) is completed work — restore its completed
            // state/output from evidence and SKIP it. Never re-execute
            // verified work; resume at the first unresolved step.
            guard let authoritativeTask = stateMachine.getTask(id: task.id) else {
                throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Authoritative task disappeared")
            }
            for index in authoritativeTask.steps.indices {
                guard let latestTask = stateMachine.getTask(id: task.id),
                      latestTask.steps.indices.contains(index) else {
                    throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Authoritative task changed during execution")
                }
                let step = latestTask.steps[index]
                try Task.checkCancellation()

                if TaskContinuity.isResolved(step, task: latestTask) {
                    JarvisLogger.actions.info("Worker [\(self.id.uuidString.prefix(6))] skipping independently verified step \(step.stepNumber) (restart continuation)")
                    continue
                }
                guard step.state != .running else {
                    throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Step \(step.stepNumber) is still marked running without verified evidence")
                }

                currentStepIndex = index
                _ = try stateMachine.beginStepAttempt(taskId: task.id, stepIndex: index)

                // Execute tool if step has one
                if let toolName = step.toolName {
                    JarvisLogger.actions.info("Worker [\(self.id.uuidString.prefix(6))] executing step \(step.stepNumber): \(toolName)")

                    guard let tool = ToolRegistry.shared.getTool(named: toolName) else {
                        throw JarvisError.actionFailed(action: toolName, reason: "Tool '\(toolName)' is not registered")
                    }
                    var environment = stateMachine.environmentContext(for: task.id)
                    if environment == nil {
                        environment = TaskEnvironmentContext.captureLive()
                        _ = try stateMachine.setEnvironmentContext(environment!, for: task.id)
                    }
                    let args = try ReferenceResolver.resolveStepArguments(
                        rawArguments: step.arguments,
                        currentStepNumber: step.stepNumber,
                        toolParameterSpecs: tool.parameterSpec,
                        resolutionRecords: stateMachine.resolutionRecords(for: task.id),
                        environmentContext: environment)
                    if toolName == "run_shell", let command = args["command"] as? String,
                       !((await MainActor.run { CommandSandbox.shared.isSafe(command) })) {
                        throw JarvisError.actionFailed(action: "run_shell", reason: "Resolved command rejected by CommandSandbox: \(command)")
                    }

                    // ToolExecutor is @MainActor, execute on MainActor
                    let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)

                    try Task.checkCancellation()

                    guard result.success, result.verification?.outcome == .passed else {
                        throw JarvisError.verificationFailed(
                            action: toolName, expected: "passed verification",
                            actual: result.verification?.outcome.rawValue ?? "unavailable")
                    }
                    try stateMachine.completeVerifiedStep(taskId: task.id, stepIndex: index, output: result.output)
                    currentStepIndex = nil
                } else {
                    try stateMachine.completeNonActionStep(taskId: task.id, stepIndex: index, output: "Step completed")
                    currentStepIndex = nil
                }
            }

            try Task.checkCancellation()

                        guard let finishedTask = stateMachine.getTask(id: task.id),
                                    !finishedTask.steps.isEmpty,
                                    finishedTask.steps.allSatisfy({ TaskContinuity.isResolved($0, task: finishedTask) }) else {
                                throw JarvisError.actionFailed(action: "TaskWorker.execute", reason: "Not all task steps have authoritative verification evidence")
                        }
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
