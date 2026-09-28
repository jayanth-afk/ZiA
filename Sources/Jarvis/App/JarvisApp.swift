import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
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

        // Handle --benchmark flag for the fixed planner benchmark (Phase D.5)
        if CommandLine.arguments.contains("--benchmark") {
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
