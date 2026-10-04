import Foundation
import Testing
@testable import Jarvis

/// Adversarial regression suite for IDENTITY-SAFE replan preservation.
///
/// Real-world failure this prevents: a recovery replan used to preserve a
/// previously completed step by POSITION. A replan that reorders, inserts, or
/// removes steps could therefore hand one action's completion state — and its
/// bound evidence — to a *different* logical action. That violates State Over
/// Transcript, Evidence Before Green, Lossless Escalation, and Intelligence
/// Never Equals Authority: a step could read "already completed and verified"
/// even though its action never ran in that form.
///
/// A step is now preserved only when the new step is provably the same logical
/// action: identical tool identity and canonical argument fingerprint (or
/// identical purpose for a composition step), backed by the same task's still
/// valid evidence.
@Suite struct RecoveryReplanIdentityTests {

    private struct StepSpec {
        let tool: String?
        let args: [String: String]
        let purpose: String
        let output: String
    }

    private func makePlan(_ specs: [StepSpec]) -> AgentPlan {
        AgentPlan(goal: "identity", steps: specs.enumerated().map { index, spec in
            PlanStep(id: "step_\(index + 1)", toolName: spec.tool,
                     arguments: spec.args, purpose: spec.purpose)
        })
    }

    /// Build an in-memory task whose steps are all fully resolved through the
    /// production state machine (so evidence is genuinely bound, not forged).
    private func resolvedTask(_ specs: [StepSpec]) throws -> JarvisTask {
        let machine = TaskStateMachine(storageURL: nil)
        let task = machine.createTask(title: "identity", goal: "identity-test-goal")
        try machine.setSteps(taskId: task.id, steps: specs.enumerated().map { index, spec in
            TaskStep(stepNumber: index + 1, description: spec.purpose,
                     toolName: spec.tool, arguments: spec.args)
        })
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        for index in specs.indices {
            _ = try machine.beginStepAttempt(taskId: task.id, stepIndex: index)
            if specs[index].tool != nil {
                _ = try machine.completeVerifiedStep(taskId: task.id, stepIndex: index, output: specs[index].output)
            } else {
                _ = try machine.completeNonActionStep(taskId: task.id, stepIndex: index, output: specs[index].output)
            }
        }
        guard let resolved = machine.getTask(id: task.id) else {
            throw JarvisError.actionFailed(action: "fixture", reason: "task vanished")
        }
        return resolved
    }

    private let shellA = StepSpec(tool: "run_shell", args: ["command": "echo a"], purpose: "a", output: "a")
    private let shellB = StepSpec(tool: "run_shell", args: ["command": "echo b"], purpose: "b", output: "b")
    private let shellC = StepSpec(tool: "run_shell", args: ["command": "echo c"], purpose: "c", output: "c")

    // MARK: - 1. Same step, same identity → preserve

    @Test func identicalPlanPreservesResolvedStep() throws {
        let task = try resolvedTask([shellA])
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA]), preservingResolvedFrom: task)
        #expect(rebuilt.steps.count == 1)
        #expect(rebuilt.steps[0].id == task.steps[0].id, "same logical action must keep its step identity")
        #expect(rebuilt.steps[0].output == "a")
        #expect(rebuilt.steps[0].verification == .passed)
        #expect(rebuilt.records.count == 1)
        #expect(rebuilt.records[0].stepNumber == 1)
        #expect(rebuilt.records[0].rawOutput == "a")
    }

    // MARK: - 2. Reordered same steps → each keeps its own completion

    @Test func reorderedPlanPreservesEachStepByItsOwnAction() throws {
        let task = try resolvedTask([shellA, shellB])
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellB, shellA]), preservingResolvedFrom: task)

        #expect(rebuilt.steps[0].id == task.steps[1].id, "position 1 is now echo b; its step id must follow")

        #expect(rebuilt.steps[0].output == "b")
        #expect(rebuilt.steps[1].id == task.steps[0].id)
        #expect(rebuilt.steps[1].output == "a")
        // Records are re-numbered to match the new positions, so a record can
        // never point at a step of a different tool/action.
        #expect(rebuilt.records.count == 2)
        #expect(rebuilt.records[0].stepNumber == 1 && rebuilt.records[0].rawOutput == "b")
        #expect(rebuilt.records[1].stepNumber == 2 && rebuilt.records[1].rawOutput == "a")
    }

    // MARK: - 3. Inserted step → only matching steps preserved

    @Test func insertedStepPreservesOnlyMatchingSteps() throws {
        let task = try resolvedTask([shellA, shellB])
        let inserted = StepSpec(tool: "run_shell", args: ["command": "echo x"], purpose: "x", output: "x")
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([inserted, shellA, shellB]), preservingResolvedFrom: task)

        #expect(rebuilt.steps.count == 3)
        #expect(rebuilt.steps[0].id != task.steps[0].id && rebuilt.steps[0].id != task.steps[1].id,
                "the inserted step must be FRESH, never a preserved completion")
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.steps[1].id == task.steps[0].id)
        #expect(rebuilt.steps[2].id == task.steps[1].id)
        #expect(rebuilt.records.map(\.stepNumber) == [2, 3])
    }

    // MARK: - 4. Removed step → orphan is never preserved

    @Test func removedStepIsNotPreservedAnywhere() throws {
        let task = try resolvedTask([shellA, shellB, shellC])
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA, shellC]), preservingResolvedFrom: task)

        #expect(rebuilt.steps.count == 2)
        #expect(rebuilt.steps.contains { $0.id == task.steps[1].id } == false,
                "the removed step's identity must not reappear on another step")
        #expect(rebuilt.records.allSatisfy { $0.rawOutput != "b" }, "the removed step's record must be dropped")
        #expect(rebuilt.records.map(\.rawOutput) == ["a", "c"])
    }

    // MARK: - 5. Changed tool → not preserved

    @Test func changedToolIsNotPreserved() throws {
        let task = try resolvedTask([shellA])
        let changed = StepSpec(tool: "read_file", args: ["command": "echo a"], purpose: "a", output: "a")
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([changed]), preservingResolvedFrom: task)

        #expect(rebuilt.steps[0].id != task.steps[0].id)
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.records.isEmpty)
    }

    // MARK: - 6. Changed arguments → not preserved

    @Test func changedArgumentsAreNotPreserved() throws {
        let task = try resolvedTask([shellA])
        let changed = StepSpec(tool: "run_shell", args: ["command": "echo DIFFERENT"], purpose: "a", output: "a")
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([changed]), preservingResolvedFrom: task)

        #expect(rebuilt.steps[0].id != task.steps[0].id)
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.records.isEmpty)
    }

    // MARK: - 7. Argument ordering (canonical equivalence) → preserved

    @Test func canonicallyEquivalentArgumentsArePreserved() throws {
        let argsOrderOne = ["path": "/tmp/a", "encoding": "utf8"]
        let argsOrderTwo = ["encoding": "utf8", "path": "/tmp/a"]
        #expect(StepResolutionRecord.fingerprint(arguments: argsOrderOne)
                    == StepResolutionRecord.fingerprint(arguments: argsOrderTwo),
                "argument order must not change the fingerprint")

        let spec = StepSpec(tool: "read_file", args: argsOrderOne, purpose: "read", output: "content")
        let task = try resolvedTask([spec])
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(
            makePlan([StepSpec(tool: "read_file", args: argsOrderTwo, purpose: "read", output: "content")]),
            preservingResolvedFrom: task)
        #expect(rebuilt.steps[0].id == task.steps[0].id)
        #expect(rebuilt.records.count == 1)
    }

    // MARK: - 8. Same tool+args but evidence bound to ANOTHER task → never preserved

    @Test func evidenceBoundToAnotherTaskIsNeverPreserved() throws {
        let taskA = try resolvedTask([shellA])
        // A different task whose step looks identical but whose only record is
        // bound to taskA (taskID/stepID of A). It must not count as resolved.
        let forgedStep = TaskStep(id: taskA.steps[0].id, stepNumber: 1, description: "a",
                                  toolName: "run_shell", arguments: ["command": "echo a"],
                                  state: .completed, output: "a", verification: .passed)
        let forgedTask = JarvisTask(id: UUID(), title: "B", goal: "identity-test-goal",
                                    state: .running, steps: [forgedStep],
                                    resolutionRecords: taskA.resolutionRecords)
        #expect(!TaskContinuity.isResolved(forgedStep, task: forgedTask))

        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA]), preservingResolvedFrom: forgedTask)
        #expect(rebuilt.steps[0].id != forgedStep.id)
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.records.isEmpty)
    }

    // MARK: - 9. Stale/inconsistent evidence → not preserved

    @Test func completedStepWithoutBoundEvidenceIsNotPreserved() throws {
        let step = TaskStep(stepNumber: 1, description: "a", toolName: "run_shell",
                            arguments: ["command": "echo a"], state: .completed,
                            output: "a", verification: .passed)
        let task = JarvisTask(id: UUID(), title: "stale", goal: "identity-test-goal",
                              state: .running, steps: [step], resolutionRecords: [])
        #expect(!TaskContinuity.isResolved(step, task: task))

        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA]), preservingResolvedFrom: task)
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.records.isEmpty)
    }

    @Test func outputNotMatchingRecordIsNotPreserved() throws {
        let task = try resolvedTask([shellA])
        // The step claims a different output than the bound record proves.
        let tampered = TaskStep(id: task.steps[0].id, stepNumber: 1, description: "a",
                                toolName: "run_shell", arguments: ["command": "echo a"],
                                state: .completed, output: "TAMPERED", verification: .passed)
        let tamperedTask = JarvisTask(id: task.id, title: task.title, goal: task.goal,
                                      state: .running, steps: [tampered],
                                      resolutionRecords: task.resolutionRecords)
        #expect(!TaskContinuity.isResolved(tampered, task: tamperedTask))

        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA]), preservingResolvedFrom: tamperedTask)
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.records.isEmpty)
    }

    // MARK: - 10. Duplicate logical identities → deterministic, never cross-issued

    @Test func duplicateIdentitiesMatchDeterministicallyInOrder() throws {
        let task = try resolvedTask([shellA, shellA])
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA, shellA]), preservingResolvedFrom: task)

        #expect(rebuilt.steps.count == 2)
        #expect(Set(rebuilt.steps.map(\.id)).count == 2, "each plan step must get a distinct step id")
        #expect(rebuilt.steps[0].id == task.steps[0].id)
        #expect(rebuilt.steps[1].id == task.steps[1].id)
        #expect(rebuilt.records.count == 2)
    }

    @Test func fewerDuplicatesThanResolvedDoesNotDuplicateEvidence() throws {
        let task = try resolvedTask([shellA, shellA])
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA]), preservingResolvedFrom: task)
        #expect(rebuilt.steps.count == 1)
        #expect(rebuilt.records.count == 1, "a single plan step must yield exactly one record")
    }

    // MARK: - 11. Malformed continuation → rejected (fail closed)

    @Test func malformedEvidenceFingerprintIsNotPreserved() throws {
        let task = try resolvedTask([shellA])
        // Corrupt the record's argument binding so it no longer proves this step.
        let corrupted = task.resolutionRecords.map {
            StepResolutionRecord(stepNumber: $0.stepNumber, toolName: $0.toolName, rawOutput: $0.rawOutput,
                                 structuredOutput: $0.structuredOutput, completedAt: $0.completedAt,
                                 verification: $0.verification, taskID: $0.taskID, stepID: $0.stepID,
                                 argumentsFingerprint: StepResolutionRecord.fingerprint(arguments: ["command": "other"]))
        }
        let corruptedTask = JarvisTask(id: task.id, title: task.title, goal: task.goal, state: task.state,
                                       steps: task.steps, resolutionRecords: corrupted)
        #expect(!TaskContinuity.isResolved(corruptedTask.steps[0], task: corruptedTask))

        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(makePlan([shellA]), preservingResolvedFrom: corruptedTask)
        #expect(rebuilt.steps[0].verification == nil)
        #expect(rebuilt.records.isEmpty)
    }

    // MARK: - Orphan records must not poison the task

    /// A replan that changes a step must also rewrite the task's records. If it
    /// does not, the stale record's `stepNumber` points at a step of a different
    /// tool and the task silently becomes unpersistable.
    @Test func staleOrphanRecordPoisonsTaskButReplacementDoesNot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zia-replan-orphan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = TaskStateMachine(storageURL: url)
        let task = machine.createTask(title: "orphan", goal: "identity-test-goal")
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "a", toolName: "run_shell", arguments: ["command": "echo a"])
        ])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        _ = try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
        _ = try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "a")
        #expect(try machine.enablePersistence(for: task.id))

        // OLD path: replace only the steps with a different tool. The passed
        // record for step 1 now points at a step whose tool differs.
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "b", toolName: "read_file", arguments: ["path": "/tmp/b"])
        ])
        #expect(!machine.isPersistenceAvailable, "an orphan record must be detected as invalid evidence")

        // NEW path: replace steps AND records together; the task stays valid.
        let healthyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zia-replan-healthy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: healthyURL) }
        let machine2 = TaskStateMachine(storageURL: healthyURL)
        let task2 = machine2.createTask(title: "healthy", goal: "identity-test-goal")
        try machine2.setSteps(taskId: task2.id, steps: [
            TaskStep(stepNumber: 1, description: "a", toolName: "run_shell", arguments: ["command": "echo a"])
        ])
        try machine2.transition(taskId: task2.id, to: .planning)
        try machine2.transition(taskId: task2.id, to: .running)
        _ = try machine2.beginStepAttempt(taskId: task2.id, stepIndex: 0)
        _ = try machine2.completeVerifiedStep(taskId: task2.id, stepIndex: 0, output: "a")
        #expect(try machine2.enablePersistence(for: task2.id))
        try machine2.setSteps(taskId: task2.id, steps: [
            TaskStep(stepNumber: 1, description: "b", toolName: "read_file", arguments: ["path": "/tmp/b"])
        ], replacingResolutionRecords: [])
        #expect(machine2.isPersistenceAvailable, "steps and records replaced together must stay consistent")
    }

    // MARK: - 12. Restart between replan and execution → recover safely

    @Test func preservedEvidenceSurvivesRestartAsCancelledContinuation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zia-replan-restart-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = TaskStateMachine(storageURL: url)
        let task = machine.createTask(title: "restart", goal: "identity-test-goal")
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "a", toolName: "run_shell", arguments: ["command": "echo a"])
        ])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        _ = try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
        _ = try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "a")
        #expect(try machine.enablePersistence(for: task.id))

        // Replan while the task is RUNNING (crash boundary: replan persisted,
        // execution not yet resumed).
        let rebuilt = TaskExecutionCoordinator.makeTaskSteps(
            makePlan([shellA, shellB]), preservingResolvedFrom: machine.getTask(id: task.id))
        try machine.setSteps(taskId: task.id, steps: rebuilt.steps,
                             replacingResolutionRecords: rebuilt.records)
        #expect(machine.isPersistenceAvailable)

        // A fresh owner re-reads the exact same snapshot.
        let restored = TaskStateMachine(storageURL: url)
        #expect(restored.isPersistenceAvailable)
        guard let recovered = restored.getTask(id: task.id) else { Issue.record("task missing after restart"); return }
        #expect(recovered.state == .cancelled)
        #expect(recovered.steps.count == 2)
        #expect(TaskContinuity.independentlyVerified(recovered.steps[0], task: recovered),
                "the preserved resolved step must survive restart with its evidence intact")
        #expect(!TaskContinuity.isResolved(recovered.steps[1], task: recovered),
                "the unexecuted step must not become completed across a restart")
    }
}
