import Foundation

// MARK: - Task-level resource lock manager

/// A small, deterministic task-level resource lock manager.
///
/// Responsibilities:
/// - Task-level exclusive ownership of named resources.
/// - Waiting queues per resource, drained in deterministic (task-id) order.
/// - Cancellation cleanup: a cancelled/failed task releases everything it owns
///   and is removed from any wait queue so it never holds a resource or a queue
///   slot forever.
/// - Deterministic acquisition ordering to prevent A↔B deadlocks when a task
///   needs more than one resource: the caller must request multiple resources
///   through `acquireAll(resources:task:)`, which acquires them in resource-id
///   order.
///
/// Independent resources remain fully concurrent: a task holding resource X does
/// not block a different task acquiring resource Y.
///
/// This is intentionally NOT a global lock and NOT a provider-capacity gate.
/// Provider capacity stays with `ProviderResourceBroker`. This manager handles
/// task-level resource ownership (e.g. a shared mutating resource that only one
/// task may touch at a time).
actor TaskResourceLock: @unchecked Sendable {

    /// Exclusive owner of a resource, if any.
    private var owners: [String: UUID] = [:]
    /// Waiting tasks per resource, ordered deterministically by task id.
    private var waiters: [String: [UUID]] = [:]
    /// Resources currently owned by each task (for cancellation cleanup).
    private var ownedByTask: [UUID: Set<String>] = [:]

    /// Acquire a single resource for a task.
    ///
    /// - Returns `true` if the resource was granted to the task.
    /// - Returns `false` if the resource is held by another task and this task
    ///   was enqueued as a waiter.
    ///
    /// Redundant calls (the task already owns the resource) are no-ops and return
    /// `true`.
    func acquire(resource: String, task: UUID) -> Bool {
        guard owners[resource] != task else { return true }
        if let currentOwner = owners[resource], currentOwner != task {
            // Resource held by another task: enqueue deterministically.
            let queue = waiters[resource, default: []]
            if !queue.contains(task) {
                waiters[resource] = (queue + [task]).sorted { $0.uuidString < $1.uuidString }
            }
            return false
        }
        // Resource free: grant it.
        owners[resource] = task
        ownedByTask[task, default: []].insert(resource)
        // Remove from any wait queue (in case the task was previously enqueued
        // under a stale request).
        waiters[resource]?.removeAll { $0 == task }
        return true
    }

    /// Release a resource previously acquired by a task.
    ///
    /// Safe to call redundantly. If the task does not own the resource, this is
    /// a no-op.
    func release(resource: String, task: UUID) {
        guard owners[resource] == task else { return }
        owners.removeValue(forKey: resource)
        ownedByTask[task]?.remove(resource)
        if ownedByTask[task]?.isEmpty == true {
            ownedByTask.removeValue(forKey: task)
        }
        // Drain the next deterministic waiter, if any.
        if let next = waiters[resource]?.removeFirst() {
            owners[resource] = next
            ownedByTask[next, default: []].insert(resource)
        } else {
            waiters.removeValue(forKey: resource)
        }
    }

    /// Acquire all of the given resources for a task in deterministic resource-id
    /// order. This is the deadlock-prevention entry point for multi-resource
    /// acquisition: by always acquiring in the same global order, cycles of the
    /// form "A waits for B, B waits for A" cannot form.
    ///
    /// - Returns the subset of resources that were granted immediately.
    /// - Resources not granted are enqueued; the caller must later poll or be
    ///   notified (via `waitingFor(task:)` or a re-evaluation loop) before
    ///   proceeding.
    /// - If the task already owns some of the resources, those are skipped.
    func acquireAll(resources: [String], task: UUID) -> [String] {
        let ordered = resources.sorted { $0 < $1 }
        var granted: [String] = []
        for resource in ordered {
            if acquire(resource: resource, task: task) {
                granted.append(resource)
            } else {
                // Stop the ordered walk: a later resource must not be acquired
                // before an earlier one is held, because that would violate the
                // deterministic ordering invariant and re-introduce deadlock risk.
                break
            }
        }
        return granted
    }

    /// Release all resources owned by a task.
    func releaseAll(task: UUID) {
        let resources = ownedByTask[task] ?? []
        for resource in resources {
            if owners[resource] == task {
                owners.removeValue(forKey: resource)
            }
            waiters[resource]?.removeAll { $0 == task }
            if waiters[resource]?.isEmpty == true {
                waiters.removeValue(forKey: resource)
            }
        }
        ownedByTask.removeValue(forKey: task)
    }

    /// Remove a task from every wait queue without granting it anything.
    /// Called when a task is cancelled/failed while waiting for resources, so it
    /// does not remain queued forever.
    func removeFromWaitQueues(task: UUID) {
        for key in waiters.keys {
            waiters[key]?.removeAll { $0 == task }
            if waiters[key]?.isEmpty == true {
                waiters.removeValue(forKey: key)
            }
        }
    }

    /// Full cancellation cleanup for a task: release everything it owns and remove
    /// it from every wait queue.
    func cancel(task: UUID) {
        releaseAll(task: task)
        removeFromWaitQueues(task: task)
    }

    // MARK: - diagnostics (bounded, read-only)

    /// Whether a task currently owns a resource.
    func owns(resource: String, task: UUID) -> Bool {
        owners[resource] == task
    }

    /// The current owner of a resource, if any.
    func owner(of resource: String) -> UUID? {
        owners[resource]
    }

    /// Whether a task is queued for a resource.
    func isWaiting(task: UUID, resource: String) -> Bool {
        waiters[resource]?.contains(task) == true
    }

    /// Snapshot of wait queue lengths, bounded to keep diagnostics finite.
    func waitQueueSummary() -> [String: Int] {
        var summary: [String: Int] = [:]
        for (resource, queue) in waiters {
            summary[resource] = min(queue.count, 256)
        }
        return summary
    }

    /// Reset the lock to an empty state. Used only by tests that need a clean
    /// lock without reconstructing the orchestrator.
    func resetForTesting() {
        owners.removeAll()
        waiters.removeAll()
        ownedByTask.removeAll()
    }
}
