import Foundation
import Testing
@testable import Jarvis

/// Bounded-retention coverage for durable TaskState.
///
/// `maxPersistedTasks` caps how many tasks a checkpoint may contain. Before this
/// fix, `enablePersistence` HARD-THREW once the cap was reached, so the 65th
/// persistent task in a long-running session failed outright with
/// "TaskState snapshot task limit reached" (observed end-to-end as
/// "TaskState.persist failed"). Retention must reclaim the least
/// recovery-critical history instead — never an active, FAILED (recoverable), or
/// unstarted task — and fail closed only when every retained task is still live.
@Suite struct TaskStateRetentionTests {

    private static let cap = 64

    private func makeMachine() throws -> (TaskStateMachine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("task-state.json")
        return (TaskStateMachine(storageURL: url), root)
    }

    /// Enroll a single-step task and drive it to COMPLETED (terminal, reclaimable).
    @discardableResult
    private func enrollCompleted(_ machine: TaskStateMachine, _ index: Int) throws -> UUID {
        let task = machine.createTask(title: "retention fixture \(index)", goal: "retention goal \(index)")
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "fixture step", toolName: "read_file",
                     arguments: ["path": "fixture.txt"])
        ])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        guard try machine.enablePersistence(for: task.id) else {
            throw JarvisError.actionFailed(action: "retentionTest", reason: "completed fixture did not persist")
        }
        try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
        try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "out-\(index)")
        try machine.transition(taskId: task.id, to: .verifying)
        try machine.transition(taskId: task.id, to: .completed)
        return task.id
    }

    /// Enroll a single-step task left RUNNING (active, never reclaimable).
    @discardableResult
    private func enrollRunning(_ machine: TaskStateMachine, _ index: Int) throws -> UUID {
        let task = machine.createTask(title: "retention live \(index)", goal: "retention live goal \(index)")
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "live step", toolName: "read_file",
                     arguments: ["path": "fixture.txt"])
        ])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        guard try machine.enablePersistence(for: task.id) else {
            throw JarvisError.actionFailed(action: "retentionTest", reason: "live fixture did not persist")
        }
        return task.id
    }

    /// Enroll a single-step task and drive it to FAILED (recoverable, never reclaimable).
    @discardableResult
    private func enrollFailed(_ machine: TaskStateMachine, _ index: Int) throws -> UUID {
        let task = machine.createTask(title: "retention failed \(index)", goal: "retention failed goal \(index)")
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "failed step", toolName: "read_file",
                     arguments: ["path": "fixture.txt"])
        ])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        try machine.transition(taskId: task.id, to: .failed, error: "retention fixture failure")
        guard try machine.enablePersistence(for: task.id) else {
            throw JarvisError.actionFailed(action: "retentionTest", reason: "failed fixture did not persist")
        }
        return task.id
    }

    @Test func atCapacityNewTaskEvictsOldestCompletedInsteadOfFailing() throws {
        let (machine, root) = try makeMachine()
        defer { try? FileManager.default.removeItem(at: root) }

        var ids: [UUID] = []
        for index in 0..<Self.cap { ids.append(try enrollCompleted(machine, index)) }
        // Newest completed task must remain persisted across the eviction.
        #expect(machine.isPersisted(taskId: ids[Self.cap - 1]))

        // The 65th task must enroll successfully rather than throw.
        let fresh = try enrollRunning(machine, Self.cap)
        #expect(machine.isPersisted(taskId: fresh), "the 65th persistent task must be enrolled, not rejected")

        // Exactly one completed slot was reclaimed; newer history is retained.
        let persistedOriginals = ids.filter { machine.isPersisted(taskId: $0) }
        #expect(persistedOriginals.count == Self.cap - 1)
        #expect(machine.isPersisted(taskId: ids[Self.cap - 1]), "the newest completed task must not be evicted")
        #expect(!machine.isPersisted(taskId: ids[0]), "the oldest completed task is the reclaim target")
    }

    @Test func failedAndActiveTasksAreNeverEvicted() throws {
        let (machine, root) = try makeMachine()
        defer { try? FileManager.default.removeItem(at: root) }

        // 63 FAILED (recoverable) + 1 COMPLETED (the only eligible slot).
        var failedIDs: [UUID] = []
        for index in 0..<(Self.cap - 1) { failedIDs.append(try enrollFailed(machine, index)) }
        let completedID = try enrollCompleted(machine, Self.cap - 1)

        let fresh = try enrollRunning(machine, Self.cap)
        #expect(machine.isPersisted(taskId: fresh))
        #expect(!machine.isPersisted(taskId: completedID), "the completed task is the reclaim target")
        #expect(failedIDs.allSatisfy { machine.isPersisted(taskId: $0) },
                "FAILED recoverable tasks must never be evicted")
    }

    @Test func allLiveStoreFailsClosed() throws {
        let (machine, root) = try makeMachine()
        defer { try? FileManager.default.removeItem(at: root) }

        // 64 active/running tasks: nothing is safely reclaimable.
        for index in 0..<Self.cap { _ = try enrollRunning(machine, index) }

        var rejected = false
        do {
            _ = try enrollRunning(machine, Self.cap)
        } catch {
            rejected = true
        }
        #expect(rejected, "with every retained task live, exhaustion must fail closed")
    }
}
