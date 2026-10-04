import Foundation
import Testing
@testable import Jarvis

/// Regression: the recovery replan must actually take effect.
///
/// A real failure enters the bounded recovery chain
///   RUNNING → FAILED → RECOVERING → REPLANNING → replan → RUNNING
/// and the REPLANNED plan is what must run for the remainder of the task.
///
/// Before the fix, `TaskExecutionCoordinator.execute` captured the original
/// plan in an immutable parameter, so after a successful replan the loop kept
/// executing the ORIGINAL step's tool and arguments while the TaskSteps (and
/// therefore the recorded evidence identity) were replaced by the replan. Two
/// real failures followed:
///   1. Recovery was a no-op — the remediating tool the planner chose never ran,
///      so any task that needed a replan to recover could only fail again until
///      the retry budget was exhausted.
///   2. Evidence lied — a resolution record named/argument-bound the replanned
///      step while the output came from the original tool, i.e. an action whose
///      evidence claims a different tool/arguments than actually produced it.
///
/// This test drives the production coordinator with a fixed first plan that is
/// guaranteed to fail, installs a validated replan (through the same test seam
/// MLXPlanner uses), and asserts that the replanned tool output is what is
/// returned and recorded.
@Suite(.serialized) struct RecoveryReplanTests {

    /// Test-only tool that always throws, forcing a real recovery replan.
    private struct AlwaysFailingProbeTool: JarvisTool {
        let name = "recovery_replan_failing_probe"
        let description = "Test-only tool that always throws, exercising the recovery replan path"
        let impact: PermissionGate.ActionImpact = .readOnly
        func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
            throw JarvisError.actionFailed(action: name, reason: "intentional recovery-replan test failure")
        }
        func observe() async throws -> ObservationResult {
            ObservationResult(observations: ["status": "never-reached"])
        }
    }

    /// Test-only tool that succeeds, standing in for a replanned recovery step.
    private struct RecoveredProbeTool: JarvisTool {
        let name = "recovery_replan_recovered_probe"
        let description = "Test-only tool that succeeds, standing in for a replanned recovery step"
        let impact: PermissionGate.ActionImpact = .readOnly
        func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
            ToolResult(success: true, output: "recovery_replan_recovered_output")
        }
        func observe() async throws -> ObservationResult {
            ObservationResult(observations: ["status": "ok"])
        }
    }

    @Test @MainActor
    func validatedReplanIsExecutedAndItsEvidenceIsAttributedToIt() async throws {
        ToolRegistry.shared.register(AlwaysFailingProbeTool())
        ToolRegistry.shared.register(RecoveredProbeTool())

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zia-recovery-replan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let goal = "use the recovery_replan_failing_probe"
        let fixedPlan = AgentPlan(goal: goal, steps: [
            PlanStep(id: "step_1", toolName: "recovery_replan_failing_probe",
                     arguments: [:], purpose: "fail once, then recover")
        ])

        // A dedicated coordinator + state machine keeps this from mutating the
        // shared singletons other suites run against.
        let stateMachine = TaskStateMachine(storageURL: storageURL)
        let coordinator = TaskExecutionCoordinator()
        await coordinator.setReplanOverrideForTesting { _, _, _ in
            AgentPlan(goal: goal, steps: [
                PlanStep(id: "step_1", toolName: "recovery_replan_recovered_probe",
                         arguments: [:], purpose: "recover with a working tool")
            ])
        }

        let response = try await coordinator.run(
            goal: goal, stateMachine: stateMachine,
            fixedPlan: fixedPlan, stopRecoveryAfterAttempt: false)

        #expect(await coordinator.latestRoute() == .planner)
        #expect(await coordinator.latestReplanCount() > 0,
                "the failing step must have triggered at least one replan")
        #expect(response.contains("recovery_replan_recovered_output"),
                "the validated replan's tool must actually execute")

        let tasks = stateMachine.allTasks
        #expect(tasks.count == 1)
        guard let task = tasks.first else { return }
        #expect(task.state == .completed,
                "the task must complete through the replanned recovery step")

        let record = task.resolutionRecords.last
        #expect(record?.toolName == "recovery_replan_recovered_probe",
                "recorded evidence must name the tool that actually produced the output")
        #expect(record?.argumentsFingerprint == StepResolutionRecord.fingerprint(arguments: [:]),
                "recorded evidence must be bound to the executed step's arguments")

        let step = task.steps.first
        #expect(step?.toolName == "recovery_replan_recovered_probe")
        #expect(step?.verification == .passed)
        if let step {
            #expect(TaskContinuity.isResolved(step, task: task))
        }
    }
}
