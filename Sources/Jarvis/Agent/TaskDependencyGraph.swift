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
    private(set) var dependents: [UUID: [UUID]] = [:]
    /// Waiting task ids, bounded to keep diagnostics finite.
    private(set) var waiting: [UUID] = []

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
        for key in dependents.keys {
            dependents[key] = dependents[key]?.filter { $0 != taskID }
        }
    }

    /// Return the dependents that the graph would consider for reevaluation when `completedID`
    /// finishes. The caller is responsible for filtering those by its own Sendable eligibility
    /// predicate (e.g. the authoritative TaskStateMachine state) so that no non-Sendable closure
    /// crosses actor isolation boundaries.
    func potentialDependents(of completedID: UUID) async -> [UUID] {
        guard let newlyUnblocked = dependents.removeValue(forKey: completedID) else { return [] }
        return newlyUnblocked.sorted { $0.uuidString < $1.uuidString }
    }

    /// Read-only dependency-edges snapshot used by the orchestration layer for submission-time
    /// cycle detection and diagnostics. Dependent -> prerequisite direction.
    func dependencyEdges() -> [UUID: [UUID]] {
        var copy: [UUID: [UUID]] = [:]
        for (prereq, dependentsList) in dependents {
            for dependent in dependentsList {
                copy[dependent, default: []].append(prereq)
            }
        }
        return copy
    }

    // MARK: - submission-time validation

    /// Validate submission-time dependency graph for `taskID`. Returns a description of the
    /// first problem found, or nil when the submission is acyclic and self-consistent.
    func validateSubmission(
        taskID: UUID,
        prerequisiteIDs: [UUID],
        existingDependents: [UUID: [UUID]],
        allKnownTaskIDs: Set<UUID>
    ) -> String? {
        guard !prerequisiteIDs.contains(taskID) else {
            return "task dependency on itself"
        }
        guard prerequisiteIDs.allSatisfy({ allKnownTaskIDs.contains($0) }) else {
            return "prerequisite dependency references a task not present in the dependency graph"
        }
        let subgraph = buildSubgraph(taskID: taskID, prerequisiteIDs: prerequisiteIDs, existingDependents: existingDependents)
        if let cycle = smallestCycle(around: taskID, in: subgraph) {
            return "dependency cycle detected: \(cycle.map { $0.uuidString.prefix(8) }.joined(separator: " -> " ))"
        }
        return nil
    }

    // MARK: - cycle detection

    /// Build the dependency subgraph used for cycle detection: a "depends-on" graph where each
    /// node maps to the nodes it depends on. We start from `taskID` -> its declared prerequisites,
    /// then transitively include prerequisite-of-prerequisite edges that are already present in the
    /// graph (via `existingDependents`, which is the authoritative "who depends on whom" snapshot
    /// for already-registered waiting tasks). This catches indirect cycles such as a -> b -> c -> a.
    /// The walk is bounded to avoid pathological input.
    private func buildSubgraph(taskID: UUID, prerequisiteIDs: [UUID], existingDependents: [UUID: [UUID]]) -> [UUID: [UUID]] {
        var g: [UUID: [UUID]] = [:]
        var visited = Set<UUID>()
        var stack: [UUID] = [taskID]
        while let node = stack.popLast() {
            guard !visited.contains(node) else { continue }
            visited.insert(node)
            let deps = node == taskID ? prerequisiteIDs : (existingDependents[node] ?? [])
            g[node] = deps
            for d in deps where !visited.contains(d) {
                stack.append(d)
            }
            if visited.count > 256 { break }
        }
        return g
    }

    /// Returns the smallest cycle reachable from `start`, or nil when acyclic.
    func smallestCycle(around start: UUID, in edges: [UUID: [UUID]]) -> [UUID]? {
        var inDegree: [UUID: Int] = [:]
        for src in edges.keys {
            inDegree[src, default: 0] += 0
            if let dsts = edges[src] { for dst in dsts { inDegree[dst, default: 0] += 1 } }
        }

        var queue: [UUID] = inDegree.keys.filter { inDegree[$0, default: 0] == 0 }.sorted { $0.uuidString < $1.uuidString }
        var remaining = Set(inDegree.keys)
        while !queue.isEmpty {
            let node = queue.removeFirst()
            remaining.remove(node)
            if let neighbors = edges[node] {
                for neighbor in neighbors.sorted(by: { $0.uuidString < $1.uuidString }) {
                    inDegree[neighbor, default: 0] -= 1
                    if inDegree[neighbor] == 0 && remaining.contains(neighbor) {
                        queue.append(neighbor)
                    }
                }
            }
        }

        guard !remaining.isEmpty else { return nil }
        let first = remaining.sorted { $0.uuidString < $1.uuidString }.first!
        return cycleContaining(first, in: edges)
    }

    private func cycleContaining(_ start: UUID, in edges: [UUID: [UUID]]) -> [UUID]? {
        var visited: [UUID: UUID] = [:] // node -> predecessor
        var stack: [UUID] = [start]
        visited[start] = start
        while let current = stack.popLast() {
            if let neighbors = edges[current] {
                for next in neighbors.sorted(by: { $0.uuidString < $1.uuidString }) {
                    if next == start {
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
        }
        return nil
    }
}
