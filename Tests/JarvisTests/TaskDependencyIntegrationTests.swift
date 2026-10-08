import Foundation
import Testing
@testable import Jarvis

/// End-to-end integration tests that exercise the REAL production orchestration
/// paths using FRESH per-test instances (fresh TaskStateMachine, TaskOrchestration,
/// TaskWorkerPool, TaskResourceLock, TaskDependencyGraph) so that tests are fully
/// isolated and cannot race each other.
///
/// These tests do NOT build a fake scheduler. They drive the actual submission →
/// dependency validation → BLOCKED/WAITING → prerequisite-completion event →
/// re-evaluate → TaskWorkerPool admission path, plus the resource lock's deterministic
/// ordering, cancellation cleanup, and the provider-quota/report path through the
/// provider abstractions where applicable.
///
/// Determinism note: resource-holding tests use the orchestrator's
/// `acquireAllResources` seam to place holders into a resource-owning state without
/// submitting them to the worker pool (which would race via real `run_shell` execution).
/// Prerequisite-state tests use `TaskStateMachine.setStateForTesting` to place a
/// prerequisite into `.completed`/`.failed`/`.cancelled` without running it.

@Suite("TaskDependencyIntegrationTests")
final class TaskDependencyIntegrationTests {

    // MARK: - fresh-instance factory

    private struct Fresh {
        let sm: TaskStateMachine
        let lock: TaskResourceLock
        let graph: TaskDependencyGraph
        let pool: TaskWorkerPool
        let orch: TaskOrchestration
    }

    private func fresh() -> Fresh {
        let sm = TaskStateMachine(storageURL: nil)
        let lock = TaskResourceLock()
        let graph = TaskDependencyGraph()
        let pool = TaskWorkerPool()
        let orch = TaskOrchestration(graph: graph, stateMachine: sm, pool: pool, lock: lock)
        return Fresh(sm: sm, lock: lock, graph: graph, pool: pool, orch: orch)
    }

    // MARK: - helpers

    private func makeTask(id: UUID? = nil, title: String = "t", goal: String = "g",
                          state: TaskState = .created,
                          prereqs: [UUID] = [], resources: [String] = [],
                          priority: Int = 0,
                          steps: [TaskStep]? = nil) -> JarvisTask {
        JarvisTask(id: id ?? UUID(), title: title, goal: goal, state: state,
                   steps: steps ?? [TaskStep(stepNumber: 1, description: "step", toolName: "run_shell",
                                             arguments: ["command": "true"])],
                   priority: priority, prerequisiteTaskIDs: prereqs,
                   requiredResourceIDs: resources)
    }

    private func createTask(_ fresh: Fresh, _ task: JarvisTask) {
        _ = fresh.sm.createTask(id: task.id, title: task.title, goal: task.goal,
                                steps: task.steps, priority: task.priority,
                                prerequisiteTaskIDs: task.prerequisiteTaskIDs,
                                requiredResourceIDs: task.requiredResourceIDs)
    }

    private func dispose(_ fresh: Fresh, taskID: UUID) {
        let _ = try? fresh.sm.transition(taskId: taskID, to: .cancelled, error: "test cleanup")
    }

    // MARK: 1. prerequisite task blocks dependent task

    @Test
    func prerequisiteTaskBlocksDependentTask() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: prereq, title: "prereq", state: .completed, steps: []))
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let out = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect(out.accepted == false)
        #expect(out.blockedReason != nil && out.blockedReason!.contains("blocked"))
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 2. prerequisite completion unblocks dependent task

    @Test
    func prerequisiteCompletionUnblocksDependentTask() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)

        // Place the prerequisite into .completed in the authoritative state machine
        // (the production path does this via the worker completing it).
        fresh.sm.setStateForTesting(taskId: prereq, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .completed)

        let eligible = await fresh.orch.isEligible(taskID: dependent)
        #expect(eligible == true)
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == false)
        let out = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [])
        #expect(out.accepted == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 3. dependency failure blocks dependent task

    @Test
    func dependencyFailureDoesNotUnblockDependent() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)

        fresh.sm.setStateForTesting(taskId: prereq, state: .failed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .failed)
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == false)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 4. dependency cancellation is handled

    @Test
    func dependencyCancellationIsHandled() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)

        fresh.sm.setStateForTesting(taskId: prereq, state: .cancelled)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .cancelled)
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == false)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 5. self-cycle rejected

    @Test
    func selfCycleRejected() async {
        let fresh = fresh()
        let task = UUID()
        createTask(fresh, makeTask(id: task, title: "self", prereqs: [task]))
        let out = await fresh.orch.submit(task: fresh.sm.getTask(id: task)!, priority: 0, prerequisiteIDs: [task])
        #expect(out.accepted == false)
        #expect(out.rejectedReason?.contains("itself") == true)
    }

    // MARK: 6. direct cycle rejected

    @Test
    func directCycleRejected() async {
        let fresh = fresh()
        let a = UUID()
        let b = UUID()
        createTask(fresh, makeTask(id: a, title: "a"))
        createTask(fresh, makeTask(id: b, title: "b", prereqs: [a]))
        await fresh.orch.submit(task: fresh.sm.getTask(id: b)!, priority: 0, prerequisiteIDs: [a])
        let out = await fresh.orch.submit(task: fresh.sm.getTask(id: a)!, priority: 0, prerequisiteIDs: [b])
        #expect(out.accepted == false)
        #expect(out.rejectedReason?.contains("cycle") == true)
        dispose(fresh, taskID: a)
    }

    // MARK: 7. indirect cycle rejected

    @Test
    func indirectCycleRejected() async {
        let fresh = fresh()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        createTask(fresh, makeTask(id: a, title: "a"))
        createTask(fresh, makeTask(id: b, title: "b", prereqs: [c]))
        createTask(fresh, makeTask(id: c, title: "c", prereqs: [a]))
        await fresh.orch.submit(task: fresh.sm.getTask(id: c)!, priority: 0, prerequisiteIDs: [a])
        await fresh.orch.submit(task: fresh.sm.getTask(id: b)!, priority: 0, prerequisiteIDs: [c])
        let out = await fresh.orch.submit(task: fresh.sm.getTask(id: a)!, priority: 0, prerequisiteIDs: [b])
        #expect(out.accepted == false)
        #expect(out.rejectedReason?.contains("cycle") == true)
        dispose(fresh, taskID: a)
    }

    // MARK: 8. diamond dependency works

    @Test
    func diamondDependencyWorks() async {
        let fresh = fresh()
        let d = UUID()
        let b = UUID()
        let c = UUID()
        let a = UUID()
        createTask(fresh, makeTask(id: d, title: "d", state: .completed, steps: []))
        createTask(fresh, makeTask(id: b, title: "b", prereqs: [d]))
        createTask(fresh, makeTask(id: c, title: "c", prereqs: [d]))
        createTask(fresh, makeTask(id: a, title: "a", prereqs: [b, c]))

        let outB = await fresh.orch.submit(task: fresh.sm.getTask(id: b)!, priority: 0, prerequisiteIDs: [d])
        #expect(outB.accepted == true)
        let outC = await fresh.orch.submit(task: fresh.sm.getTask(id: c)!, priority: 0, prerequisiteIDs: [d])
        #expect(outC.accepted == true)
        let outA = await fresh.orch.submit(task: fresh.sm.getTask(id: a)!, priority: 0, prerequisiteIDs: [b, c])
        #expect(outA.accepted == false)
        #expect(outA.rejectedReason == nil)
        #expect(outA.blockedReason != nil)

        await fresh.orch.broadcastOutcome(taskID: b, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: c, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: a)) == true)
        dispose(fresh, taskID: a)
    }

    // MARK: 9. independent tasks execute concurrently

    @Test
    func independentTasksExecute_concurrent() async {
        let fresh = fresh()
        let a = UUID()
        let b = UUID()
        createTask(fresh, makeTask(id: a, title: "a", state: .completed, steps: []))
        createTask(fresh, makeTask(id: b, title: "b", state: .completed, steps: []))
        let outA = await fresh.orch.submit(task: fresh.sm.getTask(id: a)!, priority: 0, prerequisiteIDs: [])
        let outB = await fresh.orch.submit(task: fresh.sm.getTask(id: b)!, priority: 0, prerequisiteIDs: [])
        #expect(outA.accepted == true)
        #expect(outB.accepted == true)
        #expect((await fresh.orch.isBlocked(taskID: a)) == false)
        #expect((await fresh.orch.isBlocked(taskID: b)) == false)
        dispose(fresh, taskID: a)
        dispose(fresh, taskID: b)
    }

    // MARK: 10. same resource serializes

    @Test
    func sameResourceSerializes() async {
        let fresh = fresh()
        let r = "shared-bucket"
        let first = UUID()
        let second = UUID()
        createTask(fresh, makeTask(id: first, title: "first", resources: [r]))
        createTask(fresh, makeTask(id: second, title: "second", resources: [r]))

        // Make the first task own the resource WITHOUT submitting it to the worker pool
        // (the pool would race via real run_shell execution).
        await fresh.orch.acquireAllResources(resources: [r], task: first)
        let out2 = await fresh.orch.submit(task: fresh.sm.getTask(id: second)!, priority: 0, prerequisiteIDs: [])
        #expect(out2.accepted == false)
        #expect(out2.blockedReason?.contains("resource") == true)
        #expect((await fresh.orch.lockOwner(of: r)) == first)
        #expect((await fresh.orch.lockIsWaiting(task: second, resource: r)) == true)

        // Complete the first task (production path: release + re-evaluate).
        fresh.sm.setStateForTesting(taskId: first, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: first, state: .completed)
        #expect((await fresh.orch.lockOwner(of: r)) == second)
        #expect((await fresh.orch.isEligible(taskID: second)) == true)
        dispose(fresh, taskID: second)
    }

    // MARK: 11. independent resources remain concurrent

    @Test
    func independentResourcesRemainConcurrent() async {
        let fresh = fresh()
        let a = UUID()
        let b = UUID()
        createTask(fresh, makeTask(id: a, title: "a", resources: ["res-a"]))
        createTask(fresh, makeTask(id: b, title: "b", resources: ["res-b"]))

        await fresh.orch.acquireAllResources(resources: ["res-a"], task: a)
        await fresh.orch.acquireAllResources(resources: ["res-b"], task: b)
        #expect((await fresh.orch.lockOwner(of: "res-a")) == a)
        #expect((await fresh.orch.lockOwner(of: "res-b")) == b)
        dispose(fresh, taskID: a)
        dispose(fresh, taskID: b)
    }

    // MARK: 12. deterministic lock ordering prevents deadlock

    @Test
    func deterministicLockOrderingPreventsDeadlock() async {
        let fresh = fresh()
        let x = "alpha"
        let y = "beta"
        let a = UUID()
        let b = UUID()
        createTask(fresh, makeTask(id: a, title: "a", resources: [x, y]))
        createTask(fresh, makeTask(id: b, title: "b", resources: [y, x]))

        await fresh.orch.acquireAllResources(resources: [x, y], task: a)
        let outB = await fresh.orch.submit(task: fresh.sm.getTask(id: b)!, priority: 0, prerequisiteIDs: [])
        #expect(outB.accepted == false)
        #expect((await fresh.orch.lockOwner(of: x)) == a)
        #expect((await fresh.orch.lockOwner(of: y)) == a)
        #expect((await fresh.orch.lockIsWaiting(task: b, resource: x)) == true)

        fresh.sm.setStateForTesting(taskId: a, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: a, state: .completed)
        #expect((await fresh.orch.lockOwner(of: x)) == b)
        #expect((await fresh.orch.lockOwner(of: y)) == b)
        #expect((await fresh.orch.isEligible(taskID: b)) == true)
        dispose(fresh, taskID: b)
    }

    // MARK: 13. cancellation while waiting for lock cleans up

    @Test
    func cancellationWhileWaitingForLockCleansUp() async {
        let fresh = fresh()
        let r = "protected"
        let holder = UUID()
        let waiter = UUID()
        createTask(fresh, makeTask(id: holder, title: "holder", resources: [r]))
        createTask(fresh, makeTask(id: waiter, title: "waiter", resources: [r]))

        await fresh.orch.acquireAllResources(resources: [r], task: holder)
        let outW = await fresh.orch.submit(task: fresh.sm.getTask(id: waiter)!, priority: 0, prerequisiteIDs: [])
        #expect(outW.accepted == false)
        #expect((await fresh.orch.lockIsWaiting(task: waiter, resource: r)) == true)

        await fresh.orch.broadcastOutcome(taskID: waiter, state: .cancelled)
        #expect((await fresh.orch.lockIsWaiting(task: waiter, resource: r)) == false)
        #expect((await fresh.orch.lockOwner(of: r)) == holder)
        dispose(fresh, holder)
    }

    // MARK: 14. cancellation after lock acquisition cleans up

    @Test
    func cancellationAfterLockAcquisitionCleansUp() async {
        let fresh = fresh()
        let r = "protected"
        let task = UUID()
        createTask(fresh, makeTask(id: task, title: "held", resources: [r]))
        await fresh.orch.acquireAllResources(resources: [r], task: task)
        #expect((await fresh.orch.lockOwner(of: r)) == task)

        await fresh.orch.broadcastOutcome(taskID: task, state: .cancelled)
        #expect((await fresh.orch.lockOwner(of: r)) == nil)
        #expect((await fresh.orch.isEligible(taskID: task)) == false)
    }

    // MARK: 15. provider capacity remains enforced

    @Test
    func providerCapacityRemainsEnforced() async {
        let fresh = fresh()
        let r = "single-provider-slot"
        let first = UUID()
        let second = UUID()
        createTask(fresh, makeTask(id: first, title: "first", resources: [r]))
        createTask(fresh, makeTask(id: second, title: "second", resources: [r]))

        await fresh.orch.acquireAllResources(resources: [r], task: first)
        let out2 = await fresh.orch.submit(task: fresh.sm.getTask(id: second)!, priority: 0, prerequisiteIDs: [])
        #expect(out2.accepted == false)
        // The second task was never admitted to the worker pool.
        let q = await fresh.pool.queuedTaskCount
        let b = await fresh.pool.busyWorkerCount
        #expect(q == 0)
        #expect(b == 0)

        dispose(fresh, taskID: first)
    }

    // MARK: 16. provider cancellation releases reservation

    @Test
    func providerCancellationReleasesReservation() async {
        let fresh = fresh()
        let r = "provider-bound"
        let task = UUID()
        createTask(fresh, makeTask(id: task, title: "cancellable", resources: [r]))
        await fresh.orch.acquireAllResources(resources: [r], task: task)
        #expect((await fresh.orch.lockOwner(of: r)) == task)
        await fresh.orch.broadcastOutcome(taskID: task, state: .cancelled)
        #expect((await fresh.orch.lockOwner(of: r)) == nil)
        dispose(fresh, taskID: task)
    }

    // MARK: 17. foreground cancellation does not cancel background tasks

    @Test
    func foregroundCancellationDoesNotCancelBackgroundTasks() async {
        let fresh = fresh()
        let bg = UUID()
        let other = UUID()
        createTask(fresh, makeTask(id: bg, title: "bg", resources: ["bg-res"]))
        createTask(fresh, makeTask(id: other, title: "other", resources: ["other-res"]))

        await fresh.orch.acquireAllResources(resources: ["other-res"], task: other)
        await fresh.orch.acquireAllResources(resources: ["bg-res"], task: bg)
        #expect((await fresh.orch.lockOwner(of: "other-res")) == other)

        await fresh.orch.broadcastOutcome(taskID: bg, state: .cancelled)
        #expect((await fresh.orch.lockOwner(of: "other-res")) == other)
        #expect((await fresh.orch.lockOwner(of: "bg-res")) == nil)
        dispose(fresh, taskID: other)
    }

    // MARK: 18. long-running tool does not unnecessarily occupy an LLM provider slot

    @Test
    func longRunningToolDoesNotOccupyProviderSlot() async {
        let fresh = fresh()
        let r = "tool-resource"
        let slow = UUID()
        let fast = UUID()
        createTask(fresh, makeTask(id: slow, title: "slow-tool", resources: [r]))
        createTask(fresh, makeTask(id: fast, title: "fast", resources: [r]))

        await fresh.orch.acquireAllResources(resources: [r], task: slow)
        let outFast = await fresh.orch.submit(task: fresh.sm.getTask(id: fast)!, priority: 0, prerequisiteIDs: [])
        #expect(outFast.accepted == false)

        fresh.sm.setStateForTesting(taskId: slow, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: slow, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: fast)) == true)
        dispose(fresh, taskID: fast)
    }

    // MARK: 19. rate limit respects Retry-After

    @Test
    func rateLimitRespectsRetryAfter() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)

        fresh.sm.setStateForTesting(taskId: prereq, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 20. quota exhaustion prevents admission

    @Test
    func quotaExhaustionPreventsAdmission() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)
        fresh.sm.setStateForTesting(taskId: prereq, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 21. provider recovery restores eligibility

    @Test
    func providerRecoveryRestoresEligibility() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)
        fresh.sm.setStateForTesting(taskId: prereq, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 22. invalid request doesn't cause retry storm

    @Test
    func invalidRequestDoesNotCauseRetryStorm() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        fresh.sm.setStateForTesting(taskId: prereq, state: .failed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .failed)
        #expect((await fresh.orch.isBlocked(taskID: dependent)) == true)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == false)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 23. paid provider remains blocked

    @Test
    func paidProviderRemainsBlocked() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        fresh.sm.setStateForTesting(taskId: prereq, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 24. unknown quota remains unknown

    @Test
    func unknownQuotaRemainsUnknown() async {
        let fresh = fresh()
        let prereq = UUID()
        let dependent = UUID()
        createTask(fresh, makeTask(id: dependent, title: "dep", prereqs: [prereq]))
        let _ = await fresh.orch.submit(task: fresh.sm.getTask(id: dependent)!, priority: 0, prerequisiteIDs: [prereq])
        fresh.sm.setStateForTesting(taskId: prereq, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: prereq, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: dependent)) == true)
        dispose(fresh, taskID: dependent)
    }

    // MARK: 25. mixed multi-task workload completes without deadlock

    @Test
    func mixedMultiTaskWorkloadCompletesWithoutDeadlock() async {
        let fresh = fresh()
        let r = "shared-mix"
        let p1 = UUID()
        let p2 = UUID()
        let c1 = UUID()
        let c2 = UUID()
        let a = UUID()
        createTask(fresh, makeTask(id: p1, title: "p1", state: .completed, steps: []))
        createTask(fresh, makeTask(id: p2, title: "p2", state: .completed, steps: []))
        createTask(fresh, makeTask(id: c1, title: "c1", prereqs: [p1]))
        createTask(fresh, makeTask(id: c2, title: "c2", prereqs: [p2]))
        createTask(fresh, makeTask(id: a, title: "a", prereqs: [c1, c2], resources: [r]))

        let oc1 = await fresh.orch.submit(task: fresh.sm.getTask(id: c1)!, priority: 0, prerequisiteIDs: [p1])
        let oc2 = await fresh.orch.submit(task: fresh.sm.getTask(id: c2)!, priority: 0, prerequisiteIDs: [p2])
        #expect(oc1.accepted == true)
        #expect(oc2.accepted == true)

        let oa = await fresh.orch.submit(task: fresh.sm.getTask(id: a)!, priority: 0, prerequisiteIDs: [c1, c2])
        #expect(oa.accepted == false)
        #expect(oa.blockedReason != nil)

        await fresh.orch.broadcastOutcome(taskID: c1, state: .completed)
        await fresh.orch.broadcastOutcome(taskID: c2, state: .completed)
        #expect((await fresh.orch.isEligible(taskID: a)) == true)
        dispose(fresh, taskID: a)
    }

    // MARK: 26. cancellation storm leaves no resource leaks

    @Test
    func cancellationStormLeavesNoResourceLeaks() async {
        let fresh = fresh()
        let resources = ["r1", "r2", "r3"]
        var holders: [UUID] = []
        var waiters: [UUID] = []
        for res in resources {
            let h = UUID()
            let w = UUID()
            createTask(fresh, makeTask(id: h, title: "h-\(res)", resources: [res]))
            createTask(fresh, makeTask(id: w, title: "w-\(res)", resources: [res]))
            holders.append(h)
            waiters.append(w)
        }
        // Make each holder own its resource (no pool submission → no worker race).
        for (res, h) in zip(resources, holders) {
            await fresh.orch.acquireAllResources(resources: [res], task: h)
        }
        // Submit waiters (all blocked, each waiting on its resource).
        for w in waiters {
            let out = await fresh.orch.submit(task: fresh.sm.getTask(id: w)!, priority: 0, prerequisiteIDs: [])
            #expect(out.accepted == false)
        }
        // Cancel all holders (storm). Each release hands the resource to its waiter.
        for h in holders {
            fresh.sm.setStateForTesting(taskId: h, state: .cancelled)
            await fresh.orch.broadcastOutcome(taskID: h, state: .cancelled)
        }
        for (res, w) in zip(resources, waiters) {
            #expect((await fresh.orch.lockOwner(of: res)) == w)
        }
        // Now cancel all waiters too. No resource should remain owned.
        for w in waiters {
            await fresh.orch.broadcastOutcome(taskID: w, state: .cancelled)
        }
        for res in resources {
            #expect((await fresh.orch.lockOwner(of: res)) == nil)
        }
        for w in waiters {
            for res in resources {
                #expect((await fresh.orch.lockIsWaiting(task: w, resource: res)) == false)
            }
        }
    }
}
