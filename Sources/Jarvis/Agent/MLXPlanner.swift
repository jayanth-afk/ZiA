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

    // MARK: - Public API

    /// Plan a goal with the local MLX model. Throws on invalid plans after
    /// the bounded repair attempt; never invents a plan itself.
    func plan(goal: String, context: PlannerContext) async throws -> AgentPlan {
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
                    lastRunDiagnostics.value = diagnostics
                    return plan
                case .failure(let error):
                    lastError = error
                    validatorErrorDescription = error.description
                    JarvisLogger.brain.warning("MLXPlanner attempt \(attempt) rejected: \(error.description)")
                }
            case .failure(let error):
                lastError = error
                validatorErrorDescription = error.description
                JarvisLogger.brain.warning("MLXPlanner attempt \(attempt) unparseable: \(error.description)")
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

    /// Filter the tool list to the hinted families. Returns nil when no hint is
    /// confident (full catalog). Defensive: a hint that would filter out every
    /// tool returns nil so the caller falls back to the full catalog.
    private static func hintedTools(from tools: [any JarvisTool], families: Set<String>) -> [any JarvisTool]? {
        guard !families.isEmpty else { return nil }
        let familyTools: (String) -> [any JarvisTool] = { family in
            switch family {
            case "app": return tools.filter { $0.name == "open_app" }
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
        - Output the JSON object as your entire reply. No explanations.

        Example 1:
        Goal: say hello world
        {"goal":"say hello world","steps":[{"id":"step_1","tool":"run_shell","arguments":{"command":"echo hello world"},"purpose":"print the text"}]}

        Example 2:
        Goal: what is the capital of France
        {"goal":"what is the capital of France","steps":[{"id":"step_1","tool":null,"arguments":{},"purpose":"answer from knowledge"}]}

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
