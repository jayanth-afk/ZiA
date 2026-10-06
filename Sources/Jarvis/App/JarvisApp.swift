import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.contains("--task-state-probe") {
            setbuf(stdout, nil)
            let exitCode = LockedValue<Int32>(1)
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                exitCode.value = await TaskStateProcessProbe.run(arguments: CommandLine.arguments)
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(exitCode.value)
        }

        // Handle --audio-diag flag for real-time microphone & audio telemetry
        if CommandLine.arguments.contains("--audio-diag") {
            setbuf(stdout, nil)
            let semaphore = DispatchSemaphore(value: 0)
            let duration: Int
            if let idx = CommandLine.arguments.firstIndex(of: "--audio-diag"),
               CommandLine.arguments.count > idx + 1,
               let secs = Int(CommandLine.arguments[idx + 1]) {
                duration = secs
            } else {
                duration = 5
            }
            Task { @MainActor in
                await AudioDiagnostic.runLiveDiagnostic(durationSeconds: duration)
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --self-test flag before app launches
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.runAll()
            exit(0)
        }

        // Handle --physical-test flag for live Mac control physical demonstration
        if CommandLine.arguments.contains("--physical-test") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await PhysicalDemonstration.runAll()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --planner-probe "<goal>" — dump raw planner generations for one goal (diagnostics)
        if let probeIdx = CommandLine.arguments.firstIndex(of: "--planner-probe"),
           CommandLine.arguments.count > probeIdx + 1 {
            let goal = CommandLine.arguments[probeIdx + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await PlannerBenchmark.runProbe(goal: goal)
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        if let autoIdx = CommandLine.arguments.firstIndex(of: "--autonomy"),
           CommandLine.arguments.count > autoIdx + 1,
           let lvl = Int(CommandLine.arguments[autoIdx + 1]) {
            Config.shared.autonomyLevel = lvl
        }

        // Handle --goals <g1> <| <g2> <| ...: run MULTIPLE goals through the
        // SAME production pipeline in ONE process, so the cross-turn conversation
        // memory (ConversationManager) behaves exactly as in the running app.
        // Used to verify follow-up turns ("why?") can reference the prior turn.
        if CommandLine.arguments.firstIndex(of: "--goals") != nil {
            setbuf(stdout, nil)
            let goalsIdx = CommandLine.arguments.firstIndex(of: "--goals")!
            let goals = CommandLine.arguments[(goalsIdx + 1)...]
                .joined(separator: " ")
                .components(separatedBy: "<|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                ArgumentPreservationRecorder.shared.reset()
                // Mirror the app lifecycle: restore the persisted conversation
                // window so multi-turn memory behaves as in the running app.
                ConversationManager.shared.loadPersistedHistory()
                for (i, goal) in goals.enumerated() {
                    print("── turn \(i + 1): \(goal)")
                    do {
                        let response = try await AgentLoop.shared.run(goal: goal)
                        let route = await AgentLoop.shared.latestRoute()
                        print("[route] \(route?.rawValue ?? "unknown")")
                        print("[response] \(response)")
                    } catch {
                        let route = await AgentLoop.shared.latestRoute()
                        print("[route] \(route?.rawValue ?? "unknown")")
                        print("[error] \(error.localizedDescription)")
                    }
                }
                // Allow the detached conversation-persist write to land before
                // the process exits (CLI-only concern; the running app stays up).
                try? await Task.sleep(nanoseconds: 300_000_000)
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --goal <goal>: run ONE goal through the full production
        // pipeline (AgentLoop.run → router | direct answer | planner →
        // validation → execution → verification) and print route + response.
        // Used for single-shot live validation (physical E2E probes); no
        // special benchmark behavior — the exact production path.
        if let goalIdx = CommandLine.arguments.firstIndex(of: "--goal"),
           CommandLine.arguments.count > goalIdx + 1 {
            setbuf(stdout, nil)
            let goal = CommandLine.arguments[goalIdx + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                ArgumentPreservationRecorder.shared.reset()
                do {
                    let response = try await AgentLoop.shared.run(goal: goal)
                    let route = await AgentLoop.shared.latestRoute()
                    print("[route] \(route?.rawValue ?? "unknown")")
                    print("[response] \(response)")
                } catch {
                    let route = await AgentLoop.shared.latestRoute()
                    print("[route] \(route?.rawValue ?? "unknown")")
                    print("[error] \(error.localizedDescription)")
                }
                // Argument-preservation chain evidence (byte-exact metric).
                for rec in ArgumentPreservationRecorder.shared.records(forGoal: goal) {
                    let verdict = rec.preserved.map { $0 ? "true" : "false" } ?? "n/a"
                    print("[preservation] extracted=\(rec.extractedLiteral ?? "nil") compiled=\(rec.compiledLiteral ?? "nil") executed=\(rec.executedLiteral ?? "nil") preserved=\(verdict)")
                }
                // Planner ledger: raw outputs of this run's attempts (diagnostics).
                let ledger = await MLXPlanner.shared.allLedgerRecords()
                for rec in ledger.suffix(4) {
                    print("[planner-attempt \(rec.attempt)] parseFailed=\(rec.parseStageFailed) validatorError=\(rec.validatorError ?? "none") repair=\(rec.isRepair) prompt=\(rec.promptSHA256.prefix(8))")
                    print("[raw] \(rec.rawOutput)")
                }
                // Allow the detached conversation-persist write to land before
                // the process exits (CLI-only concern; the running app stays up).
                try? await Task.sleep(nanoseconds: 300_000_000)
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --routing-benchmark flag: route-attributed planner routing
        // benchmark (repeated trials, argument-preservation metric, offline
        // replay of structural repair + compilation gates).
        // Optional segment argument: OFFLINE (replay only, no model) or LIVE
        // (matrix only) so each fits a single invocation. LIVE additionally
        // accepts a case-id filter (e.g. `--routing-benchmark LIVE arg-punct`)
        // so the model-involved matrix runs in bounded segments with identical
        // goals, repetitions, scoring, and route attribution.
        if CommandLine.arguments.contains("--routing-benchmark") {
            setbuf(stdout, nil)
            let segIdx = CommandLine.arguments.firstIndex(of: "--routing-benchmark")!
            let segment = CommandLine.arguments.count > segIdx + 1 ? CommandLine.arguments[segIdx + 1] : nil
            let caseFilter: String? = segment == "LIVE" && CommandLine.arguments.count > segIdx + 2
                ? CommandLine.arguments[segIdx + 2] : nil
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                switch segment {
                case "OFFLINE": PlannerRoutingBenchmark.runOfflineReplay()
                case "LIVE": await PlannerRoutingBenchmark.runLiveMatrix(caseFilter: caseFilter)
                default: await PlannerRoutingBenchmark.runAll()
                }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --benchmark flag for the fixed planner benchmark (Phase D.5)
        if CommandLine.arguments.contains("--benchmark") {
            setbuf(stdout, nil)
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await PlannerBenchmark.runAll()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --schema-experiment flag: Change A+B schema-contract
        // experiment protocol (reporting-only; same production path as the audit).
        // Optional segment argument: DA | DF | DIRECT | CONTROLS — runs just
        // that segment so each fits a single terminal invocation.
        if CommandLine.arguments.contains("--schema-experiment") {
            let segIdx = CommandLine.arguments.firstIndex(of: "--schema-experiment")!
            let segment = CommandLine.arguments.count > segIdx + 1 ? CommandLine.arguments[segIdx + 1] : nil
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                if let segment { await SchemaExperiment.runSegment(segment) } else { await SchemaExperiment.runProtocol() }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --sequential-experiment flag: Tier-A sequential-decomposition
        // experiment (reporting-only; same production path as the audit).
        // Mandatory phase argument: BASELINE (single-shot full-plan) or SEQA
        // (sequential next-step planning).
        if CommandLine.arguments.contains("--sequential-experiment") {
            let phaseIdx = CommandLine.arguments.firstIndex(of: "--sequential-experiment")!
            let phase = CommandLine.arguments.count > phaseIdx + 1
                ? CommandLine.arguments[phaseIdx + 1].uppercased() : ""
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                SequentialExperiment.phaseTag = phase + (CommandLine.arguments.count > phaseIdx + 2 ? "-" + CommandLine.arguments[phaseIdx + 2] : "")
                let benchFilter: String? = CommandLine.arguments.count > phaseIdx + 2 ? CommandLine.arguments[phaseIdx + 2] : nil
                switch phase {
                case "BASELINE":
                    SequentialExperiment.mode = .fullPlan
                    await SequentialExperiment.runPhase(phaseTitle: "BASELINE (single-shot full-plan)", only: benchFilter)
                case "SEQA":
                    SequentialExperiment.mode = .sequential
                    await SequentialExperiment.runPhase(phaseTitle: "EXPERIMENT A (sequential next-step)", only: benchFilter)
                default:
                    print("Unknown phase '\(phase)' — use --sequential-experiment BASELINE | SEQA [B1|B2|B3|B4|B5]")
                }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --escalation-audit flag: Milestone 3 peer edge-case harness
        if CommandLine.arguments.contains("--escalation-audit") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await EscalationAudit.runAll()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        // Handle --audit flag for real hardware integration verification
        if CommandLine.arguments.contains("--audit") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await IntegrationAudit.runAll()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
