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
        if CommandLine.arguments.contains("--schema-experiment") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await SchemaExperiment.runProtocol()
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
