import Foundation

/// Manages a pool of concurrent background task workers with resource-aware capacity.
/// Subscribes to EmergencyStopEvent to ensure immediate cancellation of all background workers (Guardrail 3).
actor TaskWorkerPool {
    static let shared = TaskWorkerPool()

    private var workers: [TaskWorker]
    private var taskQueue: [JarvisTask] = []
    private var activeWorkerTasks: [UUID: Task<Void, Never>] = [:]
    private var isListeningToEmergencyStop: Bool = false

    private init() {
        self.workers = (0..<4).map { _ in TaskWorker() }
    }

    // MARK: - Setup

    /// Register listener for EmergencyStopEvent on EventBus.
    func registerEmergencyStopListener() async {
        guard !isListeningToEmergencyStop else { return }
        isListeningToEmergencyStop = true

        await EventBus.shared.subscribe(EmergencyStopEvent.self) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.cancelAll()
            }
        }
    }

    // MARK: - Capacity & Sizing

    /// Dynamic max worker count based on unified memory pressure.
    func getMaxConcurrentWorkers() async -> Int {
        let pressure = await MainActor.run { ResourceManager.shared.currentPressure }
        switch pressure {
        case .nominal:
            return 4
        case .warning:
            return 2
        case .critical:
            return 1
        }
    }

    /// Number of workers currently executing tasks.
    var busyWorkerCount: Int {
        get async {
            var count = 0
            for worker in workers {
                if await worker.isBusy {
                    count += 1
                }
            }
            return count
        }
    }

    // MARK: - Task Scheduling

    /// Submit a task to the pool. Runs immediately if a worker is available, or queues.
    func submit(task: JarvisTask) async {
        await registerEmergencyStopListener()

        let busy = await busyWorkerCount
        let limit = await getMaxConcurrentWorkers()

        if busy < limit, let availableWorker = await getAvailableWorker() {
            startTask(task, on: availableWorker)
        } else {
            taskQueue.append(task)
            JarvisLogger.actions.info("Task [\(task.id.uuidString.prefix(8))] queued. Queue depth: \(self.taskQueue.count)")
        }
    }

    private func getAvailableWorker() async -> TaskWorker? {
        for worker in workers {
            if await !worker.isBusy {
                return worker
            }
        }
        return nil
    }

    private func startTask(_ task: JarvisTask, on worker: TaskWorker) {
        let taskId = task.id
        let workerTask = Task {
            do {
                try await worker.execute(task: task)
            } catch {
                JarvisLogger.actions.warning("Worker task [\(taskId.uuidString.prefix(8))] ended with: \(error.localizedDescription)")
            }

            // Process next task in queue if available
            await self.onWorkerFinished(taskId: taskId)
        }

        activeWorkerTasks[taskId] = workerTask
    }

    private func onWorkerFinished(taskId: UUID) async {
        activeWorkerTasks.removeValue(forKey: taskId)

        // Dequeue next task if available
        if !taskQueue.isEmpty {
            let nextTask = taskQueue.removeFirst()
            if let worker = await getAvailableWorker() {
                startTask(nextTask, on: worker)
            } else {
                taskQueue.insert(nextTask, at: 0)
            }
        }
    }

    // MARK: - Cancellation (Guardrail 3 & 8)

    /// Cancel a specific task by ID.
    func cancelTask(id: UUID) async {
        // Remove from queue if pending
        taskQueue.removeAll { $0.id == id }

        // Cancel running task
        if let workerTask = activeWorkerTasks[id] {
            workerTask.cancel()
            activeWorkerTasks.removeValue(forKey: id)
        }

        for worker in workers {
            if await worker.currentTaskId == id {
                await worker.cancel()
            }
        }

        _ = try? TaskStateMachine.shared.transition(taskId: id, to: .cancelled, error: "Cancelled by user or system")
        JarvisLogger.actions.info("Cancelled task [\(id.uuidString.prefix(8))]")
    }

    /// Emergency cancellation of ALL running and queued tasks.
    func cancelAll() async {
        JarvisLogger.security.fault("EMERGENCY STOP: Cancelling all background workers and queued tasks")

        taskQueue.removeAll()

        for (_, workerTask) in activeWorkerTasks {
            workerTask.cancel()
        }
        activeWorkerTasks.removeAll()

        for worker in workers {
            await worker.cancel()
        }

        let active = TaskStateMachine.shared.activeTasks
        for task in active {
            _ = try? TaskStateMachine.shared.transition(taskId: task.id, to: .cancelled, error: "Emergency Stop triggered")
        }
    }
}
