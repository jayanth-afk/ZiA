import Foundation

/// Shared success policy for both whole-plan and sequential execution. Empty
/// stdout is valid only when the tool produced deterministic passed evidence
/// (for example, a verified redirect that wrote a file without printing).
enum AgentStepOutcomePolicy {
    static func accepts(_ result: ToolResult) -> Bool {
        guard result.success else { return false }
        let hasOutput = !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasOutput || result.verification?.outcome == .passed
    }
}

actor AgentLoop {
    /// Truthful final report for a run that made real execution progress but
    /// whose recovery/replan could not continue. States the PARTIAL completion
    /// (how many steps completed and verified) and the ACTUAL failed step —
    /// never success — so the user's final response matches the recorded
    /// TaskState/verification evidence instead of surfacing only the raw
    /// recovery-infrastructure error.
    nonisolated static func partialCompletionReport(
        completedStepCount: Int,
        lastFailure: (stepNumber: Int, purpose: String, tool: String?, error: String)?
    ) -> String {
        let stepWord = completedStepCount == 1 ? "step" : "steps"
        let completedPart = "Partial completion: \(completedStepCount) \(stepWord) completed and verified before failure"
        let failurePart = lastFailure.map { "; Step \($0.stepNumber) ('\($0.purpose)') failed: \($0.error)" }
            ?? "; Task incomplete: no step failure recorded"
        return completedPart + failurePart
    }

    /// Core autonomous agent loop implementing:
    /// SENSE -> UNDERSTAND -> PLAN -> EXECUTE -> OBSERVE -> VERIFY -> RESPOND -> RECOVER
    /// Preserves the fundamental JARVIS architecture.
    ///
    /// Phase D: planning is now REAL — the goal goes to the local MLX model
    /// (MLXPlanner -> MLXProvider -> persistent mlx_lm worker), which returns a
    /// structured plan that PlanValidator grounds against the live ToolRegistry.
    /// Simple deterministic commands still bypass the LLM entirely via
    /// DeterministicRouter. The task state machine, ToolExecutor recovery chain,
    /// and Emergency Stop semantics are unchanged.
    static let shared = AgentLoop()

    /// Real planner metrics from the most recent run (for audit + UI).
    private let lastPlannerMetrics = LockedValue<MLXPlanner.PlannerMetrics?>(nil)
    /// Number of replans in the most recent run.
    private let lastReplanCount = LockedValue(0)

    /// Mandatory route attribution of the most recent run (planner reliability
    /// milestone). Deterministic commands, direct answers, refusals, planner
    /// runs, and escalations are reported SEPARATELY so no route's success can
    /// inflate another route's statistics. Reset at the start of every run.
    private let lastRoute = LockedValue<PipelineRoute?>(nil)
    /// True when the most recent run's plan came from the Tier-B/C escalation
    /// pipeline rather than the Tier-A planner (route attribution refinement).
    private let lastEscalationUsed = LockedValue(false)

    /// Route of the most recent run (nil before the first run). A planner run
    /// whose plan came from escalation is reported as .escalation, never .planner.
    func latestRoute() -> PipelineRoute? {
        if lastRoute.value == .planner && lastEscalationUsed.value { return .escalation }
        return lastRoute.value
    }

    /// Classification of a goal WITHOUT running it: the routing decision the
    /// pipeline WOULD make. Used by the benchmark/SelfTest for zero-cost route
    /// matrix checks that do not touch the model.
    nonisolated static func classifyRoute(for goal: String) async -> PipelineRoute {
        if await MainActor.run(body: { DeterministicRouter.shared.match(goal) }) != nil {
            return .deterministic
        }
        switch DirectAnswerRouter.decide(goal: goal) {
        case .directAnswer: return .directAnswer
        case .refusal: return .refusal
        case .planner: return .planner
        }
    }

    /// MainActor-synchronous variant of classifyRoute (SelfTest/benchmark run
    /// on the MainActor; matching the production order deterministically).
    /// DeterministicRouter first, then the DirectAnswerRouter decision.
    @MainActor static func classifyRouteSync(for goal: String) -> PipelineRoute {
        if DeterministicRouter.shared.match(goal) != nil { return .deterministic }
        switch DirectAnswerRouter.decide(goal: goal) {
        case .directAnswer: return .directAnswer
        case .refusal: return .refusal
        case .planner: return .planner
        }
    }

    func latestReplanCount() -> Int { lastReplanCount.value }

    /// Real planner metrics from the most recent run (nil after a fast-path
    /// deterministic hit, or before the first planner generation).
    func latestPlannerMetrics() -> MLXPlanner.PlannerMetrics? { lastPlannerMetrics.value }

    /// Set externally when the run's Task is cancelled (via onCancel in run()).
    private nonisolated(unsafe) static var cancellationObserved = LockedValue(false)
    /// Generation counter that makes emergency Cancel/flag-reset race-free:
    /// a new run must not inherit a stale emergency flag from a previous run.
    private nonisolated(unsafe) static var runGeneration = LockedValue(0)

    /// Emergency Stop: request cancellation of the in-flight agent run.
    /// Combined with the cooperative cancellation checks inside the loop and
    /// the TaskWorkerPool.cancelAll() path registered in EmergencyInterrupt.
    nonisolated func emergencyCancel() {
        Self.cancellationObserved.value = true
        JarvisLogger.security.fault("AgentLoop.emergencyCancel: in-flight agent run cancellation requested")
    }

    /// Current cancellation observation status (for tests & audits).
    nonisolated var isEmergencyCancelled: Bool {
        Self.cancellationObserved.value
    }

    /// Reset emergency cancellation status (for testing hygiene).
    nonisolated func resetEmergencyCancellation() {
        Self.cancellationObserved.value = false
    }

    private init() {}

    // MARK: - Public API

    /// Execute an autonomous compound goal through the full pipeline.
    func run(goal: String) async throws -> String {
        // Generational flag reset: a new run must not inherit (and must not
        // clear mid-flight) an emergency flag belonging to another run.
        Self.runGeneration.value += 1
        let myGeneration = Self.runGeneration.value
        Self.cancellationObserved.value = false
        defer {
            if Self.runGeneration.value == myGeneration {
                Self.cancellationObserved.value = false
            }
        }
        return try await runInternal(goal: goal)
    }

    /// CROSS-TURN MEMORY (production connection): record one interaction so
    /// the next user turn can reference it. Uses the existing
    /// ConversationManager — no new architecture, no new state system. Only
    /// COMPLETED interactions are recorded: failures surface their own truthful
    /// partial-state report, and a refusal is not something the assistant "did"
    /// — replaying it as a completed turn would fabricate a false action in
    /// memory. The user's request itself is still remembered either way.
    private func recordConversationTurn(goal: String, response: String?) {
        Task { @MainActor in
            ConversationManager.shared.addUserMessage(goal)
            if let response {
                let finalText = response.isEmpty ? "All actions executed and verified." : response
                ConversationManager.shared.addAssistantMessage(finalText)
                ConversationStore.shared.saveMessage(Message(role: .assistant, content: finalText))
            }
        }
    }

    private func runInternal(goal: String) async throws -> String {
        let timer = PipelineTimer()
        timer.mark(.actionStart)
        // Route attribution: set as soon as the route is decided, so every run
        // (success or failure) is attributed exactly once.
        lastEscalationUsed.value = false
        func attribute(_ route: PipelineRoute) { lastRoute.value = route }

        // 1. SENSE & UNDERSTAND (Data classification & permissions)
        let sensitivity = await DataClassifier.shared.classify(goal)
        JarvisLogger.brain.info("AgentLoop: Goal classified as \(sensitivity.rawValue)")

        let impact: PermissionGate.ActionImpact = sensitivity == .highlySensitive ? .destructive : .safeMutation
        _ = try await PermissionGate.shared.isAuthorized(actionName: "AgentLoop.run", impact: impact)

        // 2. FAST PATH: deterministic commands never touch the LLM (0ms router).
        // This preserves the Phase B/C fast path — only complex/ambiguous goals
        // reach the MLX planner.
        if let match = await MainActor.run(body: { DeterministicRouter.shared.match(goal) }) {
            JarvisLogger.brain.info("AgentLoop: deterministic fast path hit for '\(goal)'")
            attribute(.deterministic)
            // The declared impact is enforced inside ActionEngine via the
            // PermissionGate — the fast path obeys the same authority policy
            // as planned tool execution.
            let output = try await ActionEngine.shared.execute(
                intent: match.intent,
                isDeterministic: true,
                impact: match.impact,
                action: match.action)
            lastReplanCount.value = 0
            lastPlannerMetrics.value = nil
            recordConversationTurn(goal: goal, response: output)
            return output
        }
        // 3. DIRECT-ANSWER / REFUSAL ROUTE: narrow deterministic decision before
        // the planner. Obvious conversational/knowledge requests get a real
        // direct answer from the local model without planning. Unsupported or
        // unsafe requests are EXPLICITLY refused (typed, auditable) instead of
        // accidentally becoming a valid unrelated tool call. Genuine tool tasks
        // and ambiguous goals fall forward to the planner unchanged.
        switch DirectAnswerRouter.decide(goal: goal) {
        case .refusal(let reason):
            JarvisLogger.brain.info("AgentLoop: explicit refusal (\(reason.rawValue)) for goal '\(goal, privacy: .public)'")
            attribute(.refusal)
            lastReplanCount.value = 0
            lastPlannerMetrics.value = nil
            // Memory records the REQUEST (never a fake assistant action), so a
            // follow-up clarification ("what can you do instead?") has context.
            Task { @MainActor in
                ConversationManager.shared.addUserMessage(goal)
            }
            return reason.userFacingMessage
        case .directAnswer:
            JarvisLogger.brain.info("AgentLoop: direct-answer route for '\(goal, privacy: .public)'")
            do {
                let answer = try await DirectComposer().composeAnswer(goal: goal, observations: [])
                attribute(.directAnswer)
                lastReplanCount.value = 0
                lastPlannerMetrics.value = nil
                recordConversationTurn(goal: goal, response: answer)
                return answer
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Direct answer failed → fall forward to the planner (never fake).
                JarvisLogger.brain.warning("Direct-answer composition failed (\(error.localizedDescription)); falling forward to planner")
            }
        case .planner:
            break
        }

        // 4. PLAN via the real local MLX model (structured, validated, bounded).
        let stateMachine = TaskStateMachine.shared
        // Evidence ledger: the harness (or a self-contained run) owns the scope;
        // MLXPlanner.plan(goal:context:taskID:) attributes every attempt of THIS
        // run (initial + all replan cycles) to one runID + taskID.
        let task = stateMachine.createTask(
            title: "Autonomous Goal",
            goal: goal,
            environmentContext: TaskEnvironmentContext.captureLive()
        )
        try stateMachine.transition(taskId: task.id, to: .planning)

        // Experiment A: sequential next-step planning. When enabled, each
        // planning generation produces the NEXT SINGLE action; validate →
        // compile → execute → observe → verify → update Task State → repeat.
        // Deterministic authority, PermissionGate, ToolExecutor, verification,
        // and the recovery chain are all unchanged. A partial completion can
        // never report success: the loop continues until the model signals
        // DONE or the bounded attempt budget is exhausted.
        if SequentialExperiment.mode == .sequential {
            return try await runSequential(
                goal: goal, task: task, stateMachine: stateMachine)
        }

        attribute(.planner)
        var plannerContext = PlannerContext.initial(goal: goal)
        // Decomposed planning first for SINGLE-ACTION goals (planner
        // reliability milestone): the model selects ONE tool and extracts the
        // user's literal; the deterministic compiler builds the plan.
        // Compound/multi-step goals keep the legacy whole-plan path — the same
        // conservatism the deterministic router applies — because the bounded
        // extraction is structurally a ONE-tool decision. On extraction failure
        // the EXISTING whole-plan prompt runs through the unchanged recovery
        // chain (lossless escalation context preserved): the fallback is
        // structural, never a semantic rewrite of the user's request.
        let loweredGoal = goal.lowercased()
        let compoundMarkers = [" and ", " then ", ";", "&&", ", then", " also "]
        // Quoted spans are literal CONTENT, not clause structure: a goal like
        // print the line "ready, set; go!" is ONE request even though the
        // quoted literal contains ';'. Strip quoted spans before the marker
        // scan so in-literal punctuation cannot force the legacy whole-plan
        // path (unquoted separators still compound as before).
        var compoundScan = loweredGoal
        for quote in ["\"", "'"] {
            let parts = compoundScan.split(separator: quote, omittingEmptySubsequences: false)
            if parts.count >= 3 {
                compoundScan = parts.enumerated().map { $0.offset % 2 == 0 ? String($0.element) : "" }.joined()
            }
        }
        let isCompoundGoal = compoundMarkers.contains { compoundScan.contains($0) }
        var plan: AgentPlan
        if isCompoundGoal {
            plan = try await planWithRecovery(
                goal: goal, context: plannerContext, taskId: task.id, stateMachine: stateMachine)
        } else {
            do {
                plan = try await MLXPlanner.shared.planDecomposed(goal: goal, taskID: task.id)
                if let metrics = await MLXPlanner.shared.latestMetrics() {
                    lastPlannerMetrics.value = metrics
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                JarvisLogger.brain.warning("Decomposed extraction failed (\(error.localizedDescription)); falling back to whole-plan prompt")
                plannerContext = plannerContext.with(
                    failure: error.localizedDescription,
                    observations: [])
                plan = try await planWithRecovery(
                    goal: goal, context: plannerContext, taskId: task.id, stateMachine: stateMachine)
            }
        }
        // Recency safety net (deterministic, post-validation): a
        // freshness-sensitive goal can never be answered by a composition-only
        // plan — the compiler replaces it with a real web_search step.
        plan = PlannerExtraction.enforceRecency(plan: plan, goal: goal)
        try stateMachine.setSteps(taskId: task.id, steps: toTaskSteps(plan))

        // 4. EXECUTE -> OBSERVE -> VERIFY -> RECOVER loop
        try stateMachine.transition(taskId: task.id, to: .running)

        var completedOutputs: [String] = []
        var observations: [String] = []
        var replanCount = 0
        var lastFailure: (stepNumber: Int, purpose: String, tool: String?, error: String)?
        // Total attempts across the whole task (initial pass + replans), bounded.
        let maxTotalAttempts = 3 + plan.steps.count

        var attempt = 0
        var stepIndex = 0

        while stepIndex < plan.steps.count {
            attempt += 1
            guard attempt <= maxTotalAttempts else {
                let failMsg = lastFailure.map { "Step \($0.stepNumber) ('\($0.purpose)') failed: \($0.error)" }
                    ?? "Max agent attempts exceeded (\(maxTotalAttempts))"
                try stateMachine.transition(taskId: task.id, to: .failed, error: failMsg)
                if let failure = lastFailure {
                    _ = try? stateMachine.updateStep(taskId: task.id, stepIndex: failure.stepNumber - 1, state: .failed, error: failure.error)
                    _ = try? stateMachine.markStepVerification(taskId: task.id, stepIndex: failure.stepNumber - 1, outcome: .failed)
                }
                throw JarvisError.actionFailed(action: lastFailure?.tool ?? "AgentLoop.run", reason: failMsg)
            }

            let step = plan.steps[stepIndex]
            try? stateMachine.setCurrentStepIndex(taskId: task.id, index: stepIndex)

            do {
                // Cooperative cancellation points: task cancellation (user or
                // Emergency Stop) and terminal task state (emergency path).
                try Task.checkCancellation()
                if Self.cancellationObserved.value {
                    try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                    throw CancellationError()
                }
                if let current = stateMachine.getTask(id: task.id), current.state == .cancelled {
                    throw CancellationError()
                }

                try stateMachine.updateStep(taskId: task.id, stepIndex: stepIndex, state: .running)

                if let toolName = step.toolName {
                    // 1. Fetch current resolution records & ambient context
                    let resolutionRecords = stateMachine.resolutionRecords(for: task.id)
                    var envContext = stateMachine.environmentContext(for: task.id)
                    if envContext == nil {
                        envContext = TaskEnvironmentContext.captureLive()
                        _ = try? stateMachine.setEnvironmentContext(envContext!, for: task.id)
                    }

                    // 2. Fetch tool parameter spec
                    guard let tool = await MainActor.run(body: { ToolRegistry.shared.getTool(named: toolName) }) else {
                        throw JarvisError.actionFailed(action: toolName, reason: "Tool '\(toolName)' is not registered")
                    }

                    // 3. Resolve arguments deterministically (Reference Resolution)
                    let currentStepNumber = stepIndex + 1
                    let args = try ReferenceResolver.resolveStepArguments(
                        rawArguments: step.arguments,
                        currentStepNumber: currentStepNumber,
                        toolParameterSpecs: tool.parameterSpec,
                        resolutionRecords: resolutionRecords,
                        environmentContext: envContext
                    )

                    // 4. Sandbox re-check on resolved shell command (Permission evaluation sees resolved value)
                    if toolName == "run_shell", let resolvedCmd = args["command"] as? String {
                        guard await MainActor.run(body: { CommandSandbox.shared.isSafe(resolvedCmd) }) else {
                            throw JarvisError.actionFailed(
                                action: "run_shell",
                                reason: "Resolved command rejected by CommandSandbox: \(resolvedCmd)"
                            )
                        }
                    }

                    // 5. EXECUTE (ToolExecutor does permission gate + execute + observe + verify)
                    let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)
                    // Argument-preservation instrumentation: record the executed
                    // (post-reference-resolution) values for the most recent
                    // planner compilation of this goal. No-op when the run was
                    // not planner-routed (deterministic/direct-answer/refusal).
                    let stringArgs = args.reduce(into: [String: String]()) { dict, pair in
                        dict[pair.key] = "\(pair.value)"
                    }
                    await MainActor.run {
                        ArgumentPreservationRecorder.shared.noteExecution(
                            goal: goal, resolvedArguments: stringArgs)
                    }

                    // Emergency Stop / cancel may have fired during execution:
                    // do not record this step as completed if so.
                    if Self.cancellationObserved.value {
                        try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                        throw CancellationError()
                    }

                    // OBSERVE: consume the actual tool output (real result text).
                    observations.append("[\(toolName)] \(result.output)")

                    // VERIFY at the outcome level, beyond ToolExecutor's
                    // expected.success check: empty/failed output fails the
                    // step — UNLESS the tool's own deterministic verification
                    // passed. A redirecting command (`echo x > file`) legitimately
                    // writes the artifact and prints nothing; failing that step
                    // contradicts the executor's exit-code/file verification and
                    // triggers spurious replanning.
                    if !AgentStepOutcomePolicy.accepts(result) {
                        _ = try? stateMachine.markStepVerification(
                            taskId: task.id, stepIndex: stepIndex, outcome: .failed)
                        throw JarvisError.verificationFailed(
                            action: toolName,
                            expected: "meaningful output",
                            actual: result.output)
                    }
                    let stepOutcome = result.verification?.outcome ?? .passed
                    _ = try? stateMachine.markStepVerification(
                        taskId: task.id, stepIndex: stepIndex, outcome: stepOutcome)

                    // RECORD Resolution Record on stateMachine (for subsequent steps to reference)
                    let record = StepResolutionRecord(
                        stepNumber: currentStepNumber,
                        toolName: toolName,
                        rawOutput: result.output,
                        structuredOutput: nil,
                        completedAt: Date(),
                        verification: stepOutcome
                    )
                    _ = try? stateMachine.appendResolutionRecord(record, for: task.id)

                    try stateMachine.updateStep(
                        taskId: task.id,
                        stepIndex: stepIndex,
                        state: .completed,
                        output: result.output)
                    completedOutputs.append(result.output)
                    stepIndex += 1
                } else {
                    // Composition step (tool:null): produce a REAL direct answer
                    // with one bounded local-model generation conditioned on the
                    // goal + actual observations. Action purposes can NEVER be
                    // satisfied by composition without an executable tool.
                    let lowerPurpose = step.purpose.lowercased()
                    let actionVerbs = ["execute", "run ", "write", "save", "read", "open ", "set ", "download", "fetch", "search"]
                    if actionVerbs.contains(where: { lowerPurpose.contains($0) }) {
                        throw JarvisError.actionFailed(
                            action: "AgentLoop.executeStep",
                            reason: "Step '\(step.id)' requires an executable tool for action '\(step.purpose)', cannot compose answer")
                    }

                    let composed: String
                    do {
                        composed = try await DirectComposer().composeAnswer(
                            goal: goal, observations: observations)
                    } catch is CancellationError {
                        try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                        throw CancellationError()
                    } catch {
                        JarvisLogger.brain.warning("Direct composition failed, using planner purpose: \(error.localizedDescription)")
                        composed = step.purpose
                    }
                    completedOutputs.append(composed)
                    try stateMachine.updateStep(
                        taskId: task.id,
                        stepIndex: stepIndex,
                        state: .completed,
                        output: completedOutputs.last)
                    _ = try? stateMachine.markStepVerification(
                        taskId: task.id, stepIndex: stepIndex, outcome: .notApplicable)
                    stepIndex += 1
                }

            } catch is CancellationError {
                try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                throw CancellationError()
            } catch {
                // RECOVER: real failure -> existing recovery chain (unchanged).
                replanCount += 1
                lastReplanCount.value = replanCount
                JarvisLogger.actions.warning("Step '\(step.purpose)' failed (replan \(replanCount)): \(error.localizedDescription)")

                lastFailure = (stepNumber: stepIndex + 1, purpose: step.purpose, tool: step.toolName, error: error.localizedDescription)
                _ = try? stateMachine.updateStep(taskId: task.id, stepIndex: stepIndex, state: .failed, error: error.localizedDescription)
                _ = try? stateMachine.markStepVerification(taskId: task.id, stepIndex: stepIndex, outcome: .failed)

                try stateMachine.transition(taskId: task.id, to: .failed, error: error.localizedDescription)
                try stateMachine.transition(taskId: task.id, to: .recovering)
                try stateMachine.transition(taskId: task.id, to: .replanning)
                try? stateMachine.incrementRetryCount(taskId: task.id)

                // REPLAN with real failure context (not a blind repeat): the
                // planner sees the actual error and prior observations.
                if Self.cancellationObserved.value {
                    try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                    throw CancellationError()
                }
                plannerContext = plannerContext.with(
                    failure: error.localizedDescription,
                    observations: observations)

                // Lossless escalation to Tier B when repeated execution replans fail
                let isEscalationEnabled = await MainActor.run { EscalationPipeline.shared.isEnabled }
                if replanCount >= 2 && isEscalationEnabled {
                    let currentTask = stateMachine.getTask(id: task.id)
                    let resolutionRecords = stateMachine.resolutionRecords(for: task.id)
                    var verifiedOutputs: [Int: String] = [:]
                    for rec in resolutionRecords.values where rec.verification == .passed {
                        verifiedOutputs[rec.stepNumber] = rec.rawOutput
                    }
                    let env = stateMachine.environmentContext(for: task.id)
                    let sensitivity = await MainActor.run { DataClassifier.shared.classify(goal) }

                    let currentTaskStep = currentTask?.steps.indices.contains(stepIndex) == true ? currentTask?.steps[stepIndex] : nil
                    let escalationContext = EscalationContext(
                        taskId: task.id,
                        originalGoal: goal,
                        currentStepNumber: stepIndex + 1,
                        completedSteps: currentTask?.steps.filter { $0.state == .completed } ?? [],
                        verifiedOutputs: verifiedOutputs,
                        failedStep: currentTaskStep,
                        failureReason: error.localizedDescription,
                        priorObservations: observations,
                        environmentContext: env,
                        sensitivity: sensitivity,
                        triggerReason: .executionFailureReplanning,
                        attemptCount: replanCount
                    )

                    do {
                        plan = try await EscalationPipeline.shared.escalate(context: escalationContext)
                        lastEscalationUsed.value = true
                        let existingSteps = stateMachine.getTask(id: task.id)?.steps ?? []
                        try stateMachine.setSteps(taskId: task.id, steps: toTaskSteps(plan, preservingCompletedFrom: existingSteps))
                        let completedCount = existingSteps.filter { $0.state == .completed }.count
                        if stepIndex >= plan.steps.count { stepIndex = max(stepIndex, completedCount) }
                        try stateMachine.transition(taskId: task.id, to: .running)
                        continue
                    } catch {
                        JarvisLogger.brain.warning("Tier B execution replan escalation failed: \(error.localizedDescription)")
                    }
                }

                do {
                    plan = try await planWithRecovery(
                        goal: goal, context: plannerContext, taskId: task.id, stateMachine: stateMachine)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // RECOVERY-FAILED REPORTING (final-response accuracy): the
                    // replan itself failed, so the run cannot continue. The raw
                    // recovery error (e.g. a Tier-B infrastructure failure)
                    // says nothing about what the task actually DID. Report the
                    // PARTIAL completion — completed-step count plus the actual
                    // failed step — from the TaskState recorded before the
                    // replan, and close the task out as FAILED (it is in
                    // REPLANNING here, from which FAILED is the legal exit).
                    // The recovery chain above is unchanged; only the final
                    // user-facing report is fixed here.
                    JarvisLogger.brain.warning("Recovery after step failure failed: \(error.localizedDescription)")
                    let completedStepCount = stateMachine.getTask(id: task.id)?.steps.filter {
                        $0.state == .completed && ($0.verification?.isVerified == true || $0.verification == .notApplicable)
                    }.count ?? completedOutputs.count
                    let reason = Self.partialCompletionReport(
                        completedStepCount: completedStepCount, lastFailure: lastFailure)
                    try stateMachine.transition(taskId: task.id, to: .failed, error: reason)
                    throw JarvisError.actionFailed(
                        action: lastFailure?.tool ?? "AgentLoop.run", reason: reason)
                }
                let existingSteps = stateMachine.getTask(id: task.id)?.steps ?? []
                try stateMachine.setSteps(taskId: task.id, steps: toTaskSteps(plan, preservingCompletedFrom: existingSteps))
                // A replan preserves completed steps and continues execution;
                // do not reset stepIndex backwards into already-completed steps.
                let completedCount = existingSteps.filter { $0.state == .completed }.count
                if stepIndex >= plan.steps.count {
                    stepIndex = max(stepIndex, completedCount)
                }
                try stateMachine.transition(taskId: task.id, to: .running)
            }
        }

        // 5. VERIFY & RESPOND
        let finalTask = stateMachine.getTask(id: task.id)
        let finalSteps = finalTask?.steps ?? []
        let allCompletedAndVerified = !finalSteps.isEmpty && finalSteps.allSatisfy {
            $0.state == .completed && ($0.verification?.isVerified == true || $0.verification == .notApplicable)
        }
        guard allCompletedAndVerified else {
            let failMsg = lastFailure.map { "Step \($0.stepNumber) ('\($0.purpose)') failed: \($0.error)" }
                ?? "Task incomplete: not all steps completed and verified"
            try stateMachine.transition(taskId: task.id, to: .failed, error: failMsg)
            if let failure = lastFailure {
                _ = try? stateMachine.updateStep(taskId: task.id, stepIndex: failure.stepNumber - 1, state: .failed, error: failure.error)
                _ = try? stateMachine.markStepVerification(taskId: task.id, stepIndex: failure.stepNumber - 1, outcome: .failed)
            }
            throw JarvisError.actionFailed(
                action: lastFailure?.tool ?? "AgentLoop.run",
                reason: failMsg
            )
        }

        try stateMachine.transition(taskId: task.id, to: .verifying)
        try stateMachine.transition(taskId: task.id, to: .completed)

        let response = completedOutputs.joined(separator: "\n")
        JarvisLogger.brain.info("AgentLoop completed goal successfully: \(response)")

        // CROSS-TURN MEMORY (production connection): record this interaction so
        // the next user turn can reference it. Response text only; nothing is
        // inferred from state or output text.
        recordConversationTurn(goal: goal, response: response)

        return response.isEmpty ? "All actions executed and verified." : response
    }

    // MARK: - Experiment A: sequential next-step execution

    /// Sequential next-step execution loop (Experiment A only).
    /// Reuses: PlanValidator/AgentPlanParser (via planNextStep), ToolExecutor
    /// (permission + execute + observe + verify), TaskStateMachine lifecycle,
    /// DirectComposer for tool:null composition, and the bounded recovery
    /// chain. NOT reused: nothing is modified — this is a parallel path.
    private func runSequential(
        goal: String,
        task: JarvisTask,
        stateMachine: TaskStateMachine
    ) async throws -> String {
        var completedSteps: [(tool: String?, command: String?, purpose: String, output: String?)] = []
        var observations: [String] = []
        var replanCount = 0
        var stepNumber = 0
        // Bound: deterministic, per-task attempt budget (steps + margin for
        // invalid next-step generations + recovery). Hard cap prevents loops.
        let maxGenerations = 8
        var generationCount = 0

        try stateMachine.transition(taskId: task.id, to: .running)

        while generationCount < maxGenerations {
            try Task.checkCancellation()
            if Self.cancellationObserved.value {
                try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                throw CancellationError()
            }
            if let current = stateMachine.getTask(id: task.id), current.state == .cancelled {
                throw CancellationError()
            }

            // Next-step generation happens while the task is RUNNING (the only
            // legal state that can reach .failed/.recovering/.replanning and
            // back). Planning-phase evidence lives in the ledger + snapshots.
            generationCount += 1
            var plan: AgentPlan
            do {
                plan = try await MLXPlanner.shared.planNextStep(
                    goal: goal,
                    completedSteps: completedSteps,
                    nextStepIndex: stepNumber,
                    taskID: task.id)
            } catch is CancellationError {
                try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                throw CancellationError()
            } catch {
                // Bounded recovery: one retry of the next-step generation, then
                // fail safely (same chain shape as planWithRecovery).
                replanCount += 1
                lastReplanCount.value = replanCount
                if Self.cancellationObserved.value {
                    try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                    throw CancellationError()
                }
                try stateMachine.transition(taskId: task.id, to: .failed, error: "Next-step planning failed: \(error.localizedDescription)")
                try stateMachine.transition(taskId: task.id, to: .recovering)
                try stateMachine.transition(taskId: task.id, to: .replanning)
                // Bug A regression guard: the retry generation must happen in
                // RUNNING — the only state from which the loop's later
                // failed/verifying transitions are legal. Leaving the task in
                // REPLANNING here would make the later DONE-accept path attempt
                // the illegal REPLANNING → VERIFYING transition.
                try stateMachine.transition(taskId: task.id, to: .running)
                try? stateMachine.incrementRetryCount(taskId: task.id)
                do {
                    plan = try await MLXPlanner.shared.planNextStep(
                        goal: goal,
                        completedSteps: completedSteps,
                        nextStepIndex: stepNumber,
                        taskID: task.id)
                } catch {
                    try stateMachine.transition(taskId: task.id, to: .failed, error: "Next-step planning failed after recovery: \(error.localizedDescription)")
                    throw JarvisError.actionFailed(
                        action: "AgentLoop.runSequential",
                        reason: "Next-step planning failed after recovery: \(error.localizedDescription)")
                }
            }

            // Model signaled completion — the plan is empty. Partial-plan
            // safety (§8): DONE with ZERO completed steps can never be success
            // (nothing was executed). Treat it as an invalid response and
            // retry through the normal bounded path.
            if plan.steps.isEmpty {
                if completedSteps.isEmpty {
                    JarvisLogger.actions.warning("Sequential: model signaled DONE with zero completed steps — rejected as invalid")
                    try stateMachine.transition(taskId: task.id, to: .failed, error: "DONE signaled with no completed steps")
                    try stateMachine.transition(taskId: task.id, to: .recovering)
                    try stateMachine.transition(taskId: task.id, to: .replanning)
                    try stateMachine.transition(taskId: task.id, to: .running)
                    continue
                }
                // Deterministic completion gate (§6): the model's "DONE" text is
                // never authority by itself. Completion additionally requires
                // deterministic state evidence: ≥1 recorded step AND every
                // recorded step explicitly verified .passed in task state. A
                // premature DONE (e.g. after 1 of 3 intended steps) still lands
                // on this accept path — goal-level completeness is judged by
                // the benchmark harness, which reports NOT_COMPLETE, never by
                // trusting the model's declaration.
                let recordedSteps = stateMachine.getTask(id: task.id)?.steps ?? []
                let allVerified = !recordedSteps.isEmpty
                    && recordedSteps.allSatisfy { $0.verification == .passed }
                guard allVerified else {
                    JarvisLogger.actions.warning("Sequential: model signaled DONE without verified-step evidence — rejected as invalid")
                    try stateMachine.transition(taskId: task.id, to: .failed, error: "DONE not backed by verified completed steps")
                    try stateMachine.transition(taskId: task.id, to: .recovering)
                    try stateMachine.transition(taskId: task.id, to: .replanning)
                    try stateMachine.transition(taskId: task.id, to: .running)
                    continue
                }
                try stateMachine.transition(taskId: task.id, to: .verifying)
                try stateMachine.transition(taskId: task.id, to: .completed)
                let response = completedSteps.compactMap(\.output).joined(separator: "\n")
                // CROSS-TURN MEMORY: record the sequential-path interaction so
                // the next user turn can reference it (same contract as the
                // whole-plan path's success exit).
                recordConversationTurn(goal: goal, response: response)
                return response.isEmpty ? "All actions executed and verified." : response
            }
            guard let step = plan.steps.first else {
                throw JarvisError.actionFailed(action: "runSequential", reason: "empty plan after DONE check")
            }
            // Deterministic no-progress guard: if the model's "next action"
            // exactly repeats an already-completed step (same tool + same
            // arguments), executing it again is NOT progress. Discard this
            // generation (budget still consumed) so the loop cannot oscillate
            // forever on a repeating model.
            let stepKey = (step.toolName ?? "") + "|" + step.arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
            let completedKeys = Set(completedSteps.map { ($0.tool ?? "") + "|" + ($0.command.map { "command=\($0)" } ?? "") })
            if completedKeys.contains(stepKey) {
                JarvisLogger.actions.warning("Sequential: model repeated completed step (\(stepKey.prefix(80))) — discarded, no progress")
                try stateMachine.transition(taskId: task.id, to: .failed, error: "Model repeated a completed step (no progress)")
                try stateMachine.transition(taskId: task.id, to: .recovering)
                try stateMachine.transition(taskId: task.id, to: .replanning)
                try stateMachine.transition(taskId: task.id, to: .running)
                continue
            }
            stepNumber += 1
            try? stateMachine.setCurrentStepIndex(taskId: task.id, index: stepNumber - 1)
            // Replace the task's step list with executed history + the new step
            // (append-only progress view; snapshots preserve every cycle).
            var allSteps = stateMachine.getTask(id: task.id)?.steps ?? []
            let newStep = TaskStep(
                stepNumber: stepNumber,
                description: step.purpose,
                toolName: step.toolName,
                arguments: step.arguments)
            allSteps.append(newStep)
            try? stateMachine.setSteps(taskId: task.id, steps: allSteps)

            do {
                try stateMachine.updateStep(taskId: task.id, stepIndex: allSteps.count - 1, state: .running)
                guard let toolName = step.toolName else {
                    throw JarvisError.actionFailed(action: "runSequential", reason: "composition step not supported in sequential mode")
                }
                let resolutionRecords = stateMachine.resolutionRecords(for: task.id)
                var envContext = stateMachine.environmentContext(for: task.id)
                if envContext == nil {
                    envContext = TaskEnvironmentContext.captureLive()
                    _ = try? stateMachine.setEnvironmentContext(envContext!, for: task.id)
                }
                guard let tool = await MainActor.run(body: { ToolRegistry.shared.getTool(named: toolName) }) else {
                    throw JarvisError.actionFailed(action: toolName, reason: "Tool '\(toolName)' is not registered")
                }
                let args = try ReferenceResolver.resolveStepArguments(
                    rawArguments: step.arguments,
                    currentStepNumber: stepNumber,
                    toolParameterSpecs: tool.parameterSpec,
                    resolutionRecords: resolutionRecords,
                    environmentContext: envContext
                )
                if toolName == "run_shell", let resolvedCmd = args["command"] as? String {
                    guard await MainActor.run(body: { CommandSandbox.shared.isSafe(resolvedCmd) }) else {
                        throw JarvisError.actionFailed(
                            action: "run_shell",
                            reason: "Resolved command rejected by CommandSandbox: \(resolvedCmd)"
                        )
                    }
                }
                let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)

                if Self.cancellationObserved.value {
                    try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                    throw CancellationError()
                }
                if !AgentStepOutcomePolicy.accepts(result) {
                    _ = try? stateMachine.markStepVerification(
                        taskId: task.id, stepIndex: allSteps.count - 1, outcome: .failed)
                    throw JarvisError.verificationFailed(
                        action: toolName, expected: "meaningful output", actual: result.output)
                }
                let stepOutcome = result.verification?.outcome ?? .passed
                _ = try? stateMachine.markStepVerification(
                    taskId: task.id, stepIndex: allSteps.count - 1, outcome: stepOutcome)
                try stateMachine.updateStep(
                    taskId: task.id, stepIndex: allSteps.count - 1, state: .completed,
                    output: result.output)
                let command = step.arguments["command"]
                completedSteps.append((tool: toolName, command: command, purpose: step.purpose, output: result.output))
                observations.append("[\(toolName)] \(result.output)")
            } catch is CancellationError {
                try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                throw CancellationError()
            } catch {
                // RECOVER: same chain as the full-plan path (FAILED → RECOVERING
                // → REPLANNING), then the loop plans a NEW next step with the
                // failure context implicit in the completed-steps list (the
                // failed step is NOT appended, so the model does not see it as
                // completed).
                replanCount += 1
                lastReplanCount.value = replanCount
                JarvisLogger.actions.warning("Sequential step '\(step.purpose)' failed (replan \(replanCount)): \(error.localizedDescription)")
                try stateMachine.transition(taskId: task.id, to: .failed, error: error.localizedDescription)
                try stateMachine.transition(taskId: task.id, to: .recovering)
                try stateMachine.transition(taskId: task.id, to: .replanning)
                try? stateMachine.incrementRetryCount(taskId: task.id)
                try stateMachine.transition(taskId: task.id, to: .running)
                // Drop the partially-appended step from the task's step list so
                // the next generation plans it fresh (bounded by maxGenerations).
                var allSteps = stateMachine.getTask(id: task.id)?.steps ?? []
                if !allSteps.isEmpty { allSteps.removeLast() }
                try? stateMachine.setSteps(taskId: task.id, steps: allSteps)
            }
        }

        // Attempt budget exhausted WITHOUT the model signaling DONE: this is a
        // partial completion. Never report success (§8 partial-plan safety):
        // the only success exits in this loop require an explicit model DONE
        // signal that is backed by deterministically verified task state.
        // Budget expiry → FAILED, never success (§6 completion safety).
        try stateMachine.transition(taskId: task.id, to: .failed, error: "Sequential planning attempt budget exhausted before DONE")
        throw JarvisError.actionFailed(
            action: "AgentLoop.runSequential",
            reason: "Sequential planning exhausted \(maxGenerations) generations without completion (partial plan not reported as success)")
    }

    // MARK: - Planning

    /// Plan through the MLXPlanner; a planning failure enters the same recovery
    /// chain as execution failures, bounded by the same attempt budget.
    private func planWithRecovery(
        goal: String,
        context: PlannerContext,
        taskId: UUID,
        stateMachine: TaskStateMachine
    ) async throws -> AgentPlan {
        do {
            let plan = try await MLXPlanner.shared.plan(goal: goal, context: context, taskID: taskId)
            if let metrics = await MLXPlanner.shared.latestMetrics() {
                lastPlannerMetrics.value = metrics
            }
            return plan
        } catch is CancellationError {
            _ = try? stateMachine.transition(taskId: taskId, to: .cancelled, error: "Agent task cancelled during planning")
            throw CancellationError()
        } catch {
            // Emergency Stop must bypass the recovery chain entirely: no
            // replanning after an emergency cancellation request.
            if Self.cancellationObserved.value {
                _ = try? stateMachine.transition(taskId: taskId, to: .cancelled, error: "Agent task cancelled")
                throw CancellationError()
            }
            // PLANNING -> FAILED -> RECOVERING -> REPLANNING -> retry, bounded.
            // A second consecutive planning failure propagates or escalates.
            try stateMachine.transition(taskId: taskId, to: .failed, error: "Planner failed: \(error.localizedDescription)")
            try stateMachine.transition(taskId: taskId, to: .recovering)
            try stateMachine.transition(taskId: taskId, to: .replanning)
            try? stateMachine.incrementRetryCount(taskId: taskId)
            do {
                let retryPlan = try await MLXPlanner.shared.plan(goal: goal, context: context, taskID: taskId)
                if let metrics = await MLXPlanner.shared.latestMetrics() {
                    lastPlannerMetrics.value = metrics
                }
                return retryPlan
            } catch is CancellationError {
                _ = try? stateMachine.transition(taskId: taskId, to: .cancelled, error: "Agent task cancelled during planning")
                throw CancellationError()
            } catch {
                // Tier A planning exhausted after retry: lossless escalation to Tier B if enabled
                let isEscalationEnabled = await MainActor.run { EscalationPipeline.shared.isEnabled }
                if isEscalationEnabled {
                    let task = stateMachine.getTask(id: taskId)
                    let resolutionRecords = stateMachine.resolutionRecords(for: taskId)
                    var verifiedOutputs: [Int: String] = [:]
                    for rec in resolutionRecords.values where rec.verification == .passed {
                        verifiedOutputs[rec.stepNumber] = rec.rawOutput
                    }
                    let env = stateMachine.environmentContext(for: taskId)
                    let sensitivity = await MainActor.run { DataClassifier.shared.classify(goal) }

                    let escalationContext = EscalationContext(
                        taskId: taskId,
                        originalGoal: goal,
                        currentStepNumber: 1,
                        completedSteps: task?.steps.filter { $0.state == .completed } ?? [],
                        verifiedOutputs: verifiedOutputs,
                        failedStep: nil,
                        failureReason: error.localizedDescription,
                        priorObservations: context.priorObservations,
                        environmentContext: env,
                        sensitivity: sensitivity,
                        triggerReason: .tierAPlanningExhausted,
                        attemptCount: 2
                    )

                    do {
                        let escalatedPlan = try await EscalationPipeline.shared.escalate(context: escalationContext)
                        lastEscalationUsed.value = true
                        return escalatedPlan
                    } catch {
                        JarvisLogger.brain.warning("Tier B escalation failed: \(error.localizedDescription)")
                        throw error
                    }
                }
                throw error
            }
        }
    }

    /// Convert validated plan steps into state-machine TaskSteps, preserving
    /// any already-completed step states and verified outputs.
    private func toTaskSteps(_ plan: AgentPlan, preservingCompletedFrom existingSteps: [TaskStep] = []) -> [TaskStep] {
        plan.steps.enumerated().map { index, step in
            if index < existingSteps.count && existingSteps[index].state == .completed {
                return existingSteps[index]
            }
            return TaskStep(
                stepNumber: index + 1,
                description: step.purpose,
                toolName: step.toolName,
                arguments: step.arguments)
        }
    }
}
