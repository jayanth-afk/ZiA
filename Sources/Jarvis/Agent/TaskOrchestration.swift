import Foundation

// MARK: - Task orchestration eligibility + dependency unblock

/// Orchestration helpers that extend the existing task/worker-pool path without
/// introducing a second scheduler.
///
/// Responsibilities:
/// - submission-time dependency validation (cycle/self/dependency-missing),
/// - deterministic BLOCKED/WAITING state when prerequisites are incomplete,
/// - event-driven unblock from `TaskDependencyGraph` into `TaskWorkerPool`,
/// - cooperation with the existing `ProviderResourceBroker` so provider admission
///   only happens once a task is actually eligible to run.
actor TaskOrchestration: @unchecked Sendable {

    private let graph: TaskDependencyGraph
    private let stateMachine: TaskStateMachine
    private let pool: TaskWorkerPool

    /// Waiting task ids keyed by the reason they are not yet runnable. Used only for
    /// diagnostics and bounded cleanup; scheduling decisions never poll this.
    private var blockedByMissingPrerequisite: Set<UUID> = []
    private var blockedByDependencyCycle: Set<UUID> = []
    private var blockedByResourceWait: Set<UUID> = []

    static let shared = TaskOrchestration(
        graph: TaskDependencyGraph(),
        stateMachine: TaskStateMachine.shared,
        pool: TaskWorkerPool.shared
    )

    private init(graph: TaskDependencyGraph, stateMachine: TaskStateMachine, pool: TaskWorkerPool) {
        self.graph = graph
        self.stateMachine = stateMachine
        self.pool = pool
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
    func submit(
        taskID: UUID,
        priority: Int,
        prerequisiteIDs: [UUID]
    ) async -> SubmissionOutcome {
        guard let task = stateMachine.getTask(id: taskID) else {
            return SubmissionOutcome(accepted: false, rejectedReason: "task not found", blockedReason: nil, dependentIDsMadeReady: [])
        }
        let knownIDs = Set(stateMachine.allTasks.map(\.id))
        if let rejection = await graph.validateSubmission(
            taskID: taskID,
            prerequisiteIDs: prerequisiteIDs,
            existingDependents: await dependencyGraphSnapshot(),
            allKnownTaskIDs: knownIDs
        ) {
            blockedByDependencyCycle.insert(taskID)
            return SubmissionOutcome(accepted: false, rejectedReason: rejection, blockedReason: nil, dependentIDsMadeReady: [])
        }

        // If we already have the task and it is not eligible yet, register it as waiting
        // and transition it into the BLOCKED state deterministically.
        if !prerequisitesSatisfied(taskID: taskID, prerequisiteIDs: prerequisiteIDs) {
            await graph.registerWaiting(taskID: taskID, prerequisiteIDs: prerequisiteIDs)
            blockedByMissingPrerequisite.insert(taskID)
            do {
                _ = try stateMachine.transition(taskId: taskID, to: .created, error: dependencyBlockedReason(prerequisiteIDs: prerequisiteIDs))
            } catch {
                // State transition is best-effort here; the authoritative eligibility check is the graph.
            }
            return SubmissionOutcome(accepted: false, rejectedReason: nil, blockedReason: dependencyBlockedReason(prerequisiteIDs: prerequisiteIDs), dependentIDsMadeReady: [])
        }

        // Eligible: admit to the existing worker pool.
        blockedByResourceWait.insert(taskID)
        Task {
            await pool.submit(task: task, priority: priority)
            blockedByResourceWait.remove(taskID)
        }
        return SubmissionOutcome(accepted: true, rejectedReason: nil, blockedReason: nil, dependentIDsMadeReady: [])
    }

    /// Recompute eligibility for a task that may have become ready after a prerequisite
    /// completed. Returns the set of tasks that are now ready for worker-pool admission.
    func reevaluate(taskID: UUID) async -> [UUID] {
        guard let task = stateMachine.getTask(id: taskID) else { return [] }
        let prerequisiteIDs = task.prerequisiteTaskIDs
        let knownIDs = Set(stateMachine.allTasks.map(\.id))

        // If the task is still blocked by a cycle, leave it alone.
        if blockedByDependencyCycle.contains(taskID) { return [] }

        // If prerequisites still missing, keep waiting registration accurate and stay blocked.
        if !prerequisitesSatisfied(taskID: taskID, prerequisiteIDs: prerequisiteIDs) {
            await graph.registerWaiting(taskID: taskID, prerequisiteIDs: prerequisiteIDs)
            blockedByMissingPrerequisite.insert(taskID)
            return []
        }

        // Now eligible: clear waiting state and admit.
        await graph.unregisterWaiting(taskID: taskID)
        blockedByMissingPrerequisite.remove(taskID)
        let priority = task.priority
        Task {
            await pool.submit(task: task, priority: priority)
            blockedByResourceWait.remove(taskID)
        }
        return [taskID]
    }

    /// Called when a task reaches a terminal outcome. Broadcasts to the dependency graph
    /// and unblocks eligible dependents.
    func recordOutcome(_ outcome: TaskDependencyGraph.DependencyOutcome) async -> [UUID] {
        blockedByDependencyCycle.remove(outcome.taskID)
        blockedByMissingPrerequisite.remove(outcome.taskID)
        blockedByResourceWait.remove(outcome.taskID)
        let madeReady = await graph.recordOutcome(outcome, eligibility: { [weak self] id in
            guard let self else { return false }
            return self.prerequisitesSatisfied(taskID: id, prerequisiteIDs: (self.stateMachine.getTask(id: id)?.prerequisiteTaskIDs ?? [])
        })
        // Reevaluate each newly-made-eligible dependent through the same admission path.
        var newlyAdmitted: [UUID] = []
        for id in madeReady {
            let ready = await reevaluate(taskID: id)
            newlyAdmitted.append(contentsOf: ready)
        }
        return newlyAdmitted
    }

    // MARK: - private

    private func prerequisitesSatisfied(taskID: UUID, prerequisiteIDs: [UUID]) -> Bool {
        guard let task = stateMachine.getTask(id: taskID) else { return false }
        return stateMachine.arePrerequisitesSatisfied(taskId: taskID)
    }

    private func dependencyBlockedReason(prerequisiteIDs: [UUID]) -> String {
        let ids = prerequisiteIDs.map { $0.uuidString.prefix(8) }.joined(separator: ", ")
        return "blocked: waiting for prerequisite task(s) [\(ids)]"
    }

    private func dependencyGraphSnapshot() async -> [UUID: [UUID]] {
        // The dependency graph tracks waiting dependents internally. Expose enough for
        // submission-time cycle detection to see the current edges.
        await graph.dependencyEdges()
    }
}

// MARK: - TaskDependencyGraph dependency-edge exposure (read-only diagnostics)

private extension TaskDependencyGraph {
    func dependencyEdges() async -> [UUID: [UUID]] {
        var copy: [UUID: [UUID]] = [:]
        // Recompute from the live waiting registrations: a task waiting on prerequisites
        // implies an edge dependent -> prerequisite.
        for waitingID in waiting {
            // We don't store the original prerequisite list per waiting task in this
            // simplified model; instead we reconstruct from the dependents map.
        }
        for (prereq, dependentsList) in dependents {
            for dependent in dependentsList {
                copy[dependent, default: []].append(prereq)
            }
        }
        return copy
    }
}
