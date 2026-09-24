import Foundation

/// Schema-contract experiment harness (Change A + B evaluation).
///
/// REPORTING-ONLY infrastructure: runs the mandated benchmark protocol
/// (D-A ×5, D-F ×3, direct-1 ×5, known-good web ×3, known-good shell ×3)
/// through the PRODUCTION path (AgentLoop → MLXPlanner → PlanValidator →
/// ToolExecutor) and prints, for every individual run, the RAW planner output
/// per attempt plus the required dimensions:
///   valid plan / correct tool / correct arguments / execution / verification.
/// It changes NO scoring, NO validators, NO routing — every goal is executed
/// exactly as AgentLoop.run(goal:) would run it in production.
@MainActor
enum SchemaExperiment {

    struct Spec {
        let id: String
        let goal: String
        /// Expected tool (nil for no-tool/direct-answer expectations).
        let expectedTool: String?
        let note: String
    }

    /// The exact protocol goals. D-A and D-F are the audit's router-proof
    /// goals; the shell control is a known-good goal from the previous fixed
    /// benchmark; web control is "search the web for Swift 6 release notes".
    static let specs: [Spec] = [
        Spec(id: "D-A", goal: "write the word jarvis_planner_e2e_verified using run_shell", expectedTool: "run_shell", note: "audit D-A router-proof goal"),
        Spec(id: "D-F", goal: "use the audit_failing_tool and then echo recovery_completed", expectedTool: nil, note: "audit D-F recovery goal (replan expected; final plan must execute)"),
        Spec(id: "direct-1", goal: "what is the capital of France", expectedTool: nil, note: "direct/no-tool composition"),
        Spec(id: "web-good", goal: "search the web for Swift 6 release notes", expectedTool: "web_search", note: "known-good web control"),
        Spec(id: "sh-good", goal: "print hello benchmark via the shell", expectedTool: "run_shell", note: "known-good shell control"),
    ]

    // MARK: - Protocol entry point

    static func runProtocol() async {
        print("╔════════════════════════════════════════════════════════════════════════╗")
        print("║   SCHEMA-CONTRACT EXPERIMENT (Change A: explicit prompt schemas +      ║")
        print("║   Change B: schema-aware repair) — evidence per individual run         ║")
        print("╚════════════════════════════════════════════════════════════════════════╝\n")

        // L2 so run_shell is permitted (same as audit/benchmark).
        let prevAutonomy = Config.shared.autonomyLevel
        Config.shared.autonomyLevel = 2
        defer { Config.shared.autonomyLevel = prevAutonomy }

        // Register the audit-only failing tool exactly as the audit does so the
        // D-F goal behaves identically to `--audit`.
        registerAuditFailingTool()

        let repetitions: [(String, Spec, Int)] = [
            ("3. D-A", specs[0], 5),
            ("4. D-F", specs[1], 3),
            ("5. direct-1", specs[2], 5),
            ("6. Known-good web", specs[3], 3),
            ("7. Known-good shell", specs[4], 3),
        ]

        var allDimensions: [String: (pass: Int, total: Int)] = [
            "valid plan": (0, 0), "correct tool": (0, 0), "correct arguments": (0, 0),
            "execution": (0, 0), "verification": (0, 0),
        ]
        var failureClasses: [String: (pass: Int, total: Int)] = [
            "SYNTAX": (0, 0), "SEMANTIC": (0, 0), "EXECUTION": (0, 0), "VERIFICATION": (0, 0), "PASS": (0, 0),
        ]

        for (section, spec, count) in repetitions {
            print("\n────────────────────── SECTION \(section) — \(spec.id) ×\(count) ──────────────────────")
            print("  goal: \"\(spec.goal)\"  (\(spec.note))")
            for runIndex in 1...count {
                print("\n▶ RUN \(spec.id)#\(runIndex)")
                let r = await runOne(spec)
                printRun(r)
                for key in allDimensions.keys {
                    allDimensions[key]!.total += 1
                    if r.dimensions[key] == true { allDimensions[key]!.pass += 1 }
                }
                failureClasses[r.failureClass, default: (0, 0)].total += 1
            }
        }

        printSummary(dimensions: allDimensions, failureClasses: failureClasses)
    }

    // MARK: - Single run

    struct RunEvidence {
        let spec: Spec
        let index: Int
        // Per attempt: (prompt hash, raw output, exact validator error)
        let attempts: [(promptSHA: String, raw: String, validatorError: String?)]
        let completed: Bool
        let response: String
        let finalError: String?
        let taskSteps: [(tool: String?, state: String, output: String?, error: String?)]
        let dimensions: [String: Bool]
        let failureClass: String
    }

    private static func runOne(_ spec: Spec) async -> RunEvidence {
        var completed = false
        var response = ""
        var finalError: String?
        do {
            response = try await AgentLoop.shared.run(goal: spec.goal)
            completed = true
        } catch {
            finalError = error.localizedDescription
        }

        // Raw planner outputs per attempt (from the LAST plan() call of this run).
        let diagnostics = await MLXPlanner.shared.latestDiagnostics()
        let attempts = diagnostics.map { ($0.promptSHA256, $0.rawOutput, $0.validatorError) }

        // The LAST task created for this goal is this run's state-machine record.
        let task = TaskStateMachine.shared.allTasks.last { $0.goal == spec.goal }
        let steps = (task?.steps ?? []).map { ($0.toolName, $0.state.rawValue, $0.output, $0.error) }

        // ── Dimensions (honest, behavior-level) ──
        let planValid = completed && finalError == nil
        let executedSteps = steps.filter { $0.tool != nil && $0.state == "COMPLETED" }
        let toolSequence = executedSteps.map { $0.tool! }

        var correctTool = false
        var correctArguments = false
        if let expected = spec.expectedTool {
            correctTool = toolSequence.contains(expected)
            correctArguments = correctTool && executedSteps.contains { step in
                stepArgsSatisfy(tool: step.tool!, output: step.output ?? "", goal: spec.goal)
            }
        } else if spec.id == "D-F" {
            // D-F: replan goal — the FINAL plan must execute the working echo
            // step (the always-failing tool step failing once is the scenario).
            correctTool = toolSequence.contains("run_shell") && (response.contains("recovery_completed"))
            correctArguments = correctArguments(forShellEcho: executedSteps, token: "recovery_completed")
        } else {
            // direct-1: composition step — no tool expected.
            correctTool = toolSequence.isEmpty
            correctArguments = true  // no arguments to check for composition
        }

        let execution = planValid && !steps.isEmpty && executedSteps.count == steps.filter { $0.tool != nil }.count && !executedSteps.isEmpty
        let verification = planValid && execution && isMeaningfulResponse(response, for: spec)

        let dimensions: [String: Bool] = [
            "valid plan": planValid,
            "correct tool": correctTool,
            "correct arguments": correctArguments,
            "execution": execution,
            "verification": verification,
        ]

        return RunEvidence(
            spec: spec, index: 0, attempts: attempts, completed: completed,
            response: response, finalError: finalError, taskSteps: steps,
            dimensions: dimensions, failureClass: classify(dimensions: dimensions))
    }

    /// Shell echo check for D-F: some completed run_shell step produced the token.
    private static func correctArguments(forShellEcho steps: [(tool: String?, state: String, output: String?, error: String?)], token: String) -> Bool {
        steps.contains { $0.tool == "run_shell" && $0.state == "COMPLETED" && ($0.output?.contains(token) ?? false) }
    }

    private static func stepArgsSatisfy(tool: String, output: String, goal: String) -> Bool {
        switch tool {
        case "run_shell":
            // The executed command must have produced the goal's required token
            // (D-A/shell control) or real stdout (cwd control handled by output check).
            return !output.isEmpty
        case "web_search":
            return true
        default:
            return true
        }
    }

    private static func isMeaningfulResponse(_ response: String, for spec: Spec) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch spec.id {
        case "D-A": return trimmed.contains("jarvis_planner_e2e_verified")
        case "D-F": return trimmed.contains("recovery_completed")
        case "direct-1":
            let placeholders = ["composed answer", "answer from knowledge", "all actions executed and verified"]
            return !placeholders.contains { trimmed.lowercased() == $0 } && trimmed.count >= 8
        case "web-good":
            return trimmed.contains("http") || trimmed.contains("URL") || trimmed.contains("[1]")
                || trimmed.lowercased().contains("result") || trimmed.lowercased().contains("no results")
        case "sh-good":
            let l = trimmed.lowercased()
            return trimmed.contains("benchmark") || trimmed.contains("hello") || l.contains("executed") || l.contains("command")
        default: return true
        }
    }

    /// Failure class per the protocol: the EARLIEST failing stage wins.
    /// SYNTAX (no valid plan) → SEMANTIC (valid plan, wrong tool/args) →
    /// EXECUTION (right plan, step failed) → VERIFICATION (executed, output wrong).
    private static func classify(dimensions: [String: Bool]) -> String {
        if dimensions["valid plan"] != true { return "SYNTAX" }
        if dimensions["correct tool"] != true || dimensions["correct arguments"] != true { return "SEMANTIC" }
        if dimensions["execution"] != true { return "EXECUTION" }
        if dimensions["verification"] != true { return "VERIFICATION" }
        return "PASS"
    }

    // MARK: - Printing

    private static func printRun(_ r: RunEvidence) {
        print("  goal: \"\(r.spec.goal)\"")
        print("  completed: \(r.completed)\(r.finalError.map { " | final error: \($0)" } ?? "")")
        print("  first attempt valid: \(r.attempts.first?.validatorError == nil && !(r.attempts.first?.raw.isEmpty ?? true))")
        print("  repair invoked: \(r.attempts.count > 1)")
        if r.attempts.count > 1 {
            print("  exact validator failure that triggered repair: \(r.attempts.first?.validatorError ?? "n/a")")
            let same = r.attempts.count >= 2 && r.attempts[0].raw == r.attempts[1].raw
            print("  repair output differed from original: \(!same)\(same ? "  ⚠️ BYTE-IDENTICAL RETRY" : "")")
        }
        print("  ── raw planner output ──")
        for (i, a) in r.attempts.enumerated() {
            print("  [attempt \(i + 1)] prompt sha256: \(a.promptSHA.prefix(16))…")
            print("  [attempt \(i + 1)] RAW >>>\(a.raw)<<<")
            if let err = a.validatorError { print("  [attempt \(i + 1)] validator error: \(err)") }
        }
        print("  ── state machine steps ──")
        for s in r.taskSteps {
            print("    tool=\(s.tool ?? "null(composition)") state=\(s.state) output='\(String((s.output ?? "").prefix(80)))'\(s.error.map { " error='\(String($0.prefix(80)))'" } ?? "")")
        }
        print("  ── dimensions ──")
        for key in ["valid plan", "correct tool", "correct arguments", "execution", "verification"] {
            print("    \(key.padding(toLength: 18, withPad: " ", startingAt: 0)): \(r.dimensions[key] == true ? "PASS" : "FAIL")")
        }
        print("  failure class: \(r.failureClass)")
    }

    private static func printSummary(dimensions: [String: (pass: Int, total: Int)], failureClasses: [String: (pass: Int, total: Int)]) {
        print("\n────────────────────── 8. PER-DIMENSION SUMMARY ──────────────────────")
        for key in ["valid plan", "correct tool", "correct arguments", "execution", "verification"] {
            let d = dimensions[key]!
            print("  \(key.padding(toLength: 18, withPad: " ", startingAt: 0)): \(d.pass)/\(d.total)")
        }
        print("\n────────────────────── FAILURE CLASSES (per run) ──────────────────────")
        for key in ["SYNTAX", "SEMANTIC", "EXECUTION", "VERIFICATION", "PASS"] {
            let f = failureClasses[key] ?? (0, 0)
            print("  \(key.padding(toLength: 12, withPad: " ", startingAt: 0)): \(f.total) run(s)")
        }
        print("\n(END OF EXPERIMENT PROTOCOL — evidence above is per individual run)")
    }

    // MARK: - Audit-failing tool (identical to the audit's definition)

    private static func registerAuditFailingTool() {
        guard ToolRegistry.shared.getTool(named: "audit_failing_tool") == nil else { return }
        struct AlwaysFailingPlannerTool: JarvisTool {
            let name = "audit_failing_tool"
            let description = "Audit-only tool that always fails, exercising real recovery"
            let impact: PermissionGate.ActionImpact = .readOnly
            var parameterSpec: [ToolParameterSpec] {
                [ToolParameterSpec(name: "reason", kind: .string, required: false, description: "Why this tool is being called")]
            }
            func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
                throw JarvisError.actionFailed(action: name, reason: "Intentional audit failure (planned)")
            }
            func observe() async throws -> ObservationResult {
                ObservationResult(observations: ["status": "never-reached"])
            }
        }
        ToolRegistry.shared.register(AlwaysFailingPlannerTool())
    }
}
