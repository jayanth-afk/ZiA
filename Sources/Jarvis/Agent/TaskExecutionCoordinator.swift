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

    /// Test seam: when set, recovery replanning calls this instead of the real
    /// MLX planner. Production leaves it nil so every recovery plan still goes
    /// through the real MLXPlanner and is validated by PlanValidator; a real
    /// plan is required for every recovery, model or not.
    private var replanOverride: (@Sendable (String, PlannerContext, UUID) async throws -> AgentPlan)?

    /// Install/clear the recovery replanner used by tests. Passing nil restores
    /// the production MLX planner.
    func setReplanOverrideForTesting(_ override: (@Sendable (String, PlannerContext, UUID) async throws -> AgentPlan)?) {
        replanOverride = override
    }

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
        // A completed emergency stop must halt the request that was in flight,
        // but it must not permanently poison the session. The latch is set when
        // the stop event is delivered to running work; a NEW top-level request
        // therefore starts from a clean stop state (same lifecycle rule already
        // used by AgentLoop.processUserQuery). In-flight work is unaffected
        // because the stop event reaches it at stop time, not on a later request.
        AgentLoop.shared.resetEmergencyCancellation()
        try checkCancellation()

        // Emergency stop is a deterministic, zero-model-call pipeline gate at
        // EVERY entry point — not just the voice transcript path. A typed or
        // CLI command like "stop" / "Jarvis, stop" must halt deterministically
        // and must never be forwarded to the planner (which could fetch, plan,
        // or execute while the user asked for an immediate stop). Reuse the
        // exact same phrase detector the voice path uses so there is one
        // authority; it also publishes EmergencyStopEvent to cancel in-flight
        // work. The stop is honored before any routing or reference resolution.
        if await MainActor.run(body: { EmergencyInterrupt.shared.checkForEmergency(in: normalized) }) {
            // Route attribution is truthful: the stop is handled deterministically
            // with zero model calls (same category as cancel/abort).
            route = .deterministic
            await reportInteractionPhase(.stopped)
            recordConversationTurn(goal: normalized, response: nil)
            return "Stopped."
        }

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
            // A deterministic action is still a real production interaction, so
            // it publishes the same one-task/one-step lifecycle and semantic
            // phases as the planner path. Telemetry is observational only; the
            // action is still authorized by PermissionGate inside ActionEngine.
            let telemetryTaskID = UUID()
            let telemetryStepID = UUID()
            await reportInteractionPhase(.understanding)
            ExecutionTelemetry.shared.record(ExecutionTelemetryEvent(
                taskID: telemetryTaskID, kind: .taskStarted, phase: .understanding, status: "started"))
            await reportInteractionPhase(.executing)
            ExecutionTelemetry.shared.record(ExecutionTelemetryEvent(
                taskID: telemetryTaskID, stepID: telemetryStepID, kind: .stepStarted,
                phase: .executing, action: deterministic.intent, status: "started"))
            let result = try await ActionEngine.shared.execute(
                intent: deterministic.intent,
                isDeterministic: true,
                impact: deterministic.impact,
                action: deterministic.action)
            ExecutionTelemetry.shared.record(ExecutionTelemetryEvent(
                taskID: telemetryTaskID, stepID: telemetryStepID, kind: .stepCompleted,
                phase: .executing, action: deterministic.intent, status: "completed"))
            ExecutionTelemetry.shared.record(ExecutionTelemetryEvent(
                taskID: telemetryTaskID, kind: .taskCompleted, phase: .success, status: "completed"))
            await reportInteractionPhase(.success)
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
        // NOTE: replanCount is the actor's `replanCount` property, not a local.
        // A shadowing local here silently froze `latestReplanCount()` at 0, so
        // the audit/metrics reported "0 replans" even when recovery replanned.
        var lastFailure: (stepNumber: Int, purpose: String, tool: String?, error: String)?
        var stepIndex = 0
        // The plan actually driving execution. It starts as the caller's plan and
        // is REPLACED by a validated replan, so the tool and arguments that run
        // always match the TaskStep whose evidence is recorded for them.
        var activePlan = plan
        while stepIndex < activePlan.steps.count {
            let planStep = activePlan.steps[stepIndex]
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
                        verification: failure.outcome, taskID: task.id, stepID: step.id,
                        argumentsFingerprint: StepResolutionRecord.fingerprint(arguments: step.arguments)), for: task.id)
                }
                // The verifier actually ran and returned a non-passed outcome
                // (inconclusive/unavailable/failed): record that completed
                // verification truthfully instead of collapsing it into only a
                // generic step failure.
                if let failure = error as? ToolVerificationFailure {
                    telemetry(taskID: task.id, step: step, kind: .verificationCompleted,
                              status: failure.outcome.rawValue, verification: failure.outcome)
                }
                let failureCategory = ExecutionFailureCategory.classify(error)
                telemetry(taskID: task.id, step: step, kind: .stepFailed, status: error.localizedDescription,
                          verification: outcome, failureCategory: failureCategory)
                lastFailure = (stepNumber: step.stepNumber, purpose: planStep.purpose,
                               tool: planStep.toolName, error: error.localizedDescription)

                // Permission denial is a terminal authorization outcome, never a
                // recoverable step failure: replanning cannot grant authority and
                // would silently convert the gate's error into a vague task
                // failure. Close the task FAILED with the real reason and rethrow
                // the original gate error so the caller can surface/approve it.
                if case JarvisError.permissionDenied = error {
                    telemetry(taskID: task.id, step: nil, kind: .taskFailed, status: error.localizedDescription,
                              failureCategory: failureCategory)
                    _ = try? stateMachine.transition(taskId: task.id, to: .failed,
                                                     error: error.localizedDescription)
                    recordConversationTurn(goal: originalRequest, response: nil)
                    throw error
                }

                // Classified retry policy: categories that are definitionally
                // non-recoverable (malformed structured output) close the task
                // with its recorded evidence instead of replanning. The replan
                // path below produces a DIFFERENT validated plan, so it is only
                // entered for failures recovery can plausibly address.
                if failureCategory != .permission, !RecoveryPolicy.isRecoverable(failureCategory) {
                    let completedStepCount = stateMachine.getTask(id: task.id)?.steps.filter {
                        $0.state == .completed && ($0.verification?.isVerified == true || $0.verification == .notApplicable)
                    }.count ?? 0
                    let reason = AgentLoop.partialCompletionReport(
                        completedStepCount: completedStepCount, lastFailure: lastFailure)
                    telemetry(taskID: task.id, step: nil, kind: .taskFailed, status: reason,
                              failureCategory: failureCategory)
                    _ = try? stateMachine.transition(taskId: task.id, to: .failed, error: reason)
                    recordConversationTurn(goal: originalRequest, response: nil)
                    throw JarvisError.actionFailed(
                        action: lastFailure?.tool ?? "AgentLoop.run", reason: reason)
                }

                // RECOVER: the bounded, real recovery chain — RUNNING → FAILED →
                // RECOVERING → REPLANNING → replan → RUNNING. The telemetry event
                // records the attempt; it never authorizes the retry (TaskState
                // transitions do).
                replanCount += 1
                _ = try? stateMachine.transition(taskId: task.id, to: .failed,
                                                 error: error.localizedDescription)
                _ = try? stateMachine.transition(taskId: task.id, to: .recovering)
                _ = try? stateMachine.transition(taskId: task.id, to: .replanning)
                try? stateMachine.incrementRetryCount(taskId: task.id)
                telemetry(taskID: task.id, step: step, kind: .recoveryAttempted,
                          status: "replanning", failureCategory: failureCategory,
                          attemptCount: replanCount)
                await reportInteractionPhase(.thinking, taskID: task.id)

                do {
                    // Recovery is bounded by the task's persisted retry budget:
                    // once exhausted, the recorded evidence stands and the task
                    // closes FAILED rather than replanning without limit.
                    let retryBudget = stateMachine.getTask(id: task.id)?.retryCount ?? task.retryCount
                    let retryLimit = stateMachine.getTask(id: task.id)?.maxRetries ?? task.maxRetries
                    if stopRecoveryAfterAttempt || retryBudget > retryLimit {
                        throw PlanValidationError.noJSONFound
                    }
                    var plannerContext = PlannerContext.initial(goal: recoveryGoal)
                    plannerContext = plannerContext.with(
                        failure: error.localizedDescription, observations: observations)
                    let replanned: AgentPlan
                    if let replanOverride {
                        replanned = try await replanOverride(recoveryGoal, plannerContext, task.id)
                    } else {
                        replanned = try await MLXPlanner.shared.plan(
                            goal: recoveryGoal, context: plannerContext, taskID: task.id)
                    }
                    let validatedResult = await MainActor.run { PlanValidator.validate(replanned, originalGoal: recoveryGoal) }
                    guard case .success(let validatedPlan) = validatedResult else {
                        if case .failure(let validationError) = validatedResult { throw validationError }
                        throw PlanValidationError.noJSONFound
                    }
                    // A replan preserves only steps whose LOGICAL IDENTITY still
                    // matches, and continues from the first unresolved step —
                    // never resetting backwards into already-completed work, and
                    // never transferring a completion to a different action.
                    let rebuilt = Self.makeTaskSteps(
                        validatedPlan, preservingResolvedFrom: stateMachine.getTask(id: task.id))
                    try stateMachine.setSteps(taskId: task.id, steps: rebuilt.steps,
                                              replacingResolutionRecords: rebuilt.records)
                    // Adopt the validated replan for the remainder of this run and
                    // re-anchor the cursor to the first UNRESOLVED step of the new
                    // plan. Otherwise the loop keeps executing the ORIGINAL plan's
                    // tool/arguments while the task steps — and therefore the
                    // recorded evidence identity — come from the replan, so the
                    // action that runs is not the action its evidence claims, and
                    // the recovery plan is silently ignored.
                    activePlan = validatedPlan
                    if let replannedTask = stateMachine.getTask(id: task.id),
                       let firstUnresolved = TaskContinuity.firstIncompleteStepIndex(task: replannedTask) {
                        stepIndex = firstUnresolved
                    } else {
                        stepIndex = activePlan.steps.count
                    }
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

        // Workflow learning (opt-in): a verified multi-step task may become a
        // reusable procedure. Gated by configuration so it is never a silent
        // background behavior, and only trusted task-result provenance is used.
        if finalTask.steps.count >= 2 {
            let toolStepNames = finalTask.steps.compactMap { $0.toolName }
            if toolStepNames.count >= 2 {
                await MainActor.run {
                    guard Config.shared.proceduralLearningEnabled else { return }
                    _ = MemoryManager.shared.recordProcedure(
                        goal: originalRequest, toolStepNames: toolStepNames, taskID: task.id)
                }
            }
        }

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

    private func makeTaskSteps(_ plan: AgentPlan) -> [TaskStep] {
        Self.makeTaskSteps(plan).steps
    }

    /// Convert a validated plan into authoritative TaskSteps. A step that was
    /// already RESOLVED under the previous plan is preserved ONLY when the new
    /// step is provably the SAME logical action — identical canonical tool
    /// identity and argument fingerprint (or identical purpose for a
    /// composition step). Position is never used: a replan may reorder, insert,
    /// or remove steps, and index-based preservation would hand one action's
    /// completed state and evidence to a different action.
    ///
    /// Returns the steps together with the resolution records that must be
    /// stored beside them: preserved steps keep their original evidence,
    /// re-numbered to the new position, and every orphaned record (a record
    /// whose logical step is gone) is dropped so a record's `stepNumber` can
    /// never point at a step of a different tool.
    static func makeTaskSteps(
        _ plan: AgentPlan,
        preservingResolvedFrom existingTask: JarvisTask? = nil
    ) -> (steps: [TaskStep], records: [StepResolutionRecord]) {
        // FIFO queue of already-resolved existing steps per logical identity. A
        // queue (not a set) keeps duplicates deterministic; and because the key
        // IS the identity, a completion can never migrate to a different tool or
        // a different argument set. Identity is also task-bound at the record
        // level (taskID/stepID/fingerprint), so cross-task evidence cannot enter.
        var reusable: [StepIdentity: [TaskStep]] = [:]
        var passedRecordForStep: [UUID: StepResolutionRecord] = [:]
        if let existingTask {
            for step in existingTask.steps where TaskContinuity.isResolved(step, task: existingTask) {
                reusable[StepIdentity(step: step), default: []].append(step)
            }
            // Last passed record for a step wins, mirroring the lookup semantics
            // of TaskContinuity.independentlyVerified / isValidPersistedTask.
            for record in existingTask.resolutionRecords where record.verification == .passed {
                if let stepID = record.stepID { passedRecordForStep[stepID] = record }
            }
        }

        var steps: [TaskStep] = []
        var records: [StepResolutionRecord] = []
        for (index, planStep) in plan.steps.enumerated() {
            let stepNumber = index + 1
            let fresh = TaskStep(id: UUID(uuidString: planStep.id) ?? UUID(), stepNumber: stepNumber,
                                 description: planStep.purpose, toolName: planStep.toolName,
                                 arguments: planStep.arguments)
            guard let preserved = reusable[StepIdentity(step: fresh)]?.first else {
                steps.append(fresh)
                continue
            }
            reusable[StepIdentity(step: fresh)]?.removeFirst()
            // Same logical action: reuse the resolved step, re-numbered to its
            // new position. Tool identity and arguments are unchanged, so the
            // reused output/verification still describes exactly this action.
            steps.append(TaskStep(id: preserved.id, stepNumber: stepNumber,
                                  description: preserved.description, toolName: preserved.toolName,
                                  arguments: preserved.arguments, state: preserved.state,
                                  output: preserved.output, error: preserved.error,
                                  verification: preserved.verification))
            if let record = passedRecordForStep[preserved.id] {
                records.append(StepResolutionRecord(stepNumber: stepNumber, toolName: record.toolName,
                                                    rawOutput: record.rawOutput,
                                                    structuredOutput: record.structuredOutput,
                                                    completedAt: record.completedAt,
                                                    verification: record.verification,
                                                    taskID: record.taskID, stepID: record.stepID,
                                                    argumentsFingerprint: record.argumentsFingerprint))
            }
        }
        return (steps, records)
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