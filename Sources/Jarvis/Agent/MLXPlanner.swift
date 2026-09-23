import Foundation

/// Real MLX-backed agent planner.
///
/// Replaces the former keyword heuristic inside AgentLoop: the user goal and a
/// compact catalog of the LIVE ToolRegistry are sent to the local MLX model
/// (Qwen2.5-0.5B-Instruct-4bit via the persistent mlx_lm worker), and the raw
/// model output is parsed into an `AgentPlan` and validated by `PlanValidator`
/// before anything can execute.
///
/// Honest bounds (0.5B model reality):
/// - Only 2 generation attempts (initial + 1 repair) — bounded, no infinite loops.
/// - Prompts stay minimal (goal + tool catalog + one 1-shot example) because
///   the model's instruction budget is tiny.
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

    struct PlannerMetrics: Sendable {
        let requestLatencyMs: Double   // full Swift→worker→mlx_lm round trip
        let ttftMs: Double?            // real first-token latency from the worker
        let workerGenMs: Double?
        let tokens: Int?
        let tokensPerSecond: Double?
        let attempt: Int               // which generation attempt produced the plan
        let repaired: Bool             // true when attempt 2 rescued attempt 1
    }

    func latestMetrics() -> PlannerMetrics? { lastMetrics.value }

    /// Raw model outputs (per attempt) from the most recent plan() invocation.
    func latestRawOutputs() -> [String] { lastRunRawOutputs.value }

    /// Test/diagnostic hook: exposes the deterministic hint decision so the
    /// self-test can verify the hint layer without any model generation.
    /// nonisolated: the hint function is a pure static predicate.
    nonisolated static func testHookToolFamilyHint(for goal: String) -> Set<String> {
        toolFamilyHint(for: goal)
    }

    private init() {}

    // MARK: - Public API

    /// Plan a goal with the local MLX model. Throws on invalid plans after
    /// the bounded repair attempt; never invents a plan itself.
    func plan(goal: String, context: PlannerContext) async throws -> AgentPlan {
        // STEP 4: deterministic tool-family hint narrows the catalog when the
        // goal unambiguously names one family; full catalog otherwise.
        let hint = Self.toolFamilyHint(for: goal)
        var catalog: String
        if hint.isEmpty {
            catalog = await Self.toolCatalog()
        } else {
            let allTools = await MainActor.run { ToolRegistry.shared.allTools }
            if let hinted = Self.hintedCatalog(from: allTools, families: hint) {
                catalog = hinted
            } else {
                catalog = await Self.toolCatalog()
            }
        }
        var attempt = 0
        var lastError: PlanValidationError?
        var rawOutputs: [String] = []

        // Bounded: 1 initial attempt + 1 repair attempt. No loops.
        var lastRawOutput: String?
        while attempt < 2 {
            attempt += 1
            let prompt = Self.buildPrompt(
                goal: goal,
                catalog: catalog,
                repairFeedback: lastError.map { Self.repairFeedback(for: $0, context: context) },
                previousAttempt: attempt > 1 ? lastRawOutput : nil
            )

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

            switch AgentPlanParser.parse(raw.text) {
            case .success(let parsed):
                switch await PlanValidator.validateAsync(parsed) {
                case .success(let plan):
                    return plan
                case .failure(let error):
                    lastError = error
                    JarvisLogger.brain.warning("MLXPlanner attempt \(attempt) rejected: \(error.description)")
                }
            case .failure(let error):
                lastError = error
                JarvisLogger.brain.warning("MLXPlanner attempt \(attempt) unparseable: \(error.description)")
            }
        }

        lastRunRawOutputs.value = rawOutputs
        throw JarvisError.actionFailed(
            action: "mlx.planner",
            reason: "Planner output invalid after \(attempt) attempts: \(lastError?.description ?? "unknown")")
    }

    // MARK: - Generation

    /// Token budget for planner generations. The default worker budget (256)
    /// truncated the 0.5B model's JSON mid-object on multi-step goals (observed
    /// raw failure: `"command":"echo jarvis_planner_e2e_verifi`). 384 leaves
    /// headroom for 2-3 step plans while staying bounded.
    static let plannerMaxTokens = 384

    private func generate(prompt: String, maxTokens: Int = MLXPlanner.plannerMaxTokens) async throws -> (text: String, metrics: PlannerMetrics) {
        // Cancellation must surface as CancellationError even while waiting on
        // the provider stream (worker request continuations do not auto-abort).
        try Task.checkCancellation()
        let message = Message(role: .user, content: prompt)
        let stream = await provider.complete(
            messages: [message],
            tools: nil,
            stream: false,
            options: ["max_tokens": maxTokens])
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

        if g.contains("search the web") || g.contains("web search") || g.hasPrefix("search ")
            || g.hasPrefix("look up ") || g.contains("on the internet") || g.contains("online for") {
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

        return families
    }

    /// Filter the catalog to the hinted families. Returns nil when no hint is
    /// confident (full catalog). Defensive: a hint that would filter out every
    /// tool returns the full catalog instead.
    private static func hintedCatalog(from tools: [any JarvisTool], families: Set<String>) -> String? {
        guard !families.isEmpty else { return nil }
        let familyTools: (String) -> [any JarvisTool] = { family in
            switch family {
            case "app": return tools.filter { $0.name == "open_app" }
            case "shell": return tools.filter { $0.name == "run_shell" }
            case "web": return tools.filter { ["web_search", "fetch_url", "open_browser"].contains($0.name) }
            default: return []
            }
        }
        let selected = families.flatMap(familyTools)
        guard !selected.isEmpty else { return nil }
        return selected.sorted { $0.name < $1.name }.map { tool in
            let params = tool.parameterSpec
                .map { spec in "\(spec.name)\(spec.required ? "" : "?"):\(spec.kind.rawValue)" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")
    }

    // MARK: - Prompt construction (kept compact for the 0.5B model)

    /// Compact catalog of the live ToolRegistry. Only these tools can ever be
    /// planned; anything else is rejected by PlanValidator.
    private static func toolCatalog() async -> String {
        let tools = await MainActor.run { ToolRegistry.shared.allTools.sorted { $0.name < $1.name } }
        return Self.renderCatalog(tools)
    }

    private static func renderCatalog(_ tools: [any JarvisTool]) -> String {
        tools.map { tool -> String in
            let params = tool.parameterSpec
                .map { spec in "\(spec.name)\(spec.required ? "" : "?"):\(spec.kind.rawValue)" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }
        .joined(separator: "\n")
    }

    /// Builds the full planner prompt. Tuned for a 0.5B model: short, rigid
    /// template, exact output shape with NO prose — small models copy structure
    /// far more reliably than they follow abstract instructions.
    ///
    /// Repair mode (STEP 6) feeds the ACTUAL validation error plus the model's
    /// own previous output (clipped) — the model edits its real attempt instead
    /// of regenerating from an empty skeleton. No tool catalog is repeated in
    /// the repair block, keeping the prompt compact.
    private static func buildPrompt(goal: String, catalog: String, repairFeedback: String?, previousAttempt: String?) -> String {
        var prompt = """
        Available tools:
        \(catalog)
        Respond with ONLY one JSON object in EXACTLY this shape, nothing else:
        {"goal": "<the goal>", "steps": [ {"id": "step_1", "tool": "<tool name from the list>", "arguments": {<its arguments>}, "purpose": "<short reason>"} ]}
        Rules:
        - Use only tools from the list. No tool fits: use "tool": null.
        - Copy argument names exactly. Numbers without quotes.
        - If the goal asks to run a shell command, use run_shell with the command text.
        - Always fill "purpose" with a short reason.
        - Output the JSON object as your entire reply. No explanations.
        Example 1:
        Goal: say hello world
        {"goal":"say hello world","steps":[{"id":"step_1","tool":"run_shell","arguments":{"command":"echo hello world"},"purpose":"print the text"}]}
        Example 2:
        Goal: what is the capital of France
        {"goal":"what is the capital of France","steps":[{"id":"step_1","tool":null,"arguments":{},"purpose":"answer from knowledge"}]}
        Goal: \(goal)
        """
        if let repairFeedback {
            prompt += "\nYour previous JSON was INVALID: \(repairFeedback)\n"
            if let previousAttempt {
                prompt += "Previous output: \(String(previousAttempt.prefix(500)))\n"
            }
            prompt += "Output the corrected JSON object only. Keep the same tool and arguments unless the error says otherwise.\n"
        }
        prompt += "JSON: "
        return prompt
    }

    /// Targeted repair feedback derived from the actual validation error plus
    /// the real failure/observation context — not a generic "try again".
    private static func repairFeedback(for error: PlanValidationError, context: PlannerContext) -> String {
        var feedback: String
        switch error {
        case .unknownTool(let name):
            feedback = "tool '\(name)' does not exist; pick ONLY from the listed tools"
        case .missingArgument(let tool, let argument):
            feedback = "step for '\(tool)' is missing required argument '\(argument)'"
        case .unknownArgument(let tool, let argument):
            feedback = "step for '\(tool)' has undeclared argument '\(argument)'; use only declared arguments"
        case .malformedJSON(let underlying, _):
            feedback = "the text was not parseable JSON (\(String(underlying.prefix(60)))); output a single JSON object"
        case .noJSONFound:
            feedback = "no JSON object was found; output a single JSON object"
        case .emptySteps:
            feedback = "steps array was empty; plan at least one step (or use tool:null to answer directly)"
        case .tooManySteps(let limit):
            feedback = "too many steps; keep it to \(limit) or fewer"
        case .unsafeOperation(let tool, let reason):
            feedback = "the requested \(tool) operation was rejected: \(reason); plan a safe alternative"
        case .missingField(let field):
            feedback = "missing field '\(field)'"
        case .wrongType(let field):
            feedback = "field '\(field)' has the wrong type"
        case .wrongArgumentType(let tool, let argument, let expected):
            feedback = "argument '\(argument)' of '\(tool)' must be \(expected)"
        case .stepLimitArgument(let tool):
            feedback = "'\(tool)' step used a reserved internal argument"
        }
        if let prior = context.previousFailureOutput {
            feedback += ". Prior task context: \(prior)"
        }
        return feedback
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
