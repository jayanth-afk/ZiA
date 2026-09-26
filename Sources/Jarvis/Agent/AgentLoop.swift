import Foundation

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
actor AgentLoop {
    static let shared = AgentLoop()

    /// Real planner metrics from the most recent run (for audit + UI).
    private let lastPlannerMetrics = LockedValue<MLXPlanner.PlannerMetrics?>(nil)
    /// Number of replans in the most recent run.
    private let lastReplanCount = LockedValue(0)

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
    func emergencyCancel() {
        Self.cancellationObserved.value = true
        JarvisLogger.security.fault("AgentLoop.emergencyCancel: in-flight agent run cancellation requested")
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

    private func runInternal(goal: String) async throws -> String {
        let timer = PipelineTimer()
        timer.mark(.actionStart)

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
            lastReplanCount.value = 0
            lastPlannerMetrics.value = nil
            return reason.userFacingMessage
        case .directAnswer:
            JarvisLogger.brain.info("AgentLoop: direct-answer route for '\(goal, privacy: .public)'")
            do {
                let answer = try await DirectComposer().composeAnswer(goal: goal, observations: [])
                lastReplanCount.value = 0
                lastPlannerMetrics.value = nil
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
        let task = stateMachine.createTask(title: "Autonomous Goal", goal: goal)
        try stateMachine.transition(taskId: task.id, to: .planning)

        var plannerContext = PlannerContext.initial(goal: goal)
        var plan = try await planWithRecovery(
            goal: goal, context: plannerContext, taskId: task.id, stateMachine: stateMachine)
        try stateMachine.setSteps(taskId: task.id, steps: toTaskSteps(plan))

        // 4. EXECUTE -> OBSERVE -> VERIFY -> RECOVER loop
        try stateMachine.transition(taskId: task.id, to: .running)

        var completedOutputs: [String] = []
        var observations: [String] = []
        var replanCount = 0
        // Total attempts across the whole task (initial pass + replans), bounded.
        let maxTotalAttempts = 3 + plan.steps.count

        var attempt = 0
        var stepIndex = 0

        while stepIndex < plan.steps.count {
            attempt += 1
            guard attempt <= maxTotalAttempts else {
                try stateMachine.transition(taskId: task.id, to: .failed, error: "Max agent attempts exceeded")
                throw JarvisError.actionFailed(action: "AgentLoop.run", reason: "Max agent attempts exceeded (\(maxTotalAttempts))")
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
                    var args: [String: any Sendable] = [:]
                    for (k, v) in step.arguments { args[k] = v }

                    // EXECUTE (ToolExecutor does permission gate + execute + observe + verify)
                    let result = try await ToolExecutor.shared.execute(toolName: toolName, arguments: args)

                    // Emergency Stop / cancel may have fired during execution:
                    // do not record this step as completed if so.
                    if Self.cancellationObserved.value {
                        try stateMachine.transition(taskId: task.id, to: .cancelled, error: "Agent task cancelled")
                        throw CancellationError()
                    }

                    // OBSERVE: consume the actual tool output (real result text).
                    completedOutputs.append(result.output)
                    observations.append("[\(toolName)] \(result.output)")

                    // VERIFY at the outcome level, beyond ToolExecutor's
                    // expected.success check: empty/failed output fails the step.
                    if !result.success || result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try? stateMachine.markStepVerification(
                            taskId: task.id, stepIndex: stepIndex, outcome: .failed)
                        throw JarvisError.verificationFailed(
                            action: toolName,
                            expected: "meaningful output",
                            actual: result.output)
                    }
                    _ = try? stateMachine.markStepVerification(
                        taskId: task.id, stepIndex: stepIndex, outcome: .passed)

                    try stateMachine.updateStep(
                        taskId: task.id,
                        stepIndex: stepIndex,
                        state: .completed,
                        output: completedOutputs.last)
                    stepIndex += 1
                } else {
                    // Composition step (tool:null): produce a REAL direct answer
                    // with one bounded local-model generation conditioned on the
                    // goal + actual observations. Falls back to the planner's own
                    // purpose text only if composition fails — never a fake answer.
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
                plan = try await planWithRecovery(
                    goal: goal, context: plannerContext, taskId: task.id, stateMachine: stateMachine)
                try stateMachine.setSteps(taskId: task.id, steps: toTaskSteps(plan))
                // A replan can produce a shorter plan; restart traversal so the
                // new plan executes from its first step (bounded by attempts).
                if stepIndex >= plan.steps.count { stepIndex = 0 }
                try stateMachine.transition(taskId: task.id, to: .running)
            }
        }

        // 5. VERIFY & RESPOND
        try stateMachine.transition(taskId: task.id, to: .verifying)
        try stateMachine.transition(taskId: task.id, to: .completed)

        let response = completedOutputs.joined(separator: "\n")
        JarvisLogger.brain.info("AgentLoop completed goal successfully: \(response)")

        return response.isEmpty ? "All actions executed and verified." : response
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
            let plan = try await MLXPlanner.shared.plan(goal: goal, context: context)
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
            // A second consecutive planning failure propagates (fail safely).
            try stateMachine.transition(taskId: taskId, to: .failed, error: "Planner failed: \(error.localizedDescription)")
            try stateMachine.transition(taskId: taskId, to: .recovering)
            try stateMachine.transition(taskId: taskId, to: .replanning)
            try? stateMachine.incrementRetryCount(taskId: taskId)
            do {
                let retryPlan = try await MLXPlanner.shared.plan(goal: goal, context: context)
                if let metrics = await MLXPlanner.shared.latestMetrics() {
                    lastPlannerMetrics.value = metrics
                }
                return retryPlan
            } catch is CancellationError {
                _ = try? stateMachine.transition(taskId: taskId, to: .cancelled, error: "Agent task cancelled during planning")
                throw CancellationError()
            }
        }
    }

    /// Convert validated plan steps into state-machine TaskSteps.
    private func toTaskSteps(_ plan: AgentPlan) -> [TaskStep] {
        plan.steps.enumerated().map { index, step in
            TaskStep(
                stepNumber: index + 1,
                description: step.purpose,
                toolName: step.toolName,
                arguments: step.arguments)
        }
    }
}
