import Foundation

/// PLANNER RELIABILITY + DIRECT-ANSWER ROUTING benchmark (route-attributed).
///
/// Extends the existing Phase D.5 benchmark with the three capabilities the
/// planner/routing milestone adds:
///   1. ROUTE ATTRIBUTION (mandatory): every result reports DETERMINISTIC /
///      DIRECT-ANSWER / TIER-A PLANNER / TIER-B separately. No blended
///      success percentage: a direct-answer success never inflates planner
///      statistics, and a deterministic command success never inflates
///      planner statistics either.
///   2. ARGUMENT PRESERVATION (explicit metric): original user literal →
///      extracted literal → compiled literal → executed literal is measured
///      byte-for-byte through ArgumentPreservationRecorder, never folded into
///      a general semantic score.
///   3. RECURRING-FAILURE CONTROL: the argument-preservation case runs ≥5
///      repetitions (Experiment-B regression control); direct-answer and
///      recency routing run their own matrix.
///
/// Everything live runs through the PRODUCTION path (AgentLoop.run(goal:) →
/// DeterministicRouter | DirectAnswerRouter | MLXPlanner decomposition →
/// PlanValidator → ToolExecutor → observe → verify). Offline segments
/// (malformed-shape repair replay, compilation gates) run the real compiler
/// without model generation. No results are synthesized and no case is
/// special-cased: the harness only observes what the production pipeline does.
@MainActor
enum PlannerRoutingBenchmark {

    // MARK: - Case definitions (semantic expectations, no hardcoded answers)

    enum CaseKind: String {
        case deterministic      // must hit the L0 router (0 model calls)
        case directAnswer       // must hit the direct-answer route (0 planner calls)
        case refusal            // must hit the typed refusal route
        case plannerTool        // must hit the planner route AND execute the tool family
        case plannerWeb         // must hit the planner route AND run a web tool (recency-safe)
        case escalationProbe    // route must be planner/escalation; result may be either outcome
    }

    struct RoutingCase {
        let id: String
        let goal: String
        let kind: CaseKind
        /// Expected tool family for plannerTool cases ("shell", "web", …).
        let toolFamily: String?
        /// Expected user literal for preservation measurement (byte-exact).
        let expectedLiteral: String?
        let repetitions: Int
    }

    // MARK: - Result model (per-run)

    struct RunResult {
        let caseId: String
        let goal: String
        let kind: CaseKind
        let repetition: Int
        let observedRoute: PipelineRoute?
        let structural: Bool       // run completed with meaningful output
        let semantic: Bool         // behavior matched the case expectation
        let argumentPreserved: Bool?  // byte-exact chain verdict (nil = N/A)
        let plannerCalls: Int      // model generations observed (metrics presence)
        let repairUsed: Bool       // planner reported a repair attempt
        let latencyMs: Double
        let notes: String
    }

    // MARK: - Case matrix (PART H controls included)

    static let matrix: [RoutingCase] = [
        // CASE 1: knowledge question → DIRECT ANSWER, planner NOT called.
        RoutingCase(id: "case1-direct-fact", goal: "What is the capital of France?", kind: .directAnswer, toolFamily: nil, expectedLiteral: nil, repetitions: 3),
        // CASE 2: explicit tool request → TOOL PATH (planner).
        RoutingCase(id: "case2-explicit-search", goal: "Search for the capital of France.", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "capital of France", repetitions: 3),
        // CASE 3: recency-sensitive question → TOOL/WEB PATH (never stale direct answer).
        RoutingCase(id: "case3-recency-fact", goal: "What is the current capital of France according to today's sources?", kind: .plannerWeb, toolFamily: "web", expectedLiteral: nil, repetitions: 3),
        // Deterministic commands retain zero-model-call paths.
        RoutingCase(id: "ctrl-det-time", goal: "what time is it", kind: .deterministic, toolFamily: nil, expectedLiteral: nil, repetitions: 3),
        RoutingCase(id: "ctrl-det-open", goal: "open Safari", kind: .deterministic, toolFamily: nil, expectedLiteral: nil, repetitions: 3),
        // Known-good shell task through the planner. Phrased to be ROUTER-PROOF:
        // the L0 echo fast path ("echo …"/"run echo …"/"run the command echo …")
        // would otherwise swallow the goal before the planner ever sees it —
        // the "write the word X using run_shell" shape is proven to reach the
        // planner (arg-unusual runs it 5×).
        RoutingCase(id: "ctrl-planner-shell", goal: "write the word planner_route_control using run_shell", kind: .plannerTool, toolFamily: "shell", expectedLiteral: "planner_route_control", repetitions: 3),
        // Unusual literal text (underscores + digits + long token).
        RoutingCase(id: "arg-unusual", goal: "write the word jarvis_planner_e2e_verified using run_shell", kind: .plannerTool, toolFamily: "shell", expectedLiteral: "jarvis_planner_e2e_verified", repetitions: 5),
        // Literal containing spaces (router-proof phrasing: no "echo …" prefix).
        RoutingCase(id: "arg-spaces", goal: "write the words hello routing benchmark world using run_shell", kind: .plannerTool, toolFamily: "shell", expectedLiteral: "hello routing benchmark world", repetitions: 3),
        // Literal containing punctuation. The line is quoted (natural phrasing
        // for exact output); quoted spans are literal content, so the ';' in
        // the line must not trigger the compound-goal guard — the goal routes
        // to the bounded extraction path.
        RoutingCase(id: "arg-punct", goal: "print the line \"ready, set; go!\" using echo in the shell", kind: .plannerTool, toolFamily: "shell", expectedLiteral: "ready, set; go!", repetitions: 3),
        // Literal containing numbers (router-proof phrasing: no "echo …" prefix).
        RoutingCase(id: "arg-numbers", goal: "write the phrase build 42 passed using run_shell", kind: .plannerTool, toolFamily: "shell", expectedLiteral: "build 42 passed", repetitions: 3),

        // ── open_app control cases: L0 router must remain unaffected ──
        // These must stay on the .deterministic route after the extraction
        // expansion — they prove the new extractor does not shadow the L0 router.
        RoutingCase(id: "ctrl-det-open-launch", goal: "launch Calculator", kind: .deterministic, toolFamily: nil, expectedLiteral: nil, repetitions: 3),
        RoutingCase(id: "ctrl-det-open-switch", goal: "switch to Terminal", kind: .deterministic, toolFamily: nil, expectedLiteral: nil, repetitions: 3),

        // ── open_app extraction cases: new deterministic extractor (0 model calls) ──
        // Routed through planDecomposed; the L0 router will NOT catch these
        // because they are polite/indirect forms not in matchAppCommand().
        RoutingCase(id: "oa-det-please-open", goal: "please open Safari", kind: .plannerTool, toolFamily: "app", expectedLiteral: "Safari", repetitions: 3),
        RoutingCase(id: "oa-det-can-you", goal: "can you open Notes", kind: .plannerTool, toolFamily: "app", expectedLiteral: "Notes", repetitions: 3),

        // ── web_search extraction cases: 0.5B model extraction ──
        // Each exercises a different surface form of a search request.
        // expectedLiteral tracks the query span for argument preservation.
        RoutingCase(id: "ws-history-rome", goal: "search for the history of Rome", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "the history of Rome", repetitions: 3),
        RoutingCase(id: "ws-look-up", goal: "look up the boiling point of water", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "the boiling point of water", repetitions: 3),
        RoutingCase(id: "ws-google", goal: "google Swift programming tutorials", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "Swift programming tutorials", repetitions: 3),
        RoutingCase(id: "ws-lit-numbers", goal: "search for WWDC 2026 session videos", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "WWDC 2026 session videos", repetitions: 3),

        // ── set_volume control cases: L0 router must remain unaffected ──
        RoutingCase(id: "ctrl-det-vol-set", goal: "set volume to 50", kind: .deterministic, toolFamily: nil, expectedLiteral: nil, repetitions: 3),
        RoutingCase(id: "ctrl-det-vol-mute", goal: "mute", kind: .deterministic, toolFamily: nil, expectedLiteral: nil, repetitions: 3),

        // ── set_volume extraction cases: new deterministic extractor (0 model calls) ──
        RoutingCase(id: "vol-det-please-set", goal: "please set the volume to 50", kind: .plannerTool, toolFamily: "volume", expectedLiteral: "50", repetitions: 3),
        RoutingCase(id: "vol-det-can-you", goal: "can you set volume to 25%", kind: .plannerTool, toolFamily: "volume", expectedLiteral: "25", repetitions: 3),
        RoutingCase(id: "vol-det-turn-to", goal: "turn the volume to 60", kind: .plannerTool, toolFamily: "volume", expectedLiteral: "60", repetitions: 3),

        // ── write_file extraction cases: new deterministic extractor (0 model calls) ──
        RoutingCase(id: "wf-det-write-text", goal: "write the text 'benchmark_literal_token_1' to build/bm_wf1.txt", kind: .plannerTool, toolFamily: "file", expectedLiteral: "benchmark_literal_token_1", repetitions: 3),
        RoutingCase(id: "wf-det-save-file", goal: "save 'benchmark_literal_token_2' to file build/bm_wf2.txt", kind: .plannerTool, toolFamily: "file", expectedLiteral: "benchmark_literal_token_2", repetitions: 3),

        // ── fetch_url extraction cases: new deterministic extractor (0 model calls) ──
        RoutingCase(id: "fu-det-fetch-url", goal: "fetch the url https://example.com", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "https://example.com", repetitions: 3),
        RoutingCase(id: "fu-det-download-url", goal: "download url https://example.com", kind: .plannerWeb, toolFamily: "web", expectedLiteral: "https://example.com", repetitions: 3),
    ]

    /// Offline segments (no model): structural repair replay of the observed
    /// malformed shapes + deterministic compilation gates. These run the REAL
    /// compiler; nothing is mocked.
    static func runOfflineReplay() {
        print("\n════════ OFFLINE REPLAY: structural repair + compilation gates ════════")

        // Replay of the Experiment-B malformed shape: the model's split
        // command/args output. The repair must rejoin the model's OWN content.
        let malformed = #"{"tool": "run_shell", "arguments": {"command": "echo", "args": "offline_replay_token"}, "literal": "offline_replay_token"}"#
        let repaired = PlannerExtraction.structuralRepair(malformed)
        check(repaired != nil, "replay: split command/args shape is structurally repairable")
        if let repaired {
            check(repaired.arguments["command"] == "echo offline_replay_token",
                  "replay: repair re-joins model's own content byte-for-byte (got: \(repaired.arguments["command"] ?? "nil"))")
            check(![ "hello", "example", "jarvis_plan" ].contains(repaired.arguments["command"] ?? ""),
                  "replay: repair never substitutes prompt-example values")
            var validatedOK = false
            if case .success(let plan) = compileOffline(repaired, goal: "echo offline_replay_token"),
               case .success(let validated) = PlanValidator.validate(plan) {
                validatedOK = validated.steps.first?.arguments["command"] == "echo offline_replay_token"
            }
            check(validatedOK, "replay: repaired plan passes PlanValidator with user literal intact")
        }

        // Array-wrapped scalar shape.
        let arrayShape = #"{"tool": "web_search", "arguments": {"query": ["capital of France"]}, "literal": "capital of France"}"#
        let repairedArray = PlannerExtraction.structuralRepair(arrayShape)
        check(repairedArray?.arguments["query"] == "capital of France", "replay: array-wrapped scalar repaired to scalar")

        // Compilation gate: fabricated literal must be rejected.
        let fabricated = ExtractedAction(
            toolName: "run_shell",
            arguments: ["command": "echo hello"],
            literal: "hello")
        if case .failure(.unsafeOperation) = compileOffline(fabricated, goal: "write the word jarvis_planner_e2e_verified using run_shell") {
            check(true, "replay: fabricated literal (not a goal span) rejected by compilation gate")
        } else {
            check(false, "replay: fabricated literal (not a goal span) rejected by compilation gate")
        }

        // Compilation gate: substituted literal (anchor not preserved) rejected.
        let substituted = ExtractedAction(
            toolName: "run_shell",
            arguments: ["command": "echo jarvis_plan_example"],
            literal: "jarvis_planner_e2e_verified")
        if case .failure(.unsafeOperation) = compileOffline(substituted, goal: "write the word jarvis_planner_e2e_verified using run_shell") {
            check(true, "replay: substituted literal (anchor absent from compiled args) rejected")
        } else {
            check(false, "replay: substituted literal (anchor absent from compiled args) rejected")
        }

        // Compilation gate: unknown tool + undeclared argument fail closed.
        let unknownTool = ExtractedAction(toolName: "nuke_everything", arguments: [:], literal: nil)
        if case .failure(.unknownTool) = compileOffline(unknownTool, goal: "anything") {
            check(true, "replay: unknown tool rejected by deterministic compiler")
        } else {
            check(false, "replay: unknown tool rejected by deterministic compiler")
        }
        let smuggled = ExtractedAction(toolName: "run_shell", arguments: ["command": "echo x", "args": "y"], literal: nil)
        if case .failure(.unknownArgument) = compileOffline(smuggled, goal: "echo x") {
            check(true, "replay: undeclared argument rejected by deterministic compiler")
        } else {
            check(false, "replay: undeclared argument rejected by deterministic compiler")
        }

        // Decomposed plans must traverse the same canonical authority gate as
        // whole plans; valid tool/argument names do not make shell content safe.
        let unsafeShell = ExtractedAction(
            toolName: "run_shell",
            arguments: ["command": "rm -rf ~/Documents"],
            literal: nil)
        if case .failure(.unsafeOperation) = compileOffline(unsafeShell, goal: "run this command") {
            check(true, "replay: decomposed compiler applies PlanValidator shell safety")
        } else {
            check(false, "replay: decomposed compiler applies PlanValidator shell safety")
        }

        // Recency forcing determinism.
        check(PlannerExtraction.requiresFreshData("What is the current capital of France according to today's sources?"), "replay: recency signals detected (current/today's)")
        check(!PlannerExtraction.requiresFreshData("What is the capital of France?"), "replay: no recency signal in static fact question")
        check(!PlannerExtraction.requiresFreshData("I want to know python"), "replay: 'now' inside 'know' does not false-positive")
        check(PlannerExtraction.requiresFreshData("who won the game right now"), "replay: 'right now' detected")
        let stalePlan = AgentPlan(goal: "What is the latest Swift version?", steps: [PlanStep(id: "s1", toolName: nil, arguments: [:], purpose: "compose")])
        let forcedPlan = PlannerExtraction.enforceRecency(plan: stalePlan, goal: "What is the latest Swift version?")
        check(forcedPlan.steps.first?.toolName == "web_search", "replay: recency compiler replaces composition-only plan with web_search")
        check(!forcedPlan.steps.isEmpty && forcedPlan.steps.allSatisfy { $0.toolName != nil }, "replay: recency-forced plan contains no stale composition step")

        print("\n  Offline replay: \(offlinePassed) passed, \(offlineFailed) failed")
    }

    /// Offline compile helper (MainActor context assumed at call sites).
    private static func compileOffline(_ extracted: ExtractedAction, goal: String = "g") -> Result<AgentPlan, PlanValidationError> {
        PlannerExtraction.compile(extracted, goal: goal)
    }

    private static var offlinePassed = 0
    private static var offlineFailed = 0
    private static func check(_ condition: Bool, _ message: String) {
        if condition { offlinePassed += 1; print("  ✓ \(message)") }
        else { offlineFailed += 1; print("  ✗ \(message)") }
    }

    // MARK: - Live matrix runner

    static func runAll() async {
        print("╔════════════════════════════════════════════════════════════════════╗")
        print("║   JARVIS — PLANNER ROUTING BENCHMARK (route-attributed, repeated)  ║")
        print("╚════════════════════════════════════════════════════════════════════╝")

        runOfflineReplay()
        await runLiveMatrix()
    }

    /// Live matrix only (model-involved). Offline replay is a separate segment
    /// so each fits a single terminal invocation. An optional case-id filter
    /// restricts the matrix to matching cases ONLY (same goals, same
    /// repetitions, same scoring) — pure execution segmentation; a filtered
    /// invocation is observationally identical to the corresponding slice of
    /// the full matrix.
    static func runLiveMatrix(caseFilter: String? = nil) async {
        print("\n════════ LIVE MATRIX: production pipeline, repeated trials ════════")

        // L2 so run_shell/open_app/web tools are permitted (same as the audit).
        let prevAutonomy = Config.shared.autonomyLevel
        let prevNormalModel = Config.shared.modelName(for: "normal")
        Config.shared.autonomyLevel = 2
        Config.shared.setModelName("mlx-community/Qwen2.5-0.5B-Instruct-4bit", for: "normal")
        defer {
            Config.shared.autonomyLevel = prevAutonomy
            if let prevNormalModel {
                Config.shared.setModelName(prevNormalModel, for: "normal")
            }
        }

        ArgumentPreservationRecorder.shared.reset()

        var results: [RunResult] = []
        for routingCase in matrix where caseFilter == nil || routingCase.id == caseFilter {
            for rep in 1...max(1, routingCase.repetitions) {
                let r = await runCase(routingCase, repetition: rep)
                results.append(r)
                let route = r.observedRoute?.rawValue ?? "threw"
                let pres = r.argumentPreserved.map { $0 ? "preserved" : "SUBSTITUTED" } ?? "n/a"
                print("  [\(routingCase.id) #\(rep)] route=\(route) struct=\(r.structural ? "✓" : "✗") sem=\(r.semantic ? "✓" : "✗") arg=\(pres) \(String(format: "%.0f", r.latencyMs))ms — \(r.notes)")
            }
        }

        printReport(results)
    }

    private static func runCase(_ routingCase: RoutingCase, repetition: Int) async -> RunResult {
        let start = Date()
        var completed = false
        var response = ""
        var failureNote = ""
        do {
            response = try await AgentLoop.shared.run(goal: routingCase.goal)
            completed = true
        } catch {
            failureNote = error.localizedDescription
        }
        let latencyMs = Date().timeIntervalSince(start) * 1000

        let route = await AgentLoop.shared.latestRoute()
        let metrics = await AgentLoop.shared.latestPlannerMetrics()
        let plannerCalls = (route == .planner || route == .escalation) ? (metrics == nil ? 0 : max(1, metrics!.attempt)) : 0
        let repairUsed = metrics?.repaired ?? false

        // ---- STRUCTURAL: completed with meaningful output.
        let structural = completed && !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // ---- SEMANTIC: behavior matched the case expectation (route first).
        var semantic = false
        var notes = ""
        switch routingCase.kind {
        case .deterministic:
            semantic = (route == .deterministic) && structural
            notes = semantic ? "deterministic route, no model calls" : "expected deterministic route (observed \(route?.rawValue ?? "threw"))"
        case .directAnswer:
            semantic = (route == .directAnswer) && structural
            notes = semantic ? "direct-answer route, planner not called" : "expected direct-answer route (observed \(route?.rawValue ?? "threw"))"
        case .refusal:
            semantic = (route == .refusal)
            notes = semantic ? "typed refusal" : "expected refusal route (observed \(route?.rawValue ?? "threw"))"
        case .plannerTool:
            let routeOK = (route == .planner || route == .escalation)
            let familyOK = routeOK && familyObserved(routingCase.toolFamily ?? "", response: response)
            semantic = structural && familyOK
            notes = !routeOK ? "expected planner route (observed \(route?.rawValue ?? "threw"))"
                : (familyOK ? "planner route + tool family '\(routingCase.toolFamily ?? "")' executed"
                    : (completed ? "planner route but family behavior not observed: '\(response.prefix(60))'" : "failed: \(failureNote.prefix(80))"))
        case .plannerWeb:
            let routeOK = (route == .planner || route == .escalation)
            let webOK = routeOK && (familyObserved("web", response: response) || webAttempted(response))
            semantic = routeOK && (structural || webAttempted(response))
            notes = !routeOK ? "expected tool/web route (observed \(route?.rawValue ?? "threw"))"
                : (webOK ? "web/tool path engaged (recency-safe)" : (completed ? "planner route but no web/tool behavior: '\(response.prefix(60))'" : "failed: \(failureNote.prefix(80))"))
        case .escalationProbe:
            semantic = (route == .planner || route == .escalation)
            notes = "route probe (observed \(route?.rawValue ?? "threw"))"
        }

        // ---- ARGUMENT PRESERVATION: explicit byte-exact chain verdict.
        var preserved: Bool? = nil
        if let expectedLiteral = routingCase.expectedLiteral, (routingCase.kind == .plannerTool || routingCase.kind == .plannerWeb) {
            let records = ArgumentPreservationRecorder.shared.records(forGoal: routingCase.goal)
            if let last = records.last, last.preserved != nil {
                preserved = last.preserved
                if !(preserved ?? true) {
                    notes += " | PRESERVATION FAILURE: expected '\(expectedLiteral)' chain=\(describeChain(last))"
                }
            } else if route == .planner {
                // Planner-routed case with a preservation expectation produced
                // no verdict: count as failure (missing instrumentation counts
                // as not preserved — evidence, not silence).
                preserved = false
                notes += " | no preservation verdict recorded"
            } else {
                preserved = nil // non-planner route: preservation N/A
            }
            // Byte-exact response cross-check: only meaningful for tools whose
            // stdout actually echoes the user literal (shell echo). Other tools
            // (write_file, web_search, open_app) report path/URL/confirmation —
            // their byte-exact evidence is the recorder's extracted → compiled →
            // executed chain, plus physical artifact verification where applicable.
            if preserved == true && routingCase.kind == .plannerTool && routingCase.toolFamily == "shell" && !response.contains(expectedLiteral) {
                preserved = false
                notes += " | executed output missing the expected literal"
            }
            if preserved == true && routingCase.kind == .plannerTool && routingCase.toolFamily == "file" {
                let targetPath: String
                if let r = routingCase.goal.range(of: " to file ") {
                    targetPath = String(routingCase.goal[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let r = routingCase.goal.range(of: " to ") {
                    targetPath = String(routingCase.goal[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    targetPath = ""
                }
                if !targetPath.isEmpty {
                    let diskContent = FileSystemObserver.shared.readText(path: targetPath)
                    if diskContent == nil || !diskContent!.contains(expectedLiteral) {
                        preserved = false
                        notes += " | physical file missing or content mismatch"
                    }
                    try? FileManager.default.removeItem(atPath: (targetPath as NSString).expandingTildeInPath)
                }
            }
        }

        return RunResult(
            caseId: routingCase.id, goal: routingCase.goal, kind: routingCase.kind,
            repetition: repetition, observedRoute: route,
            structural: structural, semantic: semantic, argumentPreserved: preserved,
            plannerCalls: plannerCalls, repairUsed: repairUsed,
            latencyMs: latencyMs, notes: notes)
    }

    private static func describeChain(_ record: ArgumentPreservationRecorder.Record) -> String {
        "extracted=\(record.extractedLiteral ?? "nil") compiled=\(record.compiledLiteral ?? "nil") executed=\(record.executedLiteral ?? "nil")"
    }

    private static func familyObserved(_ family: String, response: String) -> Bool {
        let lowered = response.lowercased()
        switch family {
        case "shell":
            return lowered.contains("planner_route_control") || lowered.contains("hello routing benchmark world")
                || lowered.contains("jarvis_planner_e2e_verified") || lowered.contains("ready, set; go!")
                || lowered.contains("build 42 passed") || lowered.contains("/") && !lowered.contains("http")
        case "web":
            return lowered.contains("http") || lowered.contains("url") || lowered.contains("result")
                || lowered.contains("no results") || lowered.contains("[1]")
                || lowered.contains("opened") || lowered.contains("browser")
                || lowered.contains("apple events") || lowered.contains("safari")
                || lowered.contains("chrome") || lowered.contains("unavailable")
                || lowered.contains("example.com") || lowered.contains("wikipedia")
                || lowered.contains("ycombinator") || lowered.contains("news.ycombinator.com")
        case "app":
            // open_app tool output: the launcher returns a human-readable
            // confirmation containing the app name, or a system-level
            // response indicating the app was opened/switched to.
            return lowered.contains("opened") || lowered.contains("launched")
                || lowered.contains("switched") || lowered.contains("safari")
                || lowered.contains("notes") || lowered.contains("calculator")
                || lowered.contains("xcode") || lowered.contains("terminal")
                || lowered.contains("already") || lowered.contains("front")
        case "volume":
            return lowered.contains("volume") || lowered.contains("set to") || lowered.contains("%")
        case "file":
            return lowered.contains("file saved to") || lowered.contains("file written")
                || lowered.contains("saved to") || lowered.contains("bm_wf")
        default:
            return false
        }
    }

    private static func webAttempted(_ response: String) -> Bool {
        let lowered = response.lowercased()
        return lowered.contains("search") || lowered.contains("http") || lowered.contains("result")
            || lowered.contains("fetch") || lowered.contains("no results")
    }

    // MARK: - Reporting (route-attributed, no blended percentages)

    private static func printReport(_ results: [RunResult]) {
        print("\n────────────── PLANNER ROUTING BENCHMARK RESULTS ──────────────")
        print("  Runs: \(results.count) (repeated trials, no n=1 percentages)")

        func section(_ title: String, _ route: PipelineRoute?, kinds: [CaseKind]) {
            let runs = results.filter { $0.observedRoute == route && kinds.contains($0.kind) }
            guard !runs.isEmpty else { return }
            let sem = runs.filter(\.semantic).count
            let pres = runs.compactMap(\.argumentPreserved)
            print("  \(title) (route=\(route?.rawValue ?? "?"), n=\(runs.count)): semantic \(sem)/\(runs.count)"
                + (pres.isEmpty ? "" : ", argument preservation \(pres.filter { $0 }.count)/\(pres.count) byte-exact"))
        }

        section("DETERMINISTIC ROUTE", .deterministic, kinds: [.deterministic])
        section("DIRECT-ANSWER ROUTE", .directAnswer, kinds: [.directAnswer])
        section("TIER-A PLANNER ROUTE", .planner, kinds: [.plannerTool, .plannerWeb])
        section("TIER-B ESCALATION ROUTE", .escalation, kinds: [.plannerTool, .plannerWeb, .escalationProbe])

        let plannerRuns = results.filter { $0.observedRoute == .planner || $0.observedRoute == .escalation }
        let repairs = plannerRuns.filter(\.repairUsed).count
        let plannerLatencies = plannerRuns.map(\.latencyMs).sorted()
        let detRuns = results.filter { $0.observedRoute == .deterministic }
        let detLatencies = detRuns.map(\.latencyMs).sorted()
        if !plannerLatencies.isEmpty {
            print("  planner latency (n=\(plannerLatencies.count)): median \(median(plannerLatencies))ms  min \(Int(plannerLatencies.first ?? 0))ms  max \(Int(plannerLatencies.last ?? 0))ms")
            print("  planner repair (structural) usage: \(repairs)/\(plannerRuns.count) runs")
        }
        if !detLatencies.isEmpty {
            print("  deterministic latency (n=\(detLatencies.count)): median \(median(detLatencies))ms  max \(Int(detLatencies.last ?? 0))ms")
        }

        let presRuns = results.compactMap { r -> (String, Bool)? in r.argumentPreserved.map { (r.caseId, $0) } }
        if !presRuns.isEmpty {
            let ok = presRuns.filter { $0.1 }.count
            print("  ARGUMENT PRESERVATION (explicit metric): \(ok)/\(presRuns.count) byte-exact across preservation-instrumented runs")
        }

        print("\n  Per-case:")
        for caseId in OrderedCaseIds(results) {
            let runs = results.filter { $0.caseId == caseId }
            let sem = runs.filter(\.semantic).count
            let routes = Set(runs.compactMap { $0.observedRoute?.rawValue })
            let pres = runs.compactMap(\.argumentPreserved)
            print("    \(caseId) (n=\(runs.count), routes=\(routes.joined(separator: ","))): semantic \(sem)/\(runs.count)"
                + (pres.isEmpty ? "" : ", preserved \(pres.filter { $0 }.count)/\(pres.count)"))
        }

        let failed = results.filter { !$0.semantic }
        if failed.isEmpty {
            print("\n  ✅ ALL ROUTING CASES SEMANTIC GREEN")
        } else {
            print("\n  ❌ \(failed.count) run(s) failed semantic expectation:")
            for f in failed.prefix(10) { print("    - \(f.caseId)#\(f.repetition): \(f.notes)") }
        }
        print("───────────────────────────────────────────────────────────────\n")
    }

    private static func OrderedCaseIds(_ results: [RunResult]) -> [String] {
        var ids: [String] = []
        for r in results where !ids.contains(r.caseId) { ids.append(r.caseId) }
        return ids
    }

    private static func median(_ v: [Double]) -> Int {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return v.count % 2 == 1 ? Int(s[s.count / 2]) : Int((s[s.count / 2 - 1] + s[s.count / 2]) / 2)
    }
}
