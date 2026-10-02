import Foundation

enum AgentStepOutcomePolicy {
    static func accepts(_ result: ToolResult) -> Bool {
        result.success && result.verification?.outcome == .passed
    }
}

actor TaskExecutionCoordinator {
    static let shared = TaskExecutionCoordinator()

    private var route: PipelineRoute?
    private var replanCount = 0
    private var plannerMetrics: MLXPlanner.PlannerMetrics?

    func latestRoute() -> PipelineRoute? { route }
    func latestReplanCount() -> Int { replanCount }
    func latestPlannerMetrics() -> MLXPlanner.PlannerMetrics? { plannerMetrics }

    func run(goal: String, stateMachine: TaskStateMachine = .shared,
             fixedPlan: AgentPlan? = nil, stopRecoveryAfterAttempt: Bool = false) async throws -> String {
        route = nil
        replanCount = 0
        plannerMetrics = nil

        let normalized = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw JarvisError.actionFailed(action: "AgentLoop.run", reason: "Query cannot be empty")
        }
        try checkCancellation()

        if let continuity = TaskContinuity.query(for: normalized) {
            if continuity == .continueTask {
                guard stateMachine.isPersistenceAvailable else {
                    throw JarvisError.actionFailed(action: "TaskState.restore", reason: "Saved task state is invalid; continuation is disabled")
                }
                if let taskID = TaskContinuity.resumableTaskID(tasks: stateMachine.allTasks) {
                    route = .deterministic
                    return try await continueTask(taskID: taskID, stateMachine: stateMachine)
                }
            }
            route = .directAnswer
            return TaskContinuity.summary(query: continuity, tasks: stateMachine.allTasks)
        }
        let fileReference = ReferenceResolver.resolveCrossTurnFileReference(goal: normalized, tasks: stateMachine.allTasks)
        let commandReference = ReferenceResolver.resolveCrossTurnCommandReference(goal: normalized, tasks: stateMachine.allTasks)
        let urlReference = ReferenceResolver.resolveCrossTurnURLReference(goal: normalized, tasks: stateMachine.allTasks)
        let referencePlan = try await compileVerifiedCrossTurnReference(
            goal: normalized, file: fileReference, command: commandReference, url: urlReference)

        if referencePlan == nil, let deterministic = await MainActor.run(body: { DeterministicRouter.shared.match(normalized) }) {
            route = .deterministic
            let result = try await ActionEngine.shared.execute(
                intent: deterministic.intent,
                isDeterministic: true,
                impact: deterministic.impact,
                action: deterministic.action)
            recordConversationTurn(goal: normalized, response: result)
            return result
        }

        if referencePlan == nil {
            switch DirectAnswerRouter.decide(goal: normalized) {
            case .directAnswer:
                route = .directAnswer
                let response: String
                if let simple = DirectAnswerRouter.shared.evaluateDirectAnswer(normalized) {
                    response = simple
                } else {
                    response = try await DirectComposer().composeAnswer(goal: normalized, observations: [])
                }
                recordConversationTurn(goal: normalized, response: response)
                return response
            case .activitySummary:
                route = .directAnswer
                return ActivityHistory.recentSummary()
            case .verifiedArtifactSummary:
                route = .directAnswer
                return ActivityHistory.latestVerifiedArtifactSummary()
            case .verifiedArtifactStatus:
                route = .directAnswer
                return ActivityHistory.latestVerifiedArtifactStatus()
            case .informationAnswer(let source):
                route = .directAnswer
                switch source {
                case .conversationHistory: return await MainActor.run { ConversationHistoryAnswer.recentSummary() }
                case .userMemory: return await MainActor.run { MemoryManager.shared.whatDoYouRemember() }
                case .developmentHistory: return DevelopmentHistory.recentSummary()
                }
            case .taskContinuity(let query):
                route = .directAnswer
                return TaskContinuity.summary(query: query, tasks: stateMachine.allTasks)
            case .refusal(let reason):
                route = .refusal
                recordConversationTurn(goal: normalized, response: nil)
                return reason.userFacingMessage
            case .planner:
                break
            }
        }

        return try await createAndRunTask(goal: normalized, stateMachine: stateMachine,
                                          fixedPlan: fixedPlan, precompiledPlan: referencePlan,
                                          stopRecoveryAfterAttempt: stopRecoveryAfterAttempt)
    }

    private func continueTask(taskID: UUID, stateMachine: TaskStateMachine) async throws -> String {
        guard let before = stateMachine.getTask(id: taskID) else {
            throw JarvisError.actionFailed(action: "AgentLoop.continue", reason: "Authoritative task disappeared")
        }
        let task = try stateMachine.beginContinuation(taskId: taskID)
        ExecutionTelemetry.shared.record(ExecutionTelemetryEvent(
            taskID: task.id, kind: .recoveryAttempted, phase: .thinking,
            status: "task_continuation", attemptCount: task.retryCount))
        await reportInteractionPhase(.thinking, taskID: task.id)
        let savedPlan = AgentPlan(goal: task.goal, steps: task.steps.map {
            PlanStep(id: $0.id.uuidString, toolName: $0.toolName, arguments: $0.arguments, purpose: $0.description)
        })
        let validation = await MainActor.run { PlanValidator.validate(savedPlan, originalGoal: task.goal) }
        guard case .success(let plan) = validation else {
            let message: String
            if case .failure(let error) = validation { message = error.description } else { message = "unknown validation error" }
            try? stateMachine.transition(taskId: taskID, to: .failed, error: "Saved continuation plan failed validation: \(message)")
            throw JarvisError.actionFailed(action: "AgentLoop.continue", reason: message)
        }
        route = .deterministic
        return try await execute(plan: plan, task: task, stateMachine: stateMachine,
                                 originalRequest: "continue", recoveryGoal: before.goal)
    }

    private func createAndRunTask(
        goal: String,
        stateMachine: TaskStateMachine,
        fixedPlan: AgentPlan?,
        precompiledPlan: AgentPlan?,
        stopRecoveryAfterAttempt: Bool
    ) async throws -> String {
        route = .planner
        let task = stateMachine.createTask(title: "Autonomous Goal", goal: goal,
                                           environmentContext: TaskEnvironmentContext.captureLive())
        telemetry(taskID: task.id, step: nil, kind: .taskStarted, status: "started")
        await reportInteractionPhase(.thinking, taskID: task.id)
        try stateMachine.transition(taskId: task.id, to: .planning)
        do {
            let proposed: AgentPlan
            if let precompiledPlan {
                proposed = precompiledPlan
            } else if let fixedPlan {
                proposed = fixedPlan
            } else {
                let context = PlannerContext.initial(goal: goal)
                let compoundMarkers = [" and ", " then ", ";", "&&", ", then", " also "]
                if compoundMarkers.contains(where: goal.lowercased().contains) {
                    proposed = try await MLXPlanner.shared.plan(goal: goal, context: context, taskID: task.id)
                } else {
                    do {
                        proposed = try await MLXPlanner.shared.planDecomposed(goal: goal, taskID: task.id)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        proposed = try await MLXPlanner.shared.plan(goal: goal, context: context, taskID: task.id)
                    }
                }
                plannerMetrics = await MLXPlanner.shared.latestMetrics()
            }

            let validatedResult = await MainActor.run { PlanValidator.validate(proposed, originalGoal: goal) }
            guard case .success(let plan) = validatedResult else {
                if case .failure(let error) = validatedResult { throw error }
                throw PlanValidationError.noJSONFound
            }
            route = .planner
            try stateMachine.setSteps(taskId: task.id, steps: makeTaskSteps(plan))
            _ = try stateMachine.enablePersistence(for: task.id)
            try stateMachine.transition(taskId: task.id, to: .running)
            return try await execute(plan: plan, task: stateMachine.getTask(id: task.id) ?? task,
                                     stateMachine: stateMachine, originalRequest: goal,
                                     recoveryGoal: goal, stopRecoveryAfterAttempt: stopRecoveryAfterAttempt)
        } catch {
            if stateMachine.getTask(id: task.id)?.state == .planning {
                _ = try? stateMachine.transition(taskId: task.id, to: .failed, error: error.localizedDescription)
            }
            throw error
        }
    }

    private func execute(
        plan: AgentPlan,
        task: JarvisTask,
        stateMachine: TaskStateMachine,
        originalRequest: String,
        recoveryGoal: String,
        stopRecoveryAfterAttempt: Bool = false
    ) async throws -> String {
        var observations: [String] = []
        var outputs: [String] = []
        var replanCount = 0
        var lastFailure: (stepNumber: Int, purpose: String, tool: String?, error: String)?
        var stepIndex = 0
        while stepIndex < plan.steps.count {
            let planStep = plan.steps[stepIndex]
            try checkCancellation()
            guard let currentTask = stateMachine.getTask(id: task.id), currentTask.steps.indices.contains(stepIndex) else {
                throw JarvisError.actionFailed(action: "AgentLoop.execute", reason: "Authoritative task changed during execution")
            }
            let step = currentTask.steps[stepIndex]
            if TaskContinuity.isResolved(step, task: currentTask) {
                outputs.append(step.output ?? currentTask.resolutionRecords.last(where: { $0.stepNumber == step.stepNumber })?.rawOutput ?? "")
                stepIndex += 1
                continue
            }

            currentTaskStep(task.id, stepIndex)
            await reportInteractionPhase(.executing, taskID: task.id)
            telemetry(taskID: task.id, step: step, kind: .stepStarted, status: "started")
            do {
                _ = try stateMachine.beginStepAttempt(taskId: task.id, stepIndex: stepIndex)
                if let toolName = planStep.toolName {
                    guard let tool = ToolRegistry.shared.getTool(named: toolName) else {
                        throw JarvisError.actionFailed(action: toolName, reason: "Tool is not registered")
                    }
                    let args = try ReferenceResolver.resolveStepArguments(
                        rawArguments: planStep.arguments, currentStepNumber: step.stepNumber,
                        toolParameterSpecs: tool.parameterSpec,
                        resolutionRecords: stateMachine.resolutionRecords(for: task.id),
                        environmentContext: stateMachine.environmentContext(for: task.id))
                    if toolName == "run_shell", let command = args["command"] as? String,
                       !((await MainActor.run { CommandSandbox.shared.isSafe(command) })) {
                        throw JarvisError.actionFailed(action: "run_shell", reason: "Resolved command rejected by CommandSandbox: \(command)")
                    }
                    let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)
                    guard AgentStepOutcomePolicy.accepts(result) else {
                        throw JarvisError.verificationFailed(action: toolName, expected: "passed verification", actual: result.output)
                    }
                    try stateMachine.completeVerifiedStep(taskId: task.id, stepIndex: stepIndex, output: result.output)
                    observations.append("[\(toolName)] \(result.output)")
                    outputs.append(result.output)
                    telemetry(taskID: task.id, step: step, kind: .verificationCompleted,
                              status: result.verification?.outcome.rawValue ?? "unavailable",
                              verification: result.verification?.outcome)
                    telemetry(taskID: task.id, step: step, kind: .stepCompleted, status: "completed",
                              verification: .passed)
                } else {
                    let composed = try await DirectComposer().composeAnswer(goal: recoveryGoal, observations: observations)
                    try stateMachine.completeNonActionStep(taskId: task.id, stepIndex: stepIndex, output: composed)
                    outputs.append(composed)
                    telemetry(taskID: task.id, step: step, kind: .stepCompleted, status: "completed",
                              verification: .notApplicable)
                }
                try checkCancellation()
                stepIndex += 1
            } catch is CancellationError {
                cancel(taskID: task.id, stateMachine: stateMachine, reason: "Emergency Stop")
                telemetry(taskID: task.id, step: nil, kind: .stopped, status: "cancelled",
                          failureCategory: .cancellation)
                throw CancellationError()
            } catch {
                let outcome = (error as? ToolVerificationFailure)?.outcome ?? .unavailable
                _ = try? stateMachine.updateStep(taskId: task.id, stepIndex: stepIndex, state: .failed,
                                                 error: error.localizedDescription)
                _ = try? stateMachine.markStepVerification(taskId: task.id, stepIndex: stepIndex, outcome: outcome)
                if let failure = error as? ToolVerificationFailure, let toolName = planStep.toolName {
                    _ = try? stateMachine.appendResolutionRecord(StepResolutionRecord(
                        stepNumber: step.stepNumber, toolName: toolName, rawOutput: failure.observed,
                        verification: failure.outcome), for: task.id)
                }
                let failureCategory = ExecutionFailureCategory.classify(error)
                telemetry(taskID: task.id, step: step, kind: .stepFailed, status: error.localizedDescription,
                          verification: outcome, failureCategory: failureCategory)
                lastFailure = (stepNumber: step.stepNumber, purpose: planStep.purpose,
                               tool: planStep.toolName, error: error.localizedDescription)

                // RECOVER: the bounded, real recovery chain — FAILED → RECOVERING →
                // REPLANNING → replan → RUNNING. The telemetry event records the
                // attempt; it never authorizes the retry (TaskState transitions do).
                replanCount += 1
                _ = try? stateMachine.transition(taskId: task.id, to: .recovering)
                _ = try? stateMachine.transition(taskId: task.id, to: .replanning)
                try? stateMachine.incrementRetryCount(taskId: task.id)
                telemetry(taskID: task.id, step: step, kind: .recoveryAttempted,
                          status: "replanning", failureCategory: failureCategory,
                          attemptCount: replanCount)
                await reportInteractionPhase(.thinking, taskID: task.id)

                do {
                    if stopRecoveryAfterAttempt {
                        throw PlanValidationError.noJSONFound
                    }
                    var plannerContext = PlannerContext.initial(goal: recoveryGoal)
                    plannerContext = plannerContext.with(
                        failure: error.localizedDescription, observations: observations)
                    let replanned = try await MLXPlanner.shared.plan(
                        goal: recoveryGoal, context: plannerContext, taskID: task.id)
                    let validatedResult = await MainActor.run { PlanValidator.validate(replanned, originalGoal: recoveryGoal) }
                    guard case .success(let validatedPlan) = validatedResult else {
                        if case .failure(let validationError) = validatedResult { throw validationError }
                        throw PlanValidationError.noJSONFound
                    }
                    // A replan preserves completed steps and continues execution;
                    // never reset backwards into already-completed steps.
                    let existingSteps = stateMachine.getTask(id: task.id)?.steps ?? []
                    try stateMachine.setSteps(taskId: task.id, steps: Self.makeTaskSteps(validatedPlan, preservingCompletedFrom: existingSteps))
                    let completedCount = existingSteps.filter { $0.state == .completed }.count
                    if stepIndex >= validatedPlan.steps.count { stepIndex = max(stepIndex, completedCount) }
                    try stateMachine.transition(taskId: task.id, to: .running)
                } catch is CancellationError {
                    cancel(taskID: task.id, stateMachine: stateMachine, reason: "Emergency Stop")
                    telemetry(taskID: task.id, step: nil, kind: .stopped, status: "cancelled",
                              failureCategory: .cancellation)
                    throw CancellationError()
                } catch {
                    // RECOVERY-FAILED REPORTING (final-response accuracy): the replan
                    // itself failed, so the run cannot continue. Report the PARTIAL
                    // completion — completed-and-verified step count plus the actual
                    // failed step — from the TaskState recorded before the replan,
                    // and close the task out as FAILED (legal from REPLANNING).
                    let completedStepCount = stateMachine.getTask(id: task.id)?.steps.filter {
                        $0.state == .completed && ($0.verification?.isVerified == true || $0.verification == .notApplicable)
                    }.count ?? 0
                    let reason = AgentLoop.partialCompletionReport(
                        completedStepCount: completedStepCount, lastFailure: lastFailure)
                    telemetry(taskID: task.id, step: nil, kind: .taskFailed, status: reason,
                              failureCategory: ExecutionFailureCategory.classify(error))
                    try stateMachine.transition(taskId: task.id, to: .failed, error: reason)
                    recordConversationTurn(goal: originalRequest, response: nil)
                    throw JarvisError.actionFailed(
                        action: lastFailure?.tool ?? "AgentLoop.run", reason: reason)
                }
            }
        }

        guard let finalTask = stateMachine.getTask(id: task.id), !finalTask.steps.isEmpty,
              finalTask.steps.allSatisfy({ TaskContinuity.isResolved($0, task: finalTask) }) else {
            throw JarvisError.actionFailed(action: "AgentLoop.verify", reason: "Task cannot complete without passed evidence for every step")
        }
        try stateMachine.transition(taskId: task.id, to: .verifying)
        try stateMachine.transition(taskId: task.id, to: .completed)
        route = route ?? .planner
        let response = outputs.filter { !$0.isEmpty }.joined(separator: "\n")
        telemetry(taskID: task.id, step: nil, kind: .taskCompleted, status: "completed")
        recordConversationTurn(goal: originalRequest, response: response)
        return response.isEmpty ? "All actions executed and verified." : response
    }

    private func compileVerifiedCrossTurnReference(
        goal: String,
        file: ReferenceResolver.CrossTurnFileReference,
        command: ReferenceResolver.CrossTurnCommandReference,
        url: ReferenceResolver.CrossTurnURLReference
    ) async throws -> AgentPlan? {
        var extraction: ExtractedAction?
        var compilerGoal: String
        switch file {
        case .resolved(let path):
            compilerGoal = "read the file \"\(path)\""
            extraction = PlannerExtraction.explicitReadFileExtraction(goal: compilerGoal)
        case .notApplicable, .unavailable, .ambiguous: extraction = nil; compilerGoal = goal
        }
        if let extraction {
            let result = await MainActor.run { PlannerExtraction.compile(extraction, goal: compilerGoal) }
            guard case .success(let plan) = result else { throw JarvisError.actionFailed(action: "ReferenceResolver", reason: "Verified file reference could not be compiled") }
            return plan
        }
        switch command {
        case .resolved(let value):
            compilerGoal = "run command \"\(value)\""
            extraction = PlannerExtraction.explicitRunShellCommandExtraction(goal: compilerGoal)
        case .notApplicable, .unavailable, .ambiguous: extraction = nil; compilerGoal = goal
        }
        if let extraction {
            let result = await MainActor.run { PlannerExtraction.compile(extraction, goal: compilerGoal) }
            guard case .success(let plan) = result else { throw JarvisError.actionFailed(action: "ReferenceResolver", reason: "Verified command reference could not be compiled") }
            return plan
        }
        switch url {
        case .resolved(let value):
            let shouldFetch = goal.lowercased().contains("fetch") || goal.lowercased().contains("download")
            compilerGoal = shouldFetch ? "fetch the url \(value)" : "open \(value)"
            extraction = shouldFetch ? PlannerExtraction.explicitFetchURLExtraction(goal: compilerGoal)
                : PlannerExtraction.explicitURLOpenExtraction(goal: compilerGoal)
        case .notApplicable, .unavailable, .ambiguous: extraction = nil; compilerGoal = goal
        }
        if let extraction {
            let result = await MainActor.run { PlannerExtraction.compile(extraction, goal: compilerGoal) }
            guard case .success(let plan) = result else { throw JarvisError.actionFailed(action: "ReferenceResolver", reason: "Verified URL reference could not be compiled") }
            return plan
        }
        return nil
    }

    @MainActor
    private func executeDeterministic(_ result: DeterministicRouteResult) async throws -> String {
        switch result.actionName {
        case "system.openApp":
            guard let name = result.parameters["appName"] else { throw JarvisError.actionFailed(action: result.actionName, reason: "Missing app name") }
            return try await ActionEngine.shared.execute(intent: "app.open", impact: .safeMutation) {
                try await AppLauncher.shared.open(name)
            }
        case "web.search":
            let query = result.parameters["query"] ?? ""
            let output = try await ToolExecutor.shared.execute(toolName: "web_search", arguments: ["query": query])
            return output.output
        case "system.volumeUp":
            return try await ActionEngine.shared.execute(intent: result.actionName, impact: .safeMutation) {
                try SystemControl.shared.setVolume(min(100, SystemControl.shared.getVolume() + 10))
            }
        case "system.volumeDown":
            return try await ActionEngine.shared.execute(intent: result.actionName, impact: .safeMutation) {
                try SystemControl.shared.setVolume(max(0, SystemControl.shared.getVolume() - 10))
            }
        case "system.mute", "system.unmute":
            return try await ActionEngine.shared.execute(intent: result.actionName, impact: .safeMutation) {
                try result.actionName == "system.mute" ? SystemControl.shared.mute() : SystemControl.shared.unmute()
            }
        default:
            throw JarvisError.actionFailed(action: result.actionName, reason: "No deterministic action adapter is registered")
        }
    }

    private func makeTaskSteps(_ plan: AgentPlan) -> [TaskStep] {
        Self.makeTaskSteps(plan)
    }

    /// Convert validated plan steps into state-machine TaskSteps, preserving
    /// any already-completed step states and verified outputs.
    private static func makeTaskSteps(_ plan: AgentPlan, preservingCompletedFrom existingSteps: [TaskStep] = []) -> [TaskStep] {
        plan.steps.enumerated().map { index, step in
            if index < existingSteps.count && existingSteps[index].state == .completed {
                return existingSteps[index]
            }
            return TaskStep(id: UUID(uuidString: step.id) ?? UUID(), stepNumber: index + 1,
                            description: step.purpose, toolName: step.toolName, arguments: step.arguments)
        }
    }

    private func currentTaskStep(_ taskID: UUID, _ index: Int) {
        _ = try? TaskStateMachine.shared.setCurrentStepIndex(taskId: taskID, index: index)
    }

    @MainActor
    private func reportInteractionPhase(_ phase: InteractionPhase, taskID: UUID? = nil) {
        InteractionPhaseCenter.report(phase, taskID: taskID?.uuidString)
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if AgentLoop.shared.isEmergencyCancelled { throw CancellationError() }
    }

    private func cancel(taskID: UUID, stateMachine: TaskStateMachine, reason: String) {
        if stateMachine.getTask(id: taskID)?.state != .cancelled {
            _ = try? stateMachine.transition(taskId: taskID, to: .cancelled, error: reason)
        }
    }

    private func telemetry(taskID: UUID, step: TaskStep?, kind: ExecutionTelemetryKind, status: String,
                           verification: VerificationOutcome? = nil,
                           failureCategory: ExecutionFailureCategory? = nil,
                           attemptCount: Int? = nil) {
        ExecutionTelemetry.shared.record(ExecutionTelemetryEvent(
            taskID: taskID, stepID: step?.id, kind: kind,
            phase: kind == .taskCompleted ? .success : (kind == .recoveryAttempted ? .thinking : .executing),
            action: step?.toolName, status: status, verification: verification,
            failureCategory: failureCategory, attemptCount: attemptCount))
    }

    private func recordConversationTurn(goal: String, response: String?) {
        Task { @MainActor in ConversationManager.shared.recordInteraction(goal: goal, response: response) }
    }
}