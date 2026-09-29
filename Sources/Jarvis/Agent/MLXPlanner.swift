import Foundation
import CryptoKit

/// Real MLX-backed agent planner.
///
/// Replaces the former keyword heuristic inside AgentLoop: the user goal and a
/// compact catalog of the LIVE ToolRegistry are sent to the local MLX model
/// (Qwen2.5-0.5B-Instruct-4bit via the persistent mlx_lm worker), and the raw
/// model output is parsed into an `AgentPlan` and validated by `PlanValidator`
/// before anything can execute.
///
/// Schema contract experiment (Change A + B):
/// - Change A: the planner prompt embeds an ARGUMENT SCHEMAS section generated
///   directly from the live ToolRegistry's `parameterSpec` (no parallel
///   hand-maintained schema), including an explicit CORRECT vs WRONG example
///   for `run_shell` making clear that `command` is ONE scalar string.
/// - Change B: when validation fails, the repair prompt carries the EXACT
///   validator error, the relevant tool's LIVE schema, a corrected example,
///   the original invalid plan, and an explicit MODIFY instruction — never a
///   resent generic prompt.
///
/// Honest bounds (0.5B model reality):
/// - Only 2 generation attempts (initial + 1 repair) — bounded, no infinite loops.
/// - Everything is measured through the REAL MLXProvider stats infrastructure;
///   no numbers are synthesized.
actor MLXPlanner {
    static let shared = MLXPlanner()

    /// Provider slot dedicated to planning. Uses the configured "normal" local
    /// model so planning never competes with the reflex classifier's slot.
    private let provider = MLXProvider(id: "mlx-planner", modelSlot: "normal")

    /// Last real planner measurements (thread-safe for sync readers).
    private let lastMetrics = LockedValue<PlannerMetrics?>(nil)

    /// Raw model outputs from the most recent plan() call (one entry per
    /// generation attempt). Diagnostic visibility into the 0.5B model's actual
    /// behavior — the audit/benchmark use this to report honest failure modes.
    private let lastRunRawOutputs = LockedValue<[String]>([])

    /// Per-attempt diagnostics from the most recent plan() call: prompt hash,
    /// raw output, and the exact validator error that triggered the repair.
    /// Reporting-only infrastructure (benchmark/audit); no behavior depends on it.
    struct AttemptDiagnostic: Sendable {
        let attempt: Int
        let promptSHA256: String
        let rawOutput: String
        /// Exact validator/parser error this attempt produced (nil when the
        /// attempt produced a valid plan).
        let validatorError: String?
        let repaired: Bool
    }

    private let lastRunDiagnostics = LockedValue<[AttemptDiagnostic]>([])

    // MARK: Evidence ledger (instrumentation/evidence-integrity pass)

    /// Append-only, fully-attributed record of EVERY generation attempt.
    /// Unlike latestDiagnostics()/latestRawOutputs() (which are overwritten by
    /// each plan() call and therefore lose the initial planning cycle when a
    /// replan happens), the ledger preserves the COMPLETE per-run attempt
    /// history. Reporting-only: no agent behavior depends on it.
    struct PlannerAttemptRecord: Sendable {
        /// Scope opened by beginLedgerRun(); groups all cycles of one agent run.
        let runID: UUID
        /// Task that owns this planning call (stamped by AgentLoop).
        let taskID: UUID?
        /// One plan() invocation = one planning cycle (up to 2 attempts inside).
        let cycleID: UUID
        /// 0 = initial planning, 1..n = replan cycles, counted per run.
        let cycleIndex: Int
        /// 1 = initial attempt within the cycle, 2 = schema-aware repair.
        let attempt: Int
        let isRepair: Bool
        let promptSHA256: String
        let rawOutput: String
        /// nil = the attempt produced a fully validated plan.
        let validatorError: String?
        /// True when the attempt failed at the PARSE stage (no JSON extracted)
        /// as opposed to the schema/semantic validation stage.
        let parseStageFailed: Bool
        /// Compact honest summary of the parsed+validated plan (success only).
        let parsedPlanSummary: String?
        /// Exact per-step tool names compiled into the AgentPlan (success only).
        let compiledStepTools: [String?]?
        /// Exact per-step argument dictionaries compiled into the AgentPlan
        /// (success only) — what the executor receives.
        let compiledStepArgs: [[String: String]]?
        let requestLatencyMs: Double?
    }

    private let attemptLedger = LockedValue<[PlannerAttemptRecord]>([])
    private let activeLedgerRunID = LockedValue<UUID?>(nil)
    private let cycleCounters = LockedValue<[UUID: Int]>([:])

    /// Open a new ledger run scope: every plan() call until endLedgerRun() is
    /// attributed to the returned runID. Synchronous (nonisolated) on purpose:
    /// a detached endLedgerRun() Task could otherwise close a LATER run's scope
    /// (observed as misattributed evidence). The evidence harness is the single
    /// scope owner; nested code never opens or closes scopes.
    nonisolated func beginLedgerRun() -> UUID {
        let id = UUID()
        activeLedgerRunID.value = id
        var counters = cycleCounters.value
        counters[id] = 0
        cycleCounters.value = counters
        return id
    }

    /// Close the active ledger scope. Synchronous for the same reason.
    nonisolated func endLedgerRun() {
        activeLedgerRunID.value = nil
    }

    /// The currently open ledger scope ID (nil when none is open). Read-only
    /// introspection for attribution consumers.
    func activeLedgerScopeID() -> UUID? { activeLedgerRunID.value }

    /// Complete attempt history for one run, in generation order.
    func ledgerRecords(runID: UUID) -> [PlannerAttemptRecord] {
        attemptLedger.value.filter { $0.runID == runID }
    }

    /// Whole ledger (diagnostics dump support).
    func allLedgerRecords() -> [PlannerAttemptRecord] { attemptLedger.value }

    struct PlannerMetrics: Sendable {
        let requestLatencyMs: Double   // full Swift→worker→mlx_lm round trip
        let ttftMs: Double?            // real first-token latency from the worker
        let workerGenMs: Double?
        let tokens: Int?
        let tokensPerSecond: Double?
        let attempt: Int               // which generation attempt produced the plan
        let repaired: Bool             // true when attempt 2 rescued attempt 1
    }

    /// Planning mode of the generation that produced the plan — used for
    /// mandatory route attribution so decomposed-extraction runs are never
    /// blended into whole-plan statistics.
    enum PlanningMode: String, Sendable {
        /// Legacy single-shot whole-plan generation.
        case fullPlan
        /// Bounded decomposition: extraction + deterministic compilation.
        case decomposed
    }

    func latestMetrics() -> PlannerMetrics? { lastMetrics.value }

    /// Raw model outputs (per attempt) from the most recent plan() invocation.
    func latestRawOutputs() -> [String] { lastRunRawOutputs.value }

    /// Per-attempt diagnostics (prompt hashes, raw outputs, exact validator
    /// errors) from the most recent plan() invocation.
    func latestDiagnostics() -> [AttemptDiagnostic] { lastRunDiagnostics.value }

    /// Test/diagnostic hook: exposes the deterministic hint decision so the
    /// self-test can verify the hint layer without any model generation.
    /// nonisolated: the hint function is a pure static predicate.
    nonisolated static func testHookToolFamilyHint(for goal: String) -> Set<String> {
        toolFamilyHint(for: goal)
    }

    private init() {}

    // MARK: - Planning mode (route attribution)

    /// Planning mode of the most recent plan()/planDecomposed() call, for
    /// route attribution. Reset to nil by fast-path runs through AgentLoop.
    private let lastRunMode = LockedValue<PlanningMode?>(nil)

    func latestPlanningMode() -> PlanningMode? { lastRunMode.value }

    // MARK: - Public API

    /// Plan a goal with the local MLX model. Throws on invalid plans after
    /// the bounded repair attempt; never invents a plan itself.
    func plan(goal: String, context: PlannerContext, taskID: UUID? = nil) async throws -> AgentPlan {
        // Ledger attribution: one plan() invocation = one planning cycle, under
        // the scope opened by the harness (self-contained runID when none is
        // open, e.g. production runs). The ledger layer itself registers the
        // run→task attribution so evidence consumers never need "latest task"
        // heuristics.
        let ledgerRunID = activeLedgerRunID.value ?? UUID()
        if let taskID {
            TaskStateMachine.shared.registerRunAttribution(runID: ledgerRunID, taskID: taskID)
        }
        let cycleID = UUID()
        let cycleIndex: Int = {
            var counters = cycleCounters.value
            let index = counters[ledgerRunID] ?? 0
            counters[ledgerRunID] = index + 1
            cycleCounters.value = counters
            return index
        }()
        // STEP 4: deterministic tool-family hint narrows the catalog when the
        // goal unambiguously names one family; full catalog otherwise.
        // D-F isolation finding: a family hint alone HIDES registry tools the
        // goal names explicitly (e.g. "use the audit_failing_tool and then echo…"
        // triggers the shell hint and hid audit_failing_tool, forcing the model
        // to hallucinate its schema). Fix: any registry tool whose exact name
        // appears in the goal is ALWAYS included, hint or not.
        var hint = Self.toolFamilyHint(for: goal)
        let allTools = await MainActor.run { ToolRegistry.shared.allTools }
        let forcedNames = Self.toolNamesMentioned(in: goal, tools: allTools)
        hint.formUnion(forcedNames)
        let promptTools: [any JarvisTool]
        if let hinted = Self.hintedTools(from: allTools, families: hint) {
            promptTools = hinted.sorted { $0.name < $1.name }
        } else {
            promptTools = allTools.sorted { $0.name < $1.name }
        }

        var attempt = 0
        var lastError: PlanValidationError?
        var diagnostics: [AttemptDiagnostic] = []
        var rawOutputs: [String] = []

        // Bounded: 1 initial attempt + 1 repair attempt. No loops.
        var lastRawOutput: String?
        while attempt < 2 {
            attempt += 1
            // Change B: the repair attempt is SCHEMA-AWARE — it receives the
            // exact validator error, the relevant tool's live schema, a
            // corrected example, and its own previous output to MODIFY. It is
            // never a resend of the generic planner prompt.
            let isRepair = attempt > 1
            let prompt: String
            if isRepair, let error = lastError, let previous = lastRawOutput {
                prompt = Self.buildRepairPrompt(
                    goal: goal,
                    tools: Self.repairTools(for: error, promptTools: promptTools, allTools: allTools),
                    error: error,
                    previousAttempt: previous,
                    context: context)
            } else {
                prompt = Self.buildPrompt(goal: goal, tools: promptTools)
            }

            let raw = try await generate(prompt: prompt, maxTokens: Self.plannerMaxTokens)
            rawOutputs.append(raw.text)
            lastRunRawOutputs.value = rawOutputs
            lastRawOutput = raw.text
            let metrics = PlannerMetrics(
                requestLatencyMs: raw.metrics.requestLatencyMs,
                ttftMs: raw.metrics.ttftMs,
                workerGenMs: raw.metrics.workerGenMs,
                tokens: raw.metrics.tokens,
                tokensPerSecond: raw.metrics.tokensPerSecond,
                attempt: attempt,
                repaired: attempt > 1)
            lastMetrics.value = metrics
            let ttftText = metrics.ttftMs.map { String(format: "%.0f", $0) } ?? "n/a"
            JarvisLogger.brain.info("MLXPlanner attempt \(attempt): request \(String(format: "%.0f", metrics.requestLatencyMs))ms, ttft \(ttftText)ms, \(metrics.tokens ?? 0) completion tokens, \(String(format: "%.1f", metrics.tokensPerSecond ?? 0)) tok/s")

            var validatorErrorDescription: String?
            switch AgentPlanParser.parse(raw.text) {
            case .success(let parsed):
                switch await PlanValidator.validateAsync(parsed) {
                case .success(let plan):
                    diagnostics.append(AttemptDiagnostic(
                        attempt: attempt,
                        promptSHA256: Self.sha256Hex(prompt),
                        rawOutput: raw.text,
                        validatorError: nil,
                        repaired: isRepair))
                    appendLedgerRecord(
                        runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                        cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                        prompt: prompt, rawOutput: raw.text, validatorError: nil,
                        parseStageFailed: false,
                        parsedPlanSummary: Self.summarizePlan(plan),
                        compiledTools: plan.steps.map { $0.toolName },
                        compiledArgs: plan.steps.map { $0.arguments },
                        latencyMs: raw.metrics.requestLatencyMs)
                    lastRunDiagnostics.value = diagnostics
                    return plan
                case .failure(let error):
                    lastError = error
                    validatorErrorDescription = error.description
                    JarvisLogger.brain.warning("MLXPlanner attempt \(attempt) rejected: \(error.description)")
                    appendLedgerRecord(
                        runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                        cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                        prompt: prompt, rawOutput: raw.text, validatorError: error.description,
                        parseStageFailed: false, parsedPlanSummary: nil,
                        compiledTools: nil, compiledArgs: nil,
                        latencyMs: raw.metrics.requestLatencyMs)
                }
            case .failure(let error):
                lastError = error
                validatorErrorDescription = error.description
                JarvisLogger.brain.warning("MLXPlanner attempt \(attempt) unparseable: \(error.description)")
                appendLedgerRecord(
                    runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                    cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                    prompt: prompt, rawOutput: raw.text, validatorError: error.description,
                    parseStageFailed: true, parsedPlanSummary: nil,
                    compiledTools: nil, compiledArgs: nil,
                    latencyMs: raw.metrics.requestLatencyMs)
            }
            diagnostics.append(AttemptDiagnostic(
                attempt: attempt,
                promptSHA256: Self.sha256Hex(prompt),
                rawOutput: raw.text,
                validatorError: validatorErrorDescription,
                repaired: isRepair))
            lastRunDiagnostics.value = diagnostics
        }

        throw JarvisError.actionFailed(
            action: "mlx.planner",
            reason: "Planner output invalid after \(attempt) attempts: \(lastError?.description ?? "unknown")")
    }

    // MARK: - Evidence ledger helpers

    private func appendLedgerRecord(
        runID: UUID, taskID: UUID?, cycleID: UUID, cycleIndex: Int,
        attempt: Int, isRepair: Bool, prompt: String, rawOutput: String,
        validatorError: String?, parseStageFailed: Bool,
        parsedPlanSummary: String?, compiledTools: [String?]?, compiledArgs: [[String: String]]?,
        latencyMs: Double?
    ) {
        var ledger = attemptLedger.value
        ledger.append(PlannerAttemptRecord(
            runID: runID, taskID: taskID, cycleID: cycleID, cycleIndex: cycleIndex,
            attempt: attempt, isRepair: isRepair,
            promptSHA256: Self.sha256Hex(prompt), rawOutput: rawOutput,
            validatorError: validatorError, parseStageFailed: parseStageFailed,
            parsedPlanSummary: parsedPlanSummary,
            compiledStepTools: compiledTools, compiledStepArgs: compiledArgs,
            requestLatencyMs: latencyMs))
        // Soft bound for long-lived processes; CLI evidence runs never hit it.
        if ledger.count > 1000 { ledger.removeFirst(ledger.count - 1000) }
        attemptLedger.value = ledger
    }

    /// Compact honest summary of a validated plan (for the evidence ledger).
    private static func summarizePlan(_ plan: AgentPlan) -> String {
        let steps = plan.steps.map { step -> String in
            let tool = step.toolName ?? "null(composition)"
            let args = step.arguments.isEmpty
                ? "{}"
                : step.arguments.map { "\($0.key)=\"\($0.value)\"" }.sorted().joined(separator: ", ")
            return "\(tool){\(args)}"
        }
        return "goal=\"\(plan.goal)\" steps=[\(steps.joined(separator: " | "))]"
    }

    // MARK: - Experiment A: sequential next-step planning

    /// Sequential next-step planning (Experiment A): ONE planning generation
    /// for the NEXT executable action, conditioned on the original goal, the
    /// steps already completed this run, and the most recent observation.
    /// Deterministic authority is unchanged: the same parser, the same
    /// validator, the same bounded schema-aware repair, the same ledger, the
    /// same registry. The ONLY difference from plan() is the prompt shape:
    /// the model is never asked to emit future steps in one shot.
    /// Ledger classification: nextStepIndex == 0 records cycleIndex 0 (initial
    /// planning); every later call is recorded as a replan cycle so existing
    /// attribution/consumers work unchanged.
    func planNextStep(
        goal: String,
        completedSteps: [(tool: String?, command: String?, purpose: String, output: String?)],
        nextStepIndex: Int,
        taskID: UUID?
    ) async throws -> AgentPlan {
        let ledgerRunID = activeLedgerRunID.value ?? UUID()
        if let taskID {
            TaskStateMachine.shared.registerRunAttribution(runID: ledgerRunID, taskID: taskID)
        }
        let cycleID = UUID()
        let cycleIndex: Int = nextStepIndex == 0 ? 0 : cycleCountersValue(for: ledgerRunID)

        // Same catalog/hint logic as plan(): deterministic, unchanged.
        var hint = Self.toolFamilyHint(for: goal)
        let allTools = await MainActor.run { ToolRegistry.shared.allTools }
        let forcedNames = Self.toolNamesMentioned(in: goal, tools: allTools)
        hint.formUnion(forcedNames)
        let promptTools: [any JarvisTool]
        if let hinted = Self.hintedTools(from: allTools, families: hint) {
            promptTools = hinted.sorted { $0.name < $1.name }
        } else {
            promptTools = allTools.sorted { $0.name < $1.name }
        }

        var attempt = 0
        var lastError: PlanValidationError?
        var lastRawOutput: String?
        while attempt < 2 {
            attempt += 1
            let isRepair = attempt > 1
            let prompt: String
            if isRepair, let error = lastError, let previous = lastRawOutput {
                prompt = Self.buildRepairPrompt(
                    goal: goal,
                    tools: Self.repairTools(for: error, promptTools: promptTools, allTools: allTools),
                    error: error,
                    previousAttempt: previous,
                    context: Self.contextFor(goal: goal, completedSteps: completedSteps))
            } else {
                prompt = Self.buildNextStepPrompt(
                    goal: goal, tools: promptTools, completedSteps: completedSteps)
            }

            let raw = try await generate(prompt: prompt, maxTokens: Self.plannerMaxTokens)

            // DONE detection: the next-step prompt instructs the model to reply
            // with exactly "DONE" when the goal is fully achieved. Treat a
            // strict DONE reply as an EMPTY validated plan (the caller's
            // completion signal) — NOT as a parse failure.
            let trimmed = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            if trimmed.lowercased() == "done" {
                appendLedgerRecord(
                    runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                    cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                    prompt: prompt, rawOutput: raw.text, validatorError: nil,
                    parseStageFailed: false,
                    parsedPlanSummary: "DONE (goal achieved; no further steps)",
                    compiledTools: [], compiledArgs: [],
                    latencyMs: raw.metrics.requestLatencyMs)
                return AgentPlan(goal: goal, steps: [])
            }

            let metrics = raw.metrics
            let ttftText = metrics.ttftMs.map { String(format: "%.0f", $0) } ?? "n/a"
            JarvisLogger.brain.info("MLXPlanner next-step \(nextStepIndex) attempt \(attempt): request \(String(format: "%.0f", metrics.requestLatencyMs))ms, ttft \(ttftText)ms, \(metrics.tokens ?? 0) tokens")

            switch AgentPlanParser.parse(raw.text) {
            case .success(let parsed):
                switch await PlanValidator.validateAsync(parsed) {
                case .success(let plan):
                    appendLedgerRecord(
                        runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                        cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                        prompt: prompt, rawOutput: raw.text, validatorError: nil,
                        parseStageFailed: false,
                        parsedPlanSummary: Self.summarizePlan(plan),
                        compiledTools: plan.steps.map { $0.toolName },
                        compiledArgs: plan.steps.map { $0.arguments },
                        latencyMs: metrics.requestLatencyMs)
                    return plan
                case .failure(let error):
                    lastError = error
                    JarvisLogger.brain.warning("MLXPlanner next-step \(nextStepIndex) attempt \(attempt) rejected: \(error.description)")
                    appendLedgerRecord(
                        runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                        cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                        prompt: prompt, rawOutput: raw.text, validatorError: error.description,
                        parseStageFailed: false, parsedPlanSummary: nil,
                        compiledTools: nil, compiledArgs: nil,
                        latencyMs: metrics.requestLatencyMs)
                }
            case .failure(let error):
                lastError = error
                JarvisLogger.brain.warning("MLXPlanner next-step \(nextStepIndex) attempt \(attempt) unparseable: \(error.description)")
                appendLedgerRecord(
                    runID: ledgerRunID, taskID: taskID, cycleID: cycleID,
                    cycleIndex: cycleIndex, attempt: attempt, isRepair: isRepair,
                    prompt: prompt, rawOutput: raw.text, validatorError: error.description,
                    parseStageFailed: true, parsedPlanSummary: nil,
                    compiledTools: nil, compiledArgs: nil,
                    latencyMs: metrics.requestLatencyMs)
            }
            lastRawOutput = raw.text
        }

        throw JarvisError.actionFailed(
            action: "mlx.planner.nextStep",
            reason: "Next-step output invalid after \(attempt) attempts: \(lastError?.description ?? "unknown")")
    }

    private func cycleCountersValue(for runID: UUID) -> Int {
        var counters = cycleCounters.value
        let index = counters[runID] ?? 0
        counters[runID] = index + 1
        cycleCounters.value = counters
        return index
    }

    /// PlannerContext view of completed steps (feeds the repair prompt's real
    /// failure/observation slots without changing its structure).
    private static func contextFor(
        goal: String,
        completedSteps: [(tool: String?, command: String?, purpose: String, output: String?)]
    ) -> PlannerContext {
        let observations = completedSteps.compactMap { step -> String? in
            guard let output = step.output else { return nil }
            return "[\(step.tool ?? "step")] \(output)"
        }
        return PlannerContext.initial(goal: goal).with(
            failure: "the next step must not repeat any completed step",
            observations: observations)
    }

    /// Sequential next-step prompt: compact, schema-grounded, and conditioned
    /// on completed steps. The model must emit EXACTLY ONE step — the next
    /// executable action. Emits "DONE" when the goal is fully achieved.
    private static func buildNextStepPrompt(
        goal: String,
        tools: [any JarvisTool],
        completedSteps: [(tool: String?, command: String?, purpose: String, output: String?)]
    ) -> String {
        var p = ""
        p += "ORIGINAL GOAL: \(goal)\n\n"
        if completedSteps.isEmpty {
            p += "COMPLETED STEPS: none yet\n"
        } else {
            p += "COMPLETED STEPS (do NOT repeat these):\n"
            for (i, s) in completedSteps.enumerated() {
                let cmd = s.command.map { " command=\($0)" } ?? ""
                let out = s.output.map { " output=\($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))" } ?? ""
                p += "\(i + 1). \(s.tool ?? "step")\(cmd)\(out)\n"
            }
        }
        p += "\nDecide the NEXT SINGLE action that moves toward the goal.\n"
        p += "If the goal is already fully achieved, reply with exactly: DONE\n"
        p += "Otherwise reply with ONE JSON object (no code fences, no future steps):\n"
        p += "{\"goal\": \"<the original goal verbatim>\", \"steps\": [{\"id\": \"step_1\", \"tool\": \"<tool name from the catalog\", \"arguments\": {<exact arguments>}}]}\n\n"
        p += Self.schemaSection(from: tools)
        p += "\nRULES: exactly one step. Reuse EXACT user wording from the goal in arguments. Never invent tools or argument fields.\n"
        return p
    }

    // MARK: - Generation

    /// Token budget for planner generations. The default worker budget (256)
    /// truncated the 0.5B model's JSON mid-object on multi-step goals (observed
    /// raw failure: `"command":"echo jarvis_planner_e2e_verifi`). 384 leaves
    /// headroom for 2-3 step plans while staying bounded.
    static let plannerMaxTokens = 384

    // MARK: - Bounded decomposition: extraction + deterministic compilation

    /// Decomposed planning path (planner reliability milestone). Pipeline:
    ///   MODEL → bounded extraction → typed IR → deterministic compile →
    ///   PlanValidator (authority unchanged) → caller
    ///
    /// Attempt budget: 1 model extraction + 1 DETERMINISTIC structural repair
    /// (PlannerExtraction.structuralRepair). A malformed shape is NEVER sent
    /// back to the model for a second generation, so repair contamination —
    /// the model rewriting the user's literal into a prompt-example value — is
    /// structurally impossible on this path. When extraction fails even after
    /// structural repair, the error carries the exact reason so the caller's
    /// existing recovery chain (lossless escalation / whole-plan fallback)
    /// proceeds unchanged.
    func planDecomposed(goal: String, taskID: UUID? = nil) async throws -> AgentPlan {
        try Task.checkCancellation()
        // Clear per-run metrics first: a deterministic extraction must not
        // inherit the previous model call's latency/token evidence.
        lastMetrics.value = nil
        lastRunRawOutputs.value = []
        lastRunDiagnostics.value = []
        lastRunMode.value = .decomposed
        let ledgerRunID = activeLedgerRunID.value ?? UUID()
        if let taskID {
            TaskStateMachine.shared.registerRunAttribution(runID: ledgerRunID, taskID: taskID)
        }
        let cycleID = UUID()

        if let extracted = PlannerExtraction.explicitShellEchoExtraction(goal: goal) {
            switch await MainActor.run(body: { PlannerExtraction.compile(extracted, goal: goal) }) {
            case .success(let plan):
                await MainActor.run {
                    ArgumentPreservationRecorder.shared.recordCompilation(
                        originalGoal: goal,
                        extractedLiteral: extracted.literal,
                        compiledLiteral: PlannerExtraction.compiledValue(carrying: extracted.literal, in: plan))
                }
                JarvisLogger.brain.info("MLXPlanner used exact-literal deterministic extraction (0 model calls)")
                return plan
            case .failure(let error):
                throw JarvisError.actionFailed(
                    action: "mlx.planner.extraction",
                    reason: "Deterministic literal extraction failed validation: \(error.description)")
            }
        }

        // Deterministic open_app extraction for polite/indirect forms
        // ("please open X", "can you open X", "open the app [called] X").
        // Canonical forms ("open X", "launch X", "switch to X") are handled by
        // DeterministicRouter BEFORE planDecomposed is ever called — those forms
        // will never reach this block.
        // On compile failure: fall through to the model path (soft failure).
        // On compile success: return the validated plan immediately (0 model calls).
        if let extractedApp = PlannerExtraction.explicitOpenAppExtraction(goal: goal) {
            let compileResultApp = await MainActor.run { PlannerExtraction.compile(extractedApp, goal: goal) }
            switch compileResultApp {
            case .success(let plan):
                await MainActor.run {
                    ArgumentPreservationRecorder.shared.recordCompilation(
                        originalGoal: goal,
                        extractedLiteral: extractedApp.literal,
                        compiledLiteral: PlannerExtraction.compiledValue(carrying: extractedApp.literal, in: plan))
                }
                JarvisLogger.brain.info("MLXPlanner used open_app deterministic extraction (0 model calls)")
                return plan
            case .failure(let error):
                // Soft fall-through: the model gets a chance at an unusual request.
                JarvisLogger.brain.warning("open_app det extraction compile failed (\(error.description)) — falling through to model")
            }
        }

        // Deterministic set_volume extraction for polite/indirect forms
        // ("please set the volume to X", "can you set volume to X", "turn the volume to X").
        // Canonical forms ("set volume to X", "volume X%") are handled by
        // DeterministicRouter BEFORE planDecomposed is ever called.
        if let extractedVol = PlannerExtraction.explicitSetVolumeExtraction(goal: goal) {
            let compileResultVol = await MainActor.run { PlannerExtraction.compile(extractedVol, goal: goal) }
            switch compileResultVol {
            case .success(let plan):
                await MainActor.run {
                    ArgumentPreservationRecorder.shared.recordCompilation(
                        originalGoal: goal,
                        extractedLiteral: extractedVol.literal,
                        compiledLiteral: PlannerExtraction.compiledValue(carrying: extractedVol.literal, in: plan))
                }
                JarvisLogger.brain.info("MLXPlanner used set_volume deterministic extraction (0 model calls)")
                return plan
            case .failure(let error):
                // Soft fall-through: the model gets a chance at an unusual request.
                JarvisLogger.brain.warning("set_volume det extraction compile failed (\(error.description)) — falling through to model")
            }
        }

        // Deterministic write_file extraction for explicit quoted content and path
        // ("write the text 'X' to Y", "save 'X' to file Y").
        if let extractedWrite = PlannerExtraction.explicitWriteFileExtraction(goal: goal) {
            let compileResultWrite = await MainActor.run { PlannerExtraction.compile(extractedWrite, goal: goal) }
            switch compileResultWrite {
            case .success(let plan):
                await MainActor.run {
                    ArgumentPreservationRecorder.shared.recordCompilation(
                        originalGoal: goal,
                        extractedLiteral: extractedWrite.literal,
                        compiledLiteral: PlannerExtraction.compiledValue(carrying: extractedWrite.literal, in: plan))
                }
                JarvisLogger.brain.info("MLXPlanner used write_file deterministic extraction (0 model calls)")
                return plan
            case .failure(let error):
                // Soft fall-through: the model gets a chance at an unusual request.
                JarvisLogger.brain.warning("write_file det extraction compile failed (\(error.description)) — falling through to model")
            }
        }

        // Deterministic fetch_url extraction for explicit HTTP/HTTPS URL fetch requests
        // ("fetch the url https://...", "download url https://...").
        if let extractedFetch = PlannerExtraction.explicitFetchURLExtraction(goal: goal) {
            let compileResultFetch = await MainActor.run { PlannerExtraction.compile(extractedFetch, goal: goal) }
            switch compileResultFetch {
            case .success(let plan):
                await MainActor.run {
                    ArgumentPreservationRecorder.shared.recordCompilation(
                        originalGoal: goal,
                        extractedLiteral: extractedFetch.literal,
                        compiledLiteral: PlannerExtraction.compiledValue(carrying: extractedFetch.literal, in: plan))
                }
                JarvisLogger.brain.info("MLXPlanner used fetch_url deterministic extraction (0 model calls)")
                return plan
            case .failure(let error):
                // Soft fall-through: the model gets a chance at an unusual request.
                JarvisLogger.brain.warning("fetch_url det extraction compile failed (\(error.description)) — falling through to model")
            }
        }

        // Catalog: identical deterministic hint + forced-inclusion logic as
        // plan(), plus the recency web hint so freshness-sensitive goals see
        // the web tools.
        var hint = Self.toolFamilyHint(for: goal)
        if PlannerExtraction.requiresFreshData(goal) { hint.insert("web") }
        let allTools = await MainActor.run { ToolRegistry.shared.allTools }
        let forcedNames = Self.toolNamesMentioned(in: goal, tools: allTools)
        hint.formUnion(forcedNames)
        let promptTools: [any JarvisTool]
        if let hinted = Self.hintedTools(from: allTools, families: hint) {
            promptTools = hinted.sorted { $0.name < $1.name }
        } else {
            promptTools = allTools.sorted { $0.name < $1.name }
        }

        let prompt = Self.buildExtractionPrompt(goal: goal, tools: promptTools)
        let raw = try await generate(prompt: prompt, maxTokens: Self.extractionMaxTokens, temperature: 0.0)
        // One ledger record per attempt, same shape as plan() records.
        func record(_ validatorError: String?, parseStageFailed: Bool, summary: String?, tools: [String?]?, args: [[String: String]]?) {
            var ledger = attemptLedger.value
            ledger.append(PlannerAttemptRecord(
                runID: ledgerRunID, taskID: taskID, cycleID: cycleID, cycleIndex: 0,
                attempt: 1, isRepair: false,
                promptSHA256: Self.sha256Hex(prompt), rawOutput: raw.text,
                validatorError: validatorError, parseStageFailed: parseStageFailed,
                parsedPlanSummary: summary, compiledStepTools: tools, compiledStepArgs: args,
                requestLatencyMs: raw.metrics.requestLatencyMs))
            if ledger.count > 1000 { ledger.removeFirst(ledger.count - 1000) }
            attemptLedger.value = ledger
        }

        // Attempt 1: parse the bounded extraction shape.
        // Attempt 2: DETERMINISTIC structural repair (no second generation) —
        // tried both after a parse failure AND after a compile failure (the
        // split command/args shape parses but fails the compiler's
        // undeclared-argument gate until the shape is repaired).
        var extracted: ExtractedAction
        var wasStructurallyRepaired: Bool
        var extractionError: Error?
        switch PlannerExtraction.parse(raw.text) {
        case .success(let action):
            extracted = action
            wasStructurallyRepaired = false
            extractionError = nil
        case .failure(let parseError):
            guard let repaired = await MainActor.run(body: { PlannerExtraction.structuralRepair(raw.text) }) else {
                record("extraction unparseable and not structurally repairable: \(parseError)", parseStageFailed: true, summary: nil, tools: nil, args: nil)
                throw JarvisError.actionFailed(
                    action: "mlx.planner.extraction",
                    reason: "Extraction output invalid and not structurally repairable: \(String(raw.text.prefix(160)))")
            }
            extracted = repaired
            wasStructurallyRepaired = true
            extractionError = nil
        }

        // Deterministic compilation (gate + typed IR → AgentPlan).
        var compileResult = await MainActor.run {
            PlannerExtraction.compile(extracted, goal: goal)
        }
        if case .failure = compileResult, !wasStructurallyRepaired {
            // The split command/args shape parses cleanly but is rejected as an
            // undeclared argument; repair the shape deterministically once.
            if let repaired = await MainActor.run(body: { PlannerExtraction.structuralRepair(raw.text) }),
               repaired != extracted {
                extracted = repaired
                wasStructurallyRepaired = true
                compileResult = await MainActor.run {
                    PlannerExtraction.compile(extracted, goal: goal)
                }
            }
        }
        switch compileResult {
        case .success(let plan):
            record(nil, parseStageFailed: false, summary: Self.summarizePlan(plan),
                   tools: plan.steps.map { $0.toolName }, args: plan.steps.map { $0.arguments })
            await MainActor.run {
                ArgumentPreservationRecorder.shared.recordCompilation(
                    originalGoal: goal,
                    extractedLiteral: extracted.literal,
                    compiledLiteral: PlannerExtraction.compiledValue(carrying: extracted.literal, in: plan))
            }
            return plan
        case .failure(let error):
            record(error.description, parseStageFailed: false, summary: nil, tools: nil, args: nil)
            throw JarvisError.actionFailed(
                action: "mlx.planner.extraction",
                reason: "Extraction failed validation: \(error.description)")
        }
    }

    /// Token budget for the extraction generation: ONE tool choice + arguments
    /// + literal anchor. Far below the whole-plan budget; a tighter cap
    /// reduces truncation-corruption risk and latency.
    static let extractionMaxTokens = 128

    /// Bounded extraction prompt. The model selects ONE tool and copies the
    /// goal's own words into the arguments and the `literal` anchor. The
    /// anti-example names the exact Experiment-B failure mode (model emitting
    /// prompt-example values instead of user text).
    nonisolated static func buildExtractionPrompt(goal: String, tools: [any JarvisTool]) -> String {
        let catalog = tools.sorted { $0.name < $1.name }.map { tool -> String in
            let params = tool.parameterSpec
                .map { spec in "\(spec.name)\(spec.required ? "" : "?"):\(spec.kind.rawValue)" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")

        var p = ""
        p += "TASK: choose ONE tool for the user goal and COPY the goal's own words into the required argument.\n\n"
        p += "TOOLS:\n\(catalog)\n\n"
        p += "OUTPUT: one JSON object, nothing else:\n"
        p += "{\"tool\": \"<one tool name>\", \"arguments\": {<argument names exactly as listed>}, \"literal\": \"<the exact words from the goal that are the user's requested content>\"}\n\n"
        p += "ARGUMENT VALUES:\n"
        p += "- run_shell: the ENTIRE shell command as ONE scalar string.\n"
        p += "- web_search: the search query text.\n"
        p += "- write_file: content = the exact text to write; path = a file path.\n"
        p += "- open_app: app_name = the application name.\n"
        p += "- set_volume: level = integer volume level from 0 to 100.\n\n"
        p += "COPY RULE (critical): argument values and literal must be copied EXACTLY as written in the user goal, preserving exact capitalization. Never write \"hello\", \"example\", or any word that is not in the goal.\n\n"
        p += "Examples of the ONLY allowed transformation (shape change only):\n"
        p += "Goal: write the word jarvis_planner_e2e_verified using run_shell\n"
        p += "{\"tool\": \"run_shell\", \"arguments\": {\"command\": \"echo jarvis_planner_e2e_verified\"}, \"literal\": \"jarvis_planner_e2e_verified\"}\n\n"
        p += "Goal: look up Python documentation\n"
        p += "{\"tool\": \"web_search\", \"arguments\": {\"query\": \"Python documentation\"}, \"literal\": \"Python documentation\"}\n\n"
        p += "WRONG (fabrication): {\"tool\": \"run_shell\", \"arguments\": {\"command\": \"echo hello\"}, \"literal\": \"hello\"}\n\n"
        p += "No tool fits: reply {\"tool\": null, \"arguments\": {}, \"literal\": \"\"}.\n\n"
        p += "Goal: \(goal)\n\n"
        p += "JSON: "
        return p
    }

    private func generate(prompt: String, maxTokens: Int = MLXPlanner.plannerMaxTokens, temperature: Double? = nil) async throws -> (text: String, metrics: PlannerMetrics) {
        // Cancellation must surface as CancellationError even while waiting on
        // the provider stream (worker request continuations do not auto-abort).
        try Task.checkCancellation()
        let message = Message(role: .user, content: prompt)
        var options: [String: any Sendable] = ["max_tokens": maxTokens]
        if let temperature {
            // Copy-from-goal extraction is a deterministic selection task:
            // greedy decoding removes the stochastic path to prompt-example
            // contamination (observed live with a 0.5B model).
            options["temperature"] = temperature
        }
        let stream = await provider.complete(
            messages: [message],
            tools: nil,
            stream: false,
            options: options)
        var text = ""
        for try await chunk in stream {
            try Task.checkCancellation()
            switch chunk {
            case .text(let t): text += t
            case .error(let e): throw JarvisError.providerError(provider: "mlx-planner", message: e)
            case .done: continue
            case .toolCall: continue
            }
        }
        let stats = await provider.latestStats()
        let metrics = PlannerMetrics(
            requestLatencyMs: stats.requestLatencyMs,
            ttftMs: stats.ttftMs,
            workerGenMs: stats.workerGenMs,
            tokens: stats.tokens,
            tokensPerSecond: stats.tokensPerSecond,
            attempt: 1,
            repaired: false)
        return (text, metrics)
    }

    // MARK: - Tool-family hints (deterministic, generic — no audit phrases)

    /// Lightweight deterministic hint layer (STEP 4): narrow the planner's
    /// catalog to the most relevant tool family when the goal unambiguously
    /// names one. Heuristics NEVER hide the only valid tool: when no family is
    /// confident, the FULL catalog is exposed. No execution happens here.
    private static func toolFamilyHint(for goal: String) -> Set<String> {
        let g = goal.lowercased()
        var families: Set<String> = []

        let openVerbs = ["open ", "launch ", "start ", "switch to ", "quit ", "close ", "kill "]
        if openVerbs.contains(where: { g.hasPrefix($0) }) { families.insert("app") }

        if g.contains("volume") || g.contains("audio") || g.contains("sound") {
            families.insert("volume")
        }
        if g.contains("search the web") || g.contains("web search") || g.hasPrefix("search ")
            || g.hasPrefix("look up ") || g.hasPrefix("google ") || g.contains("on the internet") || g.contains("online for") {
            families.insert("web")
        }
        if g.hasPrefix("fetch ") || g.hasPrefix("download ") || g.contains("content of the page")
            || g.contains("read the page at") || g.contains("url") {
            families.insert("web")
        }
        if g.hasPrefix("open ") && (g.contains("http") || g.contains(".com") || g.contains(".org") || g.contains(".io") || g.contains(".net")) {
            families.remove("app")
            families.insert("web")
        }
        let shellVerbs = ["run ", "execute ", "shell", "command ", "print ", "echo ", "list files", "directory", "working directory", "show me the current"]
        if shellVerbs.contains(where: { g.contains($0) }) { families.insert("shell") }

        if g.contains("write ") || g.contains("save ") || g.contains("file") {
            families.insert("file")
        }

        return families
    }

    /// Filter the tool list to the hinted families. Returns nil when no hint is
    /// confident (full catalog). Defensive: a hint that would filter out every
    /// tool returns nil so the caller falls back to the full catalog.
    private static func hintedTools(from tools: [any JarvisTool], families: Set<String>) -> [any JarvisTool]? {
        guard !families.isEmpty else { return nil }
        let familyTools: (String) -> [any JarvisTool] = { family in
            switch family {
            case "app": return tools.filter { $0.name == "open_app" }
            case "volume": return tools.filter { $0.name == "set_volume" }
            case "file": return tools.filter { $0.name == "write_file" }
            case "shell": return tools.filter { $0.name == "run_shell" }
            case "web": return tools.filter { ["web_search", "fetch_url", "open_browser"].contains($0.name) }
            default: return tools.filter { $0.name == family }
            }
        }
        let selected = families.flatMap(familyTools)
        guard !selected.isEmpty else { return nil }
        return selected
    }

    /// Registry tools whose exact name appears as a word in the goal. These are
    /// always included in the prompt catalog regardless of family hints — a
    /// named tool must never be hidden from the planner. Splitting uses
    /// whitespace + explicit sentence separators only: underscore is Unicode
    /// connector punctuation, and shattering on it would break names like
    /// "audit_failing_tool".
    private static func toolNamesMentioned(in goal: String, tools: [any JarvisTool]) -> Set<String> {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.?!;:\"'()"))
        let words = Set(goal.lowercased().components(separatedBy: separators).filter { !$0.isEmpty })
        var mentioned: Set<String> = []
        for tool in tools where words.contains(tool.name) {
            mentioned.insert(tool.name)
        }
        return mentioned
    }

    /// Test/diagnostic hook: exposes the forced-inclusion predicate so the
    /// self-test can verify named tools are never hidden.
    nonisolated static func testHookToolNamesMentioned(in goal: String, toolNames: [String]) -> Set<String> {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.?!;:\"'()"))
        let words = Set(goal.lowercased().components(separatedBy: separators).filter { !$0.isEmpty })
        return Set(toolNames.filter { words.contains($0) })
    }

    // MARK: - Prompt construction (kept compact for the 0.5B model)

    /// Compact catalog of the live ToolRegistry. Only these tools can ever be
    /// planned; anything else is rejected by PlanValidator.
    private static func renderCatalog(_ tools: [any JarvisTool]) -> String {
        tools.sorted { $0.name < $1.name }.map { tool -> String in
            let params = tool.parameterSpec
                .map { spec in "\(spec.name)\(spec.required ? "" : "?"):\(spec.kind.rawValue)" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }
        .joined(separator: "\n")
    }

    // MARK: Change A — live-registry schema section

    /// ARGUMENT SCHEMAS section generated DIRECTLY from the live ToolRegistry's
    /// `parameterSpec` (no hand-maintained parallel schema that can drift).
    /// For `run_shell` the CORRECT vs WRONG representation is spelled out:
    /// `command` is ONE scalar string; an `args` field is never valid.
    private static func schemaSection(from tools: [any JarvisTool]) -> String {
        var lines: [String] = ["ARGUMENT SCHEMAS (exact, generated from the live tool registry — argument names are EXACT):"]
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            let declared = tool.parameterSpec
                .map { spec in "\"\(spec.name)\": <\(spec.kind.rawValue), \(spec.required ? "required" : "optional")>" }
                .joined(separator: ", ")
            lines.append("- \(tool.name)(arguments): {\(declared)}")
            lines.append("  CORRECT: {\"tool\": \"\(tool.name)\", \"arguments\": {\(exampleArguments(for: tool))}}")
            if tool.name == "run_shell" {
                lines.append("  WRONG:   {\"tool\": \"run_shell\", \"arguments\": {\"command\": \"echo\", \"args\": [\"hello\"]}}")
                lines.append("  RULE: command is ONE scalar string containing the complete shell command. Never create an args field.")
                lines.append("  RULE: \"echo hello world\" must be represented as one scalar command string.")
            }
        }
        lines.append("RULE: never add argument fields that are not declared above (e.g. there is no \"args\" field next to \"command\").")
        return lines.joined(separator: "\n")
    }

    /// Example argument object for a tool, built from its REQUIRED declared
    /// parameters (live registry data; values are generic tool-level examples).
    private static func exampleArguments(for tool: any JarvisTool) -> String {
        tool.parameterSpec
            .filter { $0.required }
            .map { "\"\($0.name)\": \(exampleValue(for: $0))" }
            .joined(separator: ", ")
    }

    private static func exampleValue(for spec: ToolParameterSpec) -> String {
        switch spec.kind {
        case .int:
            return "50"
        case .string:
            switch spec.name {
            case "command": return "\"echo hello\""
            case "app_name": return "\"Calculator\""
            case "query": return "\"weather in Tokyo\""
            case "url": return "\"https://example.com\""
            case "browser": return "\"Safari\""
            default: return "\"...\""
            }
        }
    }

    /// Builds the initial planner prompt. Tuned for a 0.5B model: short, rigid
    /// template, exact output shape with NO prose — small models copy structure
    /// far more reliably than they follow abstract instructions.
    ///
    /// Change A: the schema contract is explicit and generated from the live
    /// ToolRegistry (see schemaSection), including the run_shell CORRECT/WRONG
    /// contrast.
    private static func buildPrompt(goal: String, tools: [any JarvisTool]) -> String {
        let catalog = renderCatalog(tools)
        let schema = schemaSection(from: tools)
        var prompt = """
        Available tools:
        \(catalog)

        \(schema)

        Respond with ONLY one JSON object in EXACTLY this shape, nothing else:
        {"goal": "<the goal>", "steps": [ {"id": "step_1", "tool": "<tool name from the list>", "arguments": {<arguments matching the schema above>}, "purpose": "<short reason>"} ]}

        Rules:
        - Use only tools from the list. No tool fits: use "tool": null.
        - Copy argument names and value shapes EXACTLY from the schema above. Numbers without quotes. Never invent argument fields that are not in the schema.
        - If the goal asks to run a shell command, use run_shell and put the ENTIRE command text into one "command" string.
        - command is ONE scalar string containing the complete shell command. Never create an args field.
        - "echo hello world" must be represented as one scalar command string.
        - Always fill "purpose" with a short reason.
        - To use the output of an earlier step N in step M (M > N), write "$step.<N>.output" or "$step.<N>.<field>". For frontmost app, write "$ambient.current_app". The system resolves it deterministically.
        - Output the JSON object as your entire reply. No explanations.

        Example 1:
        Goal: say hello world
        {"goal":"say hello world","steps":[{"id":"step_1","tool":"run_shell","arguments":{"command":"echo hello world"},"purpose":"print the text"}]}

        Example 2:
        Goal: what is the capital of France
        {"goal":"what is the capital of France","steps":[{"id":"step_1","tool":null,"arguments":{},"purpose":"answer from knowledge"}]}

        Example 3:
        Goal: check git branch and echo it
        {"goal":"check git branch and echo it","steps":[{"id":"step_1","tool":"run_shell","arguments":{"command":"git rev-parse --abbrev-ref HEAD"},"purpose":"get current branch"},{"id":"step_2","tool":"run_shell","arguments":{"command":"echo $step.1.output"},"purpose":"print branch"}]}

        Goal: \(goal)
        """
        prompt += "\nJSON: "
        return prompt
    }

    // MARK: Change B — schema-aware repair prompt

    /// Schema-aware repair prompt (Change B). Contains ALL of:
    /// 1. The exact validator error.
    /// 2. The relevant tool's actual live schema from ToolRegistry.
    /// 3. A corrected example demonstrating the required representation.
    /// 4. The original invalid plan.
    /// 5. An explicit instruction to CORRECT the existing plan rather than regenerate an unrelated plan.
    /// Never a resend of the generic planner prompt.
    private static func buildRepairPrompt(
        goal: String,
        tools: [any JarvisTool],
        error: PlanValidationError,
        previousAttempt: String,
        context: PlannerContext
    ) -> String {
        let schema = schemaSection(from: tools)
        let correctExample = correctedExample(tools: tools, error: error, goal: goal)
        var prompt = """
        ORIGINAL GOAL (unchanged — the corrected plan must still accomplish exactly this):
        \(goal)

        Your previous plan for that goal failed validation because:
        \(error.description)

        Required schema:
        \(schema)

        Correct example (SHAPE ONLY — example values like "echo hello" must NEVER appear in the plan; use the user's actual words from the goal):
        \(correctExample)

        Previous invalid plan:
        \(String(previousAttempt.prefix(500)))

        Correct the previous plan to satisfy the schema. Keep the user's requested content (e.g. the exact word or command text the goal asks for) — change ONLY how it is represented (argument names/shape), never what the user asked for.
        Do not invent another tool.
        Do not introduce fields not present in the schema.
        Return only the corrected plan for the original goal.
        """
        if let prior = context.previousFailureOutput {
            prompt += "\nPrior task context: \(prior)"
        }
        prompt += "\nJSON: "
        return prompt
    }

    /// Corrected example line for the repair prompt: the failed tool's required
    /// representation (from the live registry), or the canonical plan shape
    /// when the failure was about JSON structure rather than one tool.
    private static func correctedExample(tools: [any JarvisTool], error: PlanValidationError, goal: String) -> String {
        if let toolName = Self.failedToolName(for: error),
           let tool = tools.first(where: { $0.name == toolName }) {
            return "{\"tool\": \"\(tool.name)\", \"arguments\": {\(exampleArguments(for: tool))}}"
        }
        return "{\"goal\": \"<goal>\", \"steps\": [{\"id\": \"step_1\", \"tool\": \"<tool name from the list>\", \"arguments\": {<arguments matching the schema above>}, \"purpose\": \"<short reason>\"}]}"
    }

    /// The tool a validation error is about, when it names one. Unknown tools
    /// return nil (the full live catalog is shown instead).
    private static func failedToolName(for error: PlanValidationError) -> String? {
        switch error {
        case .noJSONFound, .malformedJSON, .missingField, .wrongType, .emptySteps, .tooManySteps, .unknownTool:
            return nil
        case .missingArgument(let tool, _):
            return tool
        case .unknownArgument(let tool, _):
            return tool
        case .wrongArgumentType(let tool, _, _):
            return tool
        case .unsafeOperation(let tool, _):
            return tool
        case .stepLimitArgument(let tool):
            return tool
        case .invalidReference(let tool, _, _):
            return tool
        }
    }

    /// Tool list for the repair prompt: the specific failed tool when the error
    /// names one (its LIVE schema is shown), the full registry for unknown-tool
    /// errors (the model must see what actually exists), and the prompt's own
    /// tool set for structural JSON errors.
    private static func repairTools(for error: PlanValidationError, promptTools: [any JarvisTool], allTools: [any JarvisTool]) -> [any JarvisTool] {
        if case .unknownTool = error {
            return allTools.sorted { $0.name < $1.name }
        }
        if let toolName = failedToolName(for: error),
           let tool = allTools.first(where: { $0.name == toolName }) {
            return [tool]
        }
        return promptTools
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Replan context

/// Everything the planner needs for a replan: the original goal plus the real
/// failure observation, so the model can adjust instead of repeating itself.
struct PlannerContext: Sendable {
    let goal: String
    /// Human-readable summary of what failed and why (real error text).
    let previousFailure: String?
    /// Real output observed from tools already executed this task.
    let priorObservations: [String]

    static func initial(goal: String) -> PlannerContext {
        PlannerContext(goal: goal, previousFailure: nil, priorObservations: [])
    }

    /// Truncate observations/failures — context stays compact for the 0.5B model.
    func with(failure: String, observations: [String]) -> PlannerContext {
        let clippedObservations = observations.suffix(2).map { String($0.prefix(160)) }
        return PlannerContext(
            goal: goal,
            previousFailure: String(failure.prefix(160)),
            priorObservations: clippedObservations)
    }

    /// Rendered into the repair feedback so the replan uses real context.
    var previousFailureOutput: String? {
        var parts: [String] = []
        if let previousFailure { parts.append("failure: \(previousFailure)") }
        if !priorObservations.isEmpty {
            parts.append("observed: \(priorObservations.joined(separator: " | "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
