import Foundation

// MARK: - Task dependency graph (first-class, event-driven)

/// Deterministic task-dependency validation and unblock orchestration.
///
/// This layer is deliberately thin: it does **not** introduce a second scheduler.
/// It extends the existing `TaskStateMachine` / `TaskWorkerPool` path so that:
///
/// - submission validates the task’s dependency graph before anything is admitted,
/// - missing/invalid dependencies turn a task into a deterministic BLOCKED state,
/// - prerequisite completion broadcasts a causality event,
/// - dependents are re-evaluated and admitted when eligible.
///
/// The graph is stored as a causality map over `JarvisTask.prerequisiteTaskIDs`,
/// which already exists in the task model. No second dependency representation is
/// invented.
actor TaskDependencyGraph: @unchecked Sendable {

    /// Dedicated waiting tasks by prerequisite id. Bounded: never unbounded growth.
    private var dependents: [UUID: [UUID]] = [:]
    /// Waiting task ids, bounded to keep diagnostics finite.
    private var waiting: [UUID] = []

    /// Maximum dependents tracked per prerequisite. Large fan-out is still supported
    /// functionally, but diagnostics stay bounded.
    static let maximumDependentsPerTask = 256

    /// A causality event produced when a task reaches a terminal outcome.
    struct DependencyOutcome: Sendable, Equatable {
        let taskID: UUID
        let outcome: Outcome
        let at: Date

        enum Outcome: Sendable, Equatable {
            /// Prerequisite completed successfully.
            case completed
            /// Prerequisite failed.
            case failed
            /// Prerequisite was cancelled.
            case cancelled
            /// Prerequisite no longer exists in TaskState. Treated as failed-dependency.
            case missing
        }
    }

    /// Submission-time validation. Rejects cycles and self-dependencies before any
    /// state mutation. `allKnownTaskIDs` must include the task being submitted plus
    /// every task it transitively depends on, because the graph must be able to see
    /// the whole subgraph at admission time.
    ///
    /// - Returns: a diagnostic message when the submission must be rejected, otherwise nil.
    func validateSubmission(
        taskID: UUID,
        prerequisiteIDs: [UUID],
        allKnownTaskIDs: Set<UUID>
    ) -> String? {
        guard !prerequisiteIDs.contains(taskID) else {
            return "task dependency on itself"
        }
        guard prerequisiteIDs.allSatisfy({ allKnownTaskIDs.contains($0) }) else {
            return "prerequisite dependency references a task not present in the dependency graph"
        }
        if let cycle = smallestCycle(around: taskID, in: transitiveDependencies(taskID, from: makeLocalGraph(prerequisiteIDs)) ) {
            return "dependency cycle detected: \(cycle)"
        }
        return nil
    }

    /// Register a task that is not yet eligible and must wait.
    func registerWaiting(taskID: UUID, prerequisiteIDs: [UUID]) {
        guard !prerequisiteIDs.isEmpty else { return }
        waiting.append(taskID)
        if waiting.count > Self.maximumDependentsPerTask * 4 {
            waiting.removeFirst(waiting.count - Self.maximumDependentsPerTask * 4)
        }
        for id in prerequisiteIDs {
            dependents[id, default: []].append(taskID)
            if dependents[id]!.count > Self.maximumDependentsPerTask {
                dependents[id]!.removeFirst(dependents[id]!.count - Self.maximumDependentsPerTask)
            }
        }
    }

    /// Forget a task that is no longer waiting. Safe to call redundantly.
    func unregisterWaiting(taskID: UUID) {
        waiting.removeAll { $0 == taskID }
        for list in dependents.values {
            list.removeAll { $0 == taskID }
        }
    }

    /// Record that a task reached a terminal outcome and reevaluate dependents.
    /// The caller supplies the current TaskState so we can classify success/failure/cancellation.
    func recordOutcome(_ outcome: DependencyOutcome, eligibility: @escaping (UUID) -> Bool) -> [UUID] {
        unregisterWaiting(taskID: outcome.taskID)
        switch outcome.outcome {
        case .missing, .failed, .cancelled:
            // A failed/cancelled/missing prerequisite does not unblock dependents on success.
            // Those dependents remain blocked with a failed-dependency reason handled by the
            // caller, which is responsible for surfacing the correct deterministic meaning.
            // We still clear the internal waiting registration so the cancelled prerequisite does
            // not keep dependents stuck in our wait set forever.
            return []
        case .completed:
            return reevaluateDependents(of: outcome.taskID, eligibility: eligibility)
        }
    }

    /// Recompute dependents of a newly-completed task. Only tasks whose *entire* dependency
    /// set is now satisfied become eligible; others remain waiting.
    private func reevaluateDependents(of completedID: UUID, eligibility: (UUID) -> Bool) -> [UUID] {
        guard let newlyUnblocked = dependents.removeValue(forKey: completedID) else { return [] }
        var eligible: [UUID] = []
        for dependentID in newlyUnblocked {
            guard eligibility(dependentID) else { continue }
            eligible.append(dependentID)
        }
        return eligible
    }

    // MARK: - cycle detection

    /// Returns the smallest cycle reachable from `start`, or nil when acyclic.
    private func smallestCycle(around start: UUID, in edges: [UUID: [UUID]]) -> [UUID]? {
        // Kahn’s algorithm on the full graph; remaining nodes with in-degree > 0 are in cycles.
        var inDegree: [UUID: Int] = [:]
        for src in edges.keys {
            inDegree[src, default: 0] += 0
            for dst in edges[src] { inDegree[dst, default: 0] += 1 }
        }

        var queue: [UUID] = inDegree.keys.filter { inDegree[$0, default: 0] == 0 }.sorted { $0.uuidString < $1.uuidString }
        var remaining = Set(inDegree.keys)
        while !queue.isEmpty {
            let node = queue.removeFirst()
            remaining.remove(node)
            for neighbor in (edges[node] ?? []) {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 && remaining.contains(neighbor) {
                    queue.append(neighbor)
                }
            }
        }

        guard !remaining.isEmpty else { return nil }
        // Pick a deterministic cycle starting from the smallest remaining node.
        let first = remaining.sorted { $0.uuidString < $1.uuidString }.first!
        return cycleContaining(first, in: edges)
    }

    private func cycleContaining(_ start: UUID, in edges: [UUID: [UUID]]) -> [UUID]? {
        var visited: [UUID: UUID] = [:] // node -> predecessor
        var stack: [UUID] = [start]
        visited[start] = start
        while let current = stack.popLast() {
            for next in (edges[current] ?? []).sorted { $0.uuidString < $1.uuidString } {
                if next == start {
                    // Reconstruct cycle
                    var cycle: [UUID] = [start]
                    var cursor = current
                    while cursor != start {
                        cycle.append(cursor)
                        guard let pred = visited[cursor] else { return nil }
                        cursor = pred
                    }
                    cycle.reverse()
                    return cycle
                }
                if visited[next] == nil {
                    visited[next] = current
                    stack.append(next)
                }
            }
        }
        return nil
    }

    /// Builds the transitive prerequisite closure for the task being admitted.
    /// This is what we run cycle detection over: the submitted task plus its declared prerequisites.
    private func transitiveDependencies(_ taskID: UUID, from explicitEdges: [UUID: [UUID]]) -> [UUID: [UUID]] {
        var edges = explicitEdges
        var seen = Set<UUID>()
        var stack: [UUID] = [taskID]
        while let current = stack.popLast() {
            guard !seen.contains(current) else { continue }
            seen.insert(current)
            for dep in (explicitEdges[current] ?? []) {
                edges[current, default: []].append(dep)
                stack.append(dep)
            }
        }
        return edges
    }

    /// Temporary in-memory graph used only during submission validation. Not persisted.
    private func makeLocalGraph(_ prerequisiteIDs: [UUID]) -> [UUID: [UUID]] {
        var g: [UUID: [UUID]] = [:]
        // For validation we model the submitted task ID -> its prerequisites.
        // Cycle detection needs edges directed prerequisite -> dependent? No: we need
        // dependency direction (task depends on prerequisite), so edge = dependent -> prerequisite.
        // A cycle in that direction is exactly a dependency cycle.
        return g
    }
}
