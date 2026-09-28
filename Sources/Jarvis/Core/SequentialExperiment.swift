import Foundation

/// Tier-A Experiment A harness: sequential next-step planning vs single-shot
/// full-plan generation.
///
/// REPORTING-ONLY infrastructure. Every goal runs through the PRODUCTION path
/// (AgentLoop → MLXPlanner → PlanValidator → ToolExecutor) exactly as
/// production would. The harness records per-run evidence:
///   runID / taskID / input / intended step count / planner call count /
///   generation count / generated step count / validation / execution /
///   verification / recovery invocations / final state / final success /
///   latency / Task State transitions / exact failure category.
///
/// Fixed benchmark set (§4 of the experiment protocol):
///   B1 — 3-step INDEPENDENT task (three unrelated echo tokens)
///   B2 — 3-step DEPENDENT task (step 2 embeds step 1's stdout; step 3 embeds step 2's)
///   B3 — output/reference-dependent task ( pronoun/anaphora reference )
///        NOTE: reference resolution is NOT implemented in this codebase, so
///        B3 is declared REFERENCE_RESOLUTION_NOT_IMPLEMENTED. The harness
///        still probes it (×5) to document what the 0.5B model does when asked
///        — the runs are NOT scored as pass/fail.
///   B4 — existing canonical D-A benchmark (exact-token single step)
///   B5 — existing canonical D-F-multi benchmark (3 intended steps, mid-failing tool)
/// Planning mode for the current process. BASELINE uses .fullPlan (the
/// existing single-shot behavior). Experiment A uses .sequential.
/// Declared here so the harness can label evidence by mode; the AGENT reads it
/// at plan time only when sequential support is wired in Experiment A.
enum PlannerMode: String, Sendable {
    case fullPlan
    case sequential
}

/// Lock-guarded sendable box for the cross-actor planning-mode flag.
/// NSLock is itself Sendable; the mutable state lives behind it.
final class ModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: PlannerMode = .fullPlan
    func get() -> PlannerMode { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: PlannerMode) { lock.lock(); defer { lock.unlock() }; _value = v }
}

@MainActor
enum SequentialExperiment {

    // MARK: - Mode selection (read by AgentLoop at plan time)

    private nonisolated static let modeBox = ModeBox()

    /// Which planning mode the AGENT uses for the current process.
    /// Set once at process start by the CLI entry point; never toggled mid-run.
    /// nonisolated (lock-guarded) so the AgentLoop actor can read it without a
    /// MainActor hop.
    nonisolated static var mode: PlannerMode {
        get { modeBox.get() }
        set { modeBox.set(newValue) }
    }

    // MARK: - Benchmark definitions

    struct BenchSpec {
        let id: String
        let goal: String
        /// Determined from the benchmark DEFINITION, never from model output.
        let intendedSteps: Int
        /// Tool names the final executed step set must contain (nil = no check).
        let expectedTools: [String]?
        /// When non-nil: the exact user-content token that must survive into
        /// executed args AND stdout of some completed step (argument survival).
        let requiredTokens: [String]
        /// Scored benchmark (false = informational probe, e.g. B3).
        let scored: Bool
        let note: String
    }

    static let benchmarks: [BenchSpec] = [
        BenchSpec(
            id: "B1",
            goal: "echo alpha_one, then echo bravo_two, then echo charlie_three",
            intendedSteps: 3,
            expectedTools: ["run_shell"],
            requiredTokens: ["alpha_one", "bravo_two", "charlie_three"],
            scored: true,
            note: "3-step INDEPENDENT task: three unrelated echoes"),
        BenchSpec(
            id: "B2",
            goal: "echo baseline_marker_42, then echo the previous output again in uppercase form, then echo the second output with suffix done",
            intendedSteps: 3,
            expectedTools: ["run_shell"],
            requiredTokens: ["baseline_marker_42"],
            scored: true,
            note: "3-step DEPENDENT task: step 2 uses step 1's stdout text, step 3 uses step 2's output. NOTE: true dependency requires reference resolution which is NOT implemented; the goal is phrased so each step is still literally executable (the model may substitute content). Dependency success = all 3 steps execute in order."),
        BenchSpec(
            id: "B3",
            goal: "echo reference_probe_77, then echo it",
            intendedSteps: 2,
            expectedTools: ["run_shell"],
            requiredTokens: [],
            scored: false,
            note: "REFERENCE_RESOLUTION_NOT_IMPLEMENTED — 'it' cannot be resolved by any implemented mechanism. Informational probe only: documents model behavior; never scored."),
        BenchSpec(
            id: "B4",
            goal: "write the word jarvis_planner_e2e_verified using run_shell",
            intendedSteps: 1,
            expectedTools: ["run_shell"],
            requiredTokens: ["jarvis_planner_e2e_verified"],
            scored: true,
            note: "existing canonical D-A benchmark (exact user token must survive)"),
        BenchSpec(
            id: "B5",
            goal: "echo recovery_started, then use the audit_failing_tool, then echo recovery_completed",
            intendedSteps: 3,
            expectedTools: ["run_shell"],
            requiredTokens: ["recovery_started", "recovery_completed"],
            scored: true,
            note: "existing canonical D-F-multi benchmark (3 intended steps, failing tool mid-sequence)"),
    ]

    // MARK: - Per-run evidence

    struct RunEvidence {
        let spec: BenchSpec
        let index: Int
        let runID: UUID
        let taskID: UUID?
        let input: String
        let intendedSteps: Int
        let plannerCallCount: Int          // planning cycles (plan() invocations)
        let generationCount: Int           // raw model generations across all cycles
        let generatedStepCountInitial: Int // steps in the INITIAL plan (cycle 0)
        let generatedStepCountFinal: Int   // steps in the FINAL plan state
        let planValid: Bool
        let validationErrors: [String]
        let executedStepCount: Int
        let executionOK: Bool
        let verificationOK: Bool
        let recoveryInvocations: Int
        let finalTaskState: String
        let agentLoopCompleted: Bool       // AgentLoop.run returned without throwing
        let harnessVerdict: String         // PASS / NOT_COMPLETE / FAILED / PROBE
        let stepCompleteness: Double       // executedDistinctSteps / intendedSteps
        let wallLatencyMs: Double
        let modelLatencyMs: Double         // sum of ledger request latencies
        let stateHistory: String
        let failureCategory: String        // A/B/C/D/E or "—" / "INFO"
        let failureDetail: String
        let response: String
        let argumentChain: [(stage: String, detail: String)]
        let planSnapshots: [(cycle: Int, tools: [String])]
    }

    // MARK: - Entry points

    /// Run one phase: mode must already be set (BASELINE = .fullPlan, SEQA = .sequential).
    /// Optional benchmark filter (e.g. "B1") so each invocation fits a single
    /// terminal command; omitting it runs the whole set.
    static func runPhase(phaseTitle: String, only benchID: String? = nil) async {
        let reps = 5
        print("""
        ╔════════════════════════════════════════════════════════════╗
        ║   TIER-A SEQUENTIAL EXPERIMENT — PHASE: \(phaseTitle)
        ║   mode=\(mode == .fullPlan ? "fullPlan (single-shot)" : "sequential (next-step)")
        ╚════════════════════════════════════════════════════════════╝

        """)
        // L2 so run_shell is permitted (same in-process pattern as audit/SchemaExperiment;
        // restored on exit — never persisted).
        let prevAutonomy = Config.shared.autonomyLevel
        Config.shared.autonomyLevel = 2
        defer { Config.shared.autonomyLevel = prevAutonomy }

        var allRuns: [RunEvidence] = []
        let selected = benchmarks.filter { benchID == nil || $0.id == benchID }
        guard !selected.isEmpty else {
            print("Unknown benchmark '\(benchID ?? "")' — use one of: \(benchmarks.map { $0.id }.joined(separator: ", "))")
            return
        }
        for bench in selected {
            print("────────────────────── BENCHMARK \(bench.id) — ×\(reps) ──────────────────────")
            print("  goal: \"\(bench.goal)\"")
            print("  intended steps (definition-derived): \(bench.intendedSteps)")
            print("  note: \(bench.note)")
            if !bench.scored { print("  ⚠️ UNSCORED PROBE (see note above)") }
            for i in 1...reps {
                let run = await runOne(bench, index: i)
                allRuns.append(run)
                printRun(run)
                printMachineLine(run)
            }
            printSectionSummary(bench, runs: allRuns.filter { $0.spec.id == bench.id })
        }
        printPhaseSummary(phaseTitle: phaseTitle, runs: allRuns)
    }

    /// Per-run evidence lines for phase summaries that must aggregate across
    /// separate process invocations (segmented execution) are appended to a
    /// machine-readable line per run so results can be reconstructed later.
    private static func printMachineLine(_ r: RunEvidence) {
        print("SEQDATA|\(phaseTag)|\(r.spec.id)|\(r.index)|\(r.runID.uuidString.prefix(8))|\(r.taskID.map { String($0.uuidString.prefix(8)) } ?? "none")|plannerCalls=\(r.plannerCallCount)|gens=\(r.generationCount)|genStepsInit=\(r.generatedStepCountInitial)|exec=\(r.executedStepCount)|recovery=\(r.recoveryInvocations)|verdict=\(r.harnessVerdict)|cat=\(r.failureCategory)|wallMs=\(Int(r.wallLatencyMs))|modelMs=\(Int(r.modelLatencyMs))")
    }

    /// Tag for the current phase+mode, used in machine-readable lines.
    static var phaseTag: String = "untagged"

    // MARK: - Single run

    private static func runOne(_ spec: BenchSpec, index: Int) async -> RunEvidence {
        let ledgerRunID = MLXPlanner.shared.beginLedgerRun()
        defer { MLXPlanner.shared.endLedgerRun() }

        var completed = false
        var response = ""
        var finalError: String?
        let start = Date()
        do {
            response = try await AgentLoop.shared.run(goal: spec.goal)
            completed = true
        } catch {
            finalError = error.localizedDescription
        }
        let wallMs = Date().timeIntervalSince(start) * 1000

        // Evidence attribution via the explicit run→task registry (no goal heuristics).
        let attempts = await MLXPlanner.shared.ledgerRecords(runID: ledgerRunID)
        let taskID = TaskStateMachine.shared.taskID(forRunID: ledgerRunID)
        let task = taskID.flatMap { TaskStateMachine.shared.getTask(id: $0) }
        let snapshots = taskID.map { TaskStateMachine.shared.stepsHistory(for: $0) } ?? []

        let plannerCallCount = Set(attempts.map(\.cycleID)).count
        let generationCount = attempts.count
        let generatedInitial = snapshots.first { $0.cycle == 0 }?.steps.count ?? 0
        let generatedFinal = task?.steps.count ?? snapshots.last?.steps.count ?? 0

        var validationErrors: [String] = attempts.compactMap(\.validatorError)
        // Deduplicate identical consecutive error strings.
        var deduped: [String] = []
        for e in validationErrors where e != deduped.last { deduped.append(e) }
        validationErrors = deduped

        let steps: [(tool: String?, state: String, output: String?, error: String?, args: [String: String])] =
            (task?.steps ?? []).map {
                (tool: $0.toolName, state: $0.state.rawValue, output: $0.output, error: $0.error, args: $0.arguments)
            }
        let executedSteps = steps.filter { $0.tool != nil && $0.state == "COMPLETED" }

        let planValid = attempts.contains { $0.validatorError == nil }
        let executionOK = !executedSteps.isEmpty
        let verificationOK = completed && !executedSteps.isEmpty

        let recoveryInvocations = (task.map { TaskStateMachine.shared.getHistory(taskId: $0.id) } ?? [])
            .filter { $0.0.rawValue == "RECOVERING" }.count

        // Distinct-step completeness: steps are deduplicated by (tool + full
        // argument set) so a repeated identical step can never inflate the
        // count toward the intended step total (a duplicate is not progress).
        var seen = Set<String>()
        for s in executedSteps {
            let key = (s.tool ?? "") + "|" + s.args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
            seen.insert(key)
        }
        let executedDistinct = seen.count
        let completeness = spec.intendedSteps > 0
            ? Double(min(executedDistinct, spec.intendedSteps)) / Double(spec.intendedSteps)
            : 0

        // Argument-preservation chain (per required token, per cycle).
        var argumentChain: [(stage: String, detail: String)] = []
        for token in spec.requiredTokens {
            for cycleID in Array(Set(attempts.map(\.cycleID))).sorted(by: { "\($0)" < "\($1)" }) {
                for a in attempts.filter({ $0.cycleID == cycleID }) {
                    argumentChain.append((
                        stage: "raw c\(a.cycleIndex).a\(a.attempt)\(a.isRepair ? "R" : "")",
                        detail: "\"\(token)\" present=\(a.rawOutput.contains(token))"))
                }
                if let compiled = attempts.first(where: { $0.cycleID == cycleID && $0.compiledStepArgs != nil }) {
                    let joined = (compiled.compiledStepArgs ?? []).compactMap { $0["command"] }.joined(separator: " && ")
                    argumentChain.append((stage: "compiled c\(compiled.cycleIndex)",
                                          detail: "\"\(token)\" present=\(joined.contains(token)) cmd=\(joined.prefix(90))"))
                }
            }
            if let exec = executedSteps.first(where: { ($0.args["command"] ?? "").contains(token) }),
               let out = exec.output {
                argumentChain.append((stage: "executed+stdout", detail: "\"\(token)\" present=\(out.contains(token))"))
            } else if let anyExec = executedSteps.first(where: { ($0.output ?? "").contains(token) }) {
                argumentChain.append((stage: "stdout-only", detail: "\"\(token)\" in output of \(anyExec.tool ?? "?") (args missing token)"))
            } else {
                argumentChain.append((stage: "executed", detail: "\"\(token)\" NOT found in any executed step"))
            }
        }

        // Harness verdict (deterministic reporting-layer guard — the AGENT may
        // still report success on a partial plan; the harness says NOT_COMPLETE).
        let verdict: String
        if !spec.scored {
            verdict = "PROBE"
        } else if !completed {
            verdict = "FAILED"
        } else if executedDistinct >= spec.intendedSteps {
            verdict = "PASS"
        } else {
            verdict = "NOT_COMPLETE"
        }

        // Failure classification (primary category).
        var category = "—"
        var detail = ""
        if !spec.scored {
            category = "INFO"
            detail = "unscored reference-resolution probe"
        } else if !planValid {
            category = "A"
            detail = "model output never validated (\(validationErrors.first.map { String($0.prefix(110)) } ?? "?"))"
        } else if executedDistinct < spec.intendedSteps {
            if executedDistinct == 0 {
                category = "A"
                detail = "valid plan but zero steps executed"
            } else {
                category = "B"
                detail = "planning/scaffolding: generated \(generatedInitial) of \(spec.intendedSteps) intended steps (partial plan)"
            }
        } else if !spec.requiredTokens.isEmpty {
            let missing = spec.requiredTokens.filter { token in
                !(executedSteps.contains { ($0.args["command"] ?? "").contains(token) }
                    && (executedSteps.contains { ($0.output ?? "").contains(token) }))
            }
            if !missing.isEmpty {
                category = "C"
                detail = "argument preservation: tokens not preserved into executed args+stdout: \(missing)"
            } else if !verificationOK {
                category = "E"
                detail = "execution/verification lifecycle failure despite complete plan"
            } else {
                detail = "pass"
            }
        } else if !verificationOK {
            category = "E"
            detail = "verification/recovery lifecycle failure"
        } else {
            detail = "pass"
        }

        let stateHistory = task.map { t in
            TaskStateMachine.shared.getHistory(taskId: t.id).map { $0.0.rawValue }.joined(separator: " → ")
        } ?? "<no task>"
        let modelLatency = attempts.compactMap(\.requestLatencyMs).reduce(0, +)
        let planSnapshots = snapshots.map { (cycle: $0.cycle, tools: $0.steps.compactMap { $0.toolName ?? "null" }) }

        return RunEvidence(
            spec: spec, index: index, runID: ledgerRunID, taskID: taskID,
            input: spec.goal, intendedSteps: spec.intendedSteps,
            plannerCallCount: plannerCallCount, generationCount: generationCount,
            generatedStepCountInitial: generatedInitial, generatedStepCountFinal: generatedFinal,
            planValid: planValid, validationErrors: validationErrors,
            executedStepCount: executedDistinct, executionOK: executionOK, verificationOK: verificationOK,
            recoveryInvocations: recoveryInvocations,
            finalTaskState: task?.state.rawValue ?? "<none>",
            agentLoopCompleted: completed, harnessVerdict: verdict,
            stepCompleteness: completeness, wallLatencyMs: wallMs, modelLatencyMs: modelLatency,
            stateHistory: stateHistory, failureCategory: category, failureDetail: detail,
            response: String(response.prefix(200)),
            argumentChain: argumentChain, planSnapshots: planSnapshots)
    }

    // MARK: - Printing

    private static func printRun(_ r: RunEvidence) {
        let modeLabel = mode == .fullPlan ? "fullPlan" : "seq"
        print("▶ RUN \(r.spec.id)#\(r.index)  [mode: \(modeLabel)]")
        let taskIDText = r.taskID.map { String($0.uuidString.prefix(8)) } ?? "none"
        print("  runID: \(r.runID.uuidString.prefix(8))  taskID: \(taskIDText)")
        print("  intendedSteps: \(r.intendedSteps)  plannerCalls: \(r.plannerCallCount)  generations: \(r.generationCount)  genStepsInitial: \(r.generatedStepCountInitial)  genStepsFinal: \(r.generatedStepCountFinal)")
        print("  planValid: \(r.planValid)  executed: \(r.executedStepCount)  recovery: \(r.recoveryInvocations)  finalState: \(r.finalTaskState)")
        let errNote = r.agentLoopCompleted ? "" : " | error: \(r.failureDetail)"
        print("  agentLoopCompleted: \(r.agentLoopCompleted)\(errNote)")
        for (i, e) in r.validationErrors.enumerated() where i < 4 {
            print("    validation error \(i + 1): \(e.prefix(150))")
        }
        for snap in r.planSnapshots {
            print("    plan snapshot cycle\(snap.cycle): [\(snap.tools.joined(separator: ", "))]")
        }
        print("    state history: \(r.stateHistory)")
        if !r.argumentChain.isEmpty {
            print("  ── argument-preservation chain ──")
            for a in r.argumentChain { print("    \(a.stage): \(a.detail)") }
        }
        print("  response: >>>\(r.response)<<<")
        print("  latency: wall=\(String(format: "%.0f", r.wallLatencyMs))ms model=\(String(format: "%.0f", r.modelLatencyMs))ms")
        print("  verdict: \(r.harnessVerdict)  completeness: \(String(format: "%.2f", r.stepCompleteness))  category: \(r.failureCategory) — \(r.failureDetail)")
    }

    private static func printSectionSummary(_ bench: BenchSpec, runs: [RunEvidence]) {
        let pass = runs.filter { $0.harnessVerdict == "PASS" }.count
        let notComplete = runs.filter { $0.harnessVerdict == "NOT_COMPLETE" }.count
        let failed = runs.filter { $0.harnessVerdict == "FAILED" }.count
        let avgGen = Double(runs.map(\.generationCount).reduce(0, +)) / Double(max(runs.count, 1))
        let avgSteps = Double(runs.map(\.generatedStepCountInitial).reduce(0, +)) / Double(max(runs.count, 1))
        let avgWall = runs.map(\.wallLatencyMs).reduce(0, +) / Double(max(runs.count, 1))
        let cats = Dictionary(grouping: runs.filter { $0.failureCategory != "—" && $0.failureCategory != "INFO" }, by: \.failureCategory)
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        print("""
        ── SECTION SUMMARY \(bench.id) (scored=\(bench.scored)) ──
          PASS: \(pass)/5  NOT_COMPLETE: \(notComplete)/5  FAILED: \(failed)/5
          avg plannerCalls: \(String(format: "%.1f", Double(runs.map(\.plannerCallCount).reduce(0, +)) / Double(max(runs.count, 1))))  avg generations: \(String(format: "%.1f", avgGen))  avg generatedSteps(initial): \(String(format: "%.1f", avgSteps))  avg wall ms: \(String(format: "%.0f", avgWall))
          failure categories: \(cats.isEmpty ? "none" : cats)
        """)
    }

    private static func printPhaseSummary(phaseTitle: String, runs: [RunEvidence]) {
        print("""
        ════════════════════ PHASE SUMMARY: \(phaseTitle) ════════════════════
        """ )
        for bench in benchmarks {
            let rs = runs.filter { $0.spec.id == bench.id }
            let pass = rs.filter { $0.harnessVerdict == "PASS" }.count
            let nc = rs.filter { $0.harnessVerdict == "NOT_COMPLETE" }.count
            let f = rs.filter { $0.harnessVerdict == "FAILED" }.count
            let plannerCalls = rs.map(\.plannerCallCount).reduce(0, +)
            let gens = rs.map(\.generationCount).reduce(0, +)
            let avgSteps = Double(rs.map(\.generatedStepCountInitial).reduce(0, +)) / Double(max(rs.count, 1))
            let execOK = rs.filter(\.executionOK).count
            let verOK = rs.filter(\.verificationOK).count
            let recovery = rs.map(\.recoveryInvocations).reduce(0, +)
            let avgWall = rs.map(\.wallLatencyMs).reduce(0, +) / Double(max(rs.count, 1))
            print(String(format: "  %@: PASS %d/5 NOT_COMPLETE %d/5 FAILED %d/5 | plannerCalls %d gens %d avgGenSteps %.1f exec %d/5 verify %d/5 recovery %d avgWall %.0fms",
                         bench.id, pass, nc, f, plannerCalls, gens, avgSteps, execOK, verOK, recovery, avgWall))
        }
        print("══════════════════════════════════════════════════════")
    }
}
