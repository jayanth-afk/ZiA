import Foundation

// MARK: - Task orchestration eligibility + dependency unblock + resource gating

/// Orchestration helpers that extend the existing task/worker-pool path without
/// introducing a second scheduler.
///
/// Responsibilities:
/// - submission-time dependency validation (cycle/self/dependency-missing),
/// - deterministic BLOCKED/WAITING state when prerequisites are incomplete,
/// - event-driven unblock from `TaskDependencyGraph` into `TaskWorkerPool`,
/// - task-level resource gating via `TaskResourceLock` so that tasks declaring a
///   required resource serialize on that resource while independent resources stay
///   concurrent, and so that cancellation/failure/termination always releases held
///   resources and re-evaluates waiters.
/// - cooperation with the existing `ProviderResourceBroker` so provider admission
///   only happens once a task is actually eligible to run.
actor TaskOrchestration: @unchecked Sendable {

    private let graph: TaskDependencyGraph
    private let stateMachine: TaskStateMachine
    private let pool: TaskWorkerPool
    private let lock: TaskResourceLock

    /// Waiting task ids keyed by the reason they are not yet runnable. Used only for
    /// diagnostics and bounded cleanup; scheduling decisions never poll this.
    private var blockedByMissingPrerequisite: Set<UUID> = []
    private var blockedByDependencyCycle: Set<UUID> = []
    private var blockedByResourceWait: Set<UUID> = []

    static let shared = TaskOrchestration(
        graph: TaskDependencyGraph(),
        stateMachine: TaskStateMachine.shared,
        pool: TaskWorkerPool.shared,
        lock: TaskResourceLock()
    )

    init(graph: TaskDependencyGraph, stateMachine: TaskStateMachine, pool: TaskWorkerPool, lock: TaskResourceLock) {
        self.graph = graph
        self.stateMachine = stateMachine
        self.pool = pool
        self.lock = lock
    }

    // MARK: - submission

    struct SubmissionOutcome: Sendable, Equatable {
        let accepted: Bool
        let rejectedReason: String?
        let blockedReason: String?
        let dependentIDsMadeReady: [UUID]
    }

    /// Attempt to admit a task that already exists in `TaskStateMachine`.
    ///
    /// This is the integration seam requested by the mission: dependency validation
    /// and cycle validation happen here, before any provider admission or worker dispatch.
    /// If the task declares required resources and any of them is held, the task is
    /// registered as resource-blocked (not admitted) and will be re-evaluated when the
    /// resource is released.
    func submit(task: JarvisTask, priority: Int, prerequisiteIDs: [UUID]) async -> SubmissionOutcome {
        let taskID = task.id
        guard stateMachine.getTask(id: taskID) != nil else {
            return SubmissionOutcome(accepted: false, rejectedReason: "task not found", blockedReason: nil, dependentIDsMadeReady: [])
        }
        let knownIDs = Set(stateMachine.allTasks.map { $0.id })
        if let rejection = await graph.validateSubmission(
            taskID: taskID,
            prerequisiteIDs: prerequisiteIDs,
            existingDependents: await graph.dependencyEdges(),
            allKnownTaskIDs: knownIDs
        ) {
            blockedByDependencyCycle.insert(taskID)
            return SubmissionOutcome(accepted: false, rejectedReason: rejection, blockedReason: nil, dependentIDsMadeReady: [])
        }

        // If prerequisites are not satisfied yet, register as waiting and stay blocked.
        if !(await prerequisitesSatisfied(taskID: taskID, prerequisiteIDs)) {
            await graph.registerWaiting(taskID: taskID, prerequisiteIDs: prerequisiteIDs)
            blockedByMissingPrerequisite.insert(taskID)
            do {
                _ = try stateMachine.transition(taskId: taskID, to: .created, error: dependencyBlockedReason(prerequisiteIDs: prerequisiteIDs))
            } catch {
                // State transition is best-effort here; the authoritative eligibility check is the graph.
            }
            return SubmissionOutcome(accepted: false, rejectedReason: nil, blockedReason: dependencyBlockedReason(prerequisiteIDs: prerequisiteIDs), dependentIDsMadeReady: [])
        }

        // Prerequisites satisfied: try to admit, including resource gating.
        return await tryAdmit(taskID: taskID, priority: priority)
    }

    /// Try to admit a task whose prerequisites are already satisfied. If the task
    /// declares required resources and they are not all available, the task is
    /// registered as resource-blocked and NOT admitted; it will be re-evaluated when
    /// a resource is released.
    private func tryAdmit(taskID: UUID, priority: Int) async -> SubmissionOutcome {
        guard let task = stateMachine.getTask(id: taskID) else {
            return SubmissionOutcome(accepted: false, rejectedReason: "task not found", blockedReason: nil, dependentIDsMadeReady: [])
        }

        let resources = task.requiredResourceIDs
        if resources.isEmpty {
            // No resource gating: admit directly.
            return await admit(taskID: taskID, priority: priority)
        }

        // Try to acquire all required resources in deterministic (resource-id) order.
        let granted = await lock.acquireAll(resources: resources, task: taskID)
        if granted.count == resources.count {
            // All resources acquired: admit.
            return await admit(taskID: taskID, priority: priority)
        }

        // Could not acquire all resources: block on resources.
        blockedByResourceWait.insert(taskID)
        // Best-effort state update: record that the task is waiting on resources.
        do {
            _ = try stateMachine.transition(taskId: taskID, to: .created, error: resourceBlockedReason(taskID: taskID))
        } catch {
            // State transition is best-effort; the orchestration is the authority.
        }
        return SubmissionOutcome(accepted: false, rejectedReason: nil, blockedReason: resourceBlockedReason(taskID: taskID), dependentIDsMadeReady: [])
    }

    /// Admit a task that is fully eligible (prerequisites satisfied AND all required
    /// resources already acquired) to the existing worker pool.
    private func admit(taskID: UUID, priority: Int) async -> SubmissionOutcome {
        guard let task = stateMachine.getTask(id: taskID) else {
            return SubmissionOutcome(accepted: false, rejectedReason: "task not found", blockedReason: nil, dependentIDsMadeReady: [])
        }
        blockedByResourceWait.remove(taskID)
        Task { [pool, task] in
            await pool.submit(task: task, priority: priority)
            await self.clearBlockedByResourceWait(taskID)
        }
        return SubmissionOutcome(accepted: true, rejectedReason: nil, blockedReason: nil, dependentIDsMadeReady: [])
    }

    /// Recompute eligibility for a task that may have become ready after a prerequisite
    /// completed (or a resource was released). Returns the set of tasks that are now
    /// ready for worker-pool admission.
    func reevaluate(taskID: UUID) async -> [UUID] {
        guard let task = stateMachine.getTask(id: taskID) else { return [] }
        let prerequisiteIDs = task.prerequisiteTaskIDs

        // If the task is still blocked by a cycle, leave it alone.
        if blockedByDependencyCycle.contains(taskID) { return [] }

        // If prerequisites still missing, keep waiting registration accurate and stay blocked.
        if !(await prerequisitesSatisfied(taskID: taskID, prerequisiteIDs)) {
            await graph.registerWaiting(taskID: taskID, prerequisiteIDs: prerequisiteIDs)
            blockedByMissingPrerequisite.insert(taskID)
            blockedByResourceWait.remove(taskID)
            return []
        }

        // Prerequisites satisfied: clear dependency-waiting state and try to admit
        // (which will also handle resource gating).
        await graph.unregisterWaiting(taskID: taskID)
        blockedByMissingPrerequisite.remove(taskID)
        let priority = task.priority
        let outcome = await tryAdmit(taskID: taskID, priority: priority)
        if outcome.accepted {
            return [taskID]
        }
        // Not admitted due to resources: leave it in blockedByResourceWait (already set by tryAdmit).
        return []
    }

    /// Called when a task reaches a terminal outcome. Broadcasts to the dependency graph,
    /// releases any resources the task held, and re-evaluates resource-blocked waiters so
    /// that eligible dependents can be admitted.
    func recordOutcome(_ outcome: TaskDependencyGraph.DependencyOutcome) async -> [UUID] {
        blockedByDependencyCycle.remove(outcome.taskID)
        blockedByMissingPrerequisite.remove(outcome.taskID)
        blockedByResourceWait.remove(outcome.taskID)

        // Dependency unblock: ask the graph which dependents it would potentially unblock,
        // then filter by authoritative state and re-evaluate each.
        let potentiallyUnblocked = await graph.potentialDependents(of: outcome.taskID)
        var madeReady: [UUID] = []
        for id in potentiallyUnblocked {
            if prerequisitesSatisfied(taskID: id, stateMachine.getTask(id: id)?.prerequisiteTaskIDs ?? []) {
                madeReady.append(id)
            }
        }
        var newlyAdmitted: [UUID] = []
        for id in madeReady {
            let ready = await reevaluate(taskID: id)
            newlyAdmitted.append(contentsOf: ready)
        }

        // Release any resources the terminal task held, then re-evaluate resource-blocked
        // waiters so that tasks waiting on the released resources can make progress.
        await releaseAndReevaluateResourceWaiters(taskID: outcome.taskID)

        return newlyAdmitted
    }

    /// Release every resource owned by a task and then re-evaluate the resource-blocked
    /// wait set so that tasks whose resources just became available can be admitted.
    private func releaseAndReevaluateResourceWaiters(taskID: UUID) async {
        // For cancelled tasks, also remove the task from any wait queues (cleanup).
        if let task = stateMachine.getTask(id: taskID), task.state == .cancelled {
            await lock.cancel(task: taskID)
        } else {
            await lock.releaseAll(task: taskID)
        }

        // Re-evaluate every resource-blocked task. A release may have freed a resource
        // that one of these tasks needs, so each gets a fresh acquire attempt (which
        // grants whatever is now free and enqueues for the first still-held resource).
        let waiters = blockedByResourceWait
        for id in waiters {
            // Only re-evaluate tasks that are still present in the state machine and not
            // terminal (a concurrent cancellation may have terminated it).
            guard let task = stateMachine.getTask(id: id) else { continue }
            if task.state.isTerminal { continue }
            let priority = task.priority
            let outcome = await tryAdmit(taskID: id, priority: priority)
            if outcome.accepted {
                blockedByResourceWait.remove(id)
            }
        }
    }

    // MARK: - eligibility

    func prerequisitesSatisfied(taskID: UUID, _ prerequisiteIDs: [UUID]) -> Bool {
        return stateMachine.arePrerequisitesSatisfied(taskId: taskID)
    }

    func dependencyBlockedReason(prerequisiteIDs: [UUID]) -> String {
        let ids = prerequisiteIDs.map { $0.uuidString.prefix(8) }.joined(separator: ", ")
        return "blocked: waiting for prerequisite task(s) [\(ids)]"
    }

    func resourceBlockedReason(taskID: UUID) -> String {
        guard let task = stateMachine.getTask(id: taskID) else { return "blocked: waiting for resource" }
        let ids = task.requiredResourceIDs.map { $0.prefix(8) }.joined(separator: ", ")
        return "blocked: waiting for resource(s) [\(ids)]"
    }

    func clearBlockedByResourceWait(_ taskID: UUID) {
        blockedByResourceWait.remove(taskID)
    }

    // MARK: - outcome mapping (production seam)

    /// Map a terminal task state to the dependency outcome broadcast that the
    /// dependency graph and waiting dependents expect.
    func outcomeForState(_ state: TaskState, taskID: UUID) -> TaskDependencyGraph.DependencyOutcome {
        let out: TaskDependencyGraph.DependencyOutcome.Outcome
        switch state {
        case .completed: out = .completed
        case .failed:    out = .failed
        case .cancelled: out = .cancelled
        default:         out = .missing
        }
        return TaskDependencyGraph.DependencyOutcome(taskID: taskID, outcome: out, at: Date())
    }

    /// Broadcast a terminal task outcome to the dependency graph and unblock
    /// eligible dependents. Best-effort: if the task is not in the state machine
    /// the outcome is treated as .missing, which still clears waiting state.
    func broadcastOutcome(taskID: UUID, state: TaskState) async {
        let outcome = outcomeForState(state, taskID: taskID)
        _ = await recordOutcome(outcome)
    }

    // MARK: - test seams

    /// Reset the orchestrator's mutable waiting/blocked state and its internal
    /// dependency graph and resource lock. Used only by integration tests that
    /// drive the production orchestration paths against the shared singletons.
    func resetForTesting() async {
        blockedByMissingPrerequisite.removeAll()
        blockedByDependencyCycle.removeAll()
        blockedByResourceWait.removeAll()
        await graph.clearForTesting()
        await lock.resetForTesting()
    }

    /// Test seam: return the set of task ids currently blocked on resources.
    func resourceBlockedTaskIDs() -> Set<UUID> { blockedByResourceWait }

    /// Test seam: return the set of task ids currently blocked on missing prerequisites.
    func prerequisiteBlockedTaskIDs() -> Set<UUID> { blockedByMissingPrerequisite }

    /// Test seam: return whether a task is currently blocked for any reason.
    func isBlocked(taskID: UUID) -> Bool { blockedByMissingPrerequisite.contains(taskID) || blockedByResourceWait.contains(taskID) || blockedByDependencyCycle.contains(taskID) }

    /// Test seam: return whether a task is fully eligible to run (prerequisites
    /// satisfied AND all required resources available/owned AND the task is not
    /// terminal). Does not mutate state.
    func isEligible(taskID: UUID) async -> Bool {
        guard let task = stateMachine.getTask(id: taskID) else { return false }
        if task.state.isTerminal { return false }
        if !stateMachine.arePrerequisitesSatisfied(taskId: taskID) { return false }
        let resources = task.requiredResourceIDs
        if resources.isEmpty { return true }
        for r in resources {
            if let owner = await lock.owner(of: r), owner != taskID { return false }
        }
        return true
    }

    /// Test seam: acquire all of the given resources for a task (via the real
    /// `TaskResourceLock.acquireAll`) WITHOUT submitting the task to the worker pool.
    /// This lets integration tests place a task into a resource-owning state
    /// deterministically, without triggering real worker execution that would race
    /// with the test's assertions.
    func acquireAllResources(resources: [String], task: UUID) async -> [String] {
        await lock.acquireAll(resources: resources, task: task)
    }

    /// Test seam: return whether a task currently owns a given resource.
    func lockOwns(resource: String, task: UUID) async -> Bool { await lock.owns(resource: resource, task: task) }

    /// Test seam: return whether a task is waiting for a given resource.
    func lockIsWaiting(task: UUID, resource: String) async -> Bool { await lock.isWaiting(task: task, resource: resource) }

    /// Test seam: return the current owner of a resource, if any.
    func lockOwner(of resource: String) async -> UUID? { await lock.owner(of: resource) }
}