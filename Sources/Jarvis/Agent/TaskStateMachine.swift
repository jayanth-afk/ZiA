import Foundation

/// Defines all states in the JARVIS task state machine.
/// Flow: CREATED -> PLANNING -> RUNNING -> VERIFYING -> COMPLETED
/// Recovery: FAILED -> RECOVERING -> REPLANNING -> RUNNING
/// Safety: CANCELLED (terminal from any non-completed state)
enum TaskState: String, Sendable, Codable {
    case created = "CREATED"
    case planning = "PLANNING"
    case running = "RUNNING"
    case verifying = "VERIFYING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case recovering = "RECOVERING"
    case replanning = "REPLANNING"
    case cancelled = "CANCELLED"

    /// Validates if transition to next state is permitted.
    func canTransition(to next: TaskState) -> Bool {
        // Can always cancel from any active (non-terminal) state
        if next == .cancelled && !isTerminal {
            return true
        }

        switch self {
        case .created:
            return next == .planning || next == .running
        case .planning:
            return next == .running || next == .failed
        case .running:
            return next == .verifying || next == .failed
        case .verifying:
            return next == .completed || next == .failed || next == .running
        case .failed:
            return next == .recovering
        case .recovering:
            return next == .replanning || next == .failed
        case .replanning:
            return next == .running || next == .failed
        case .completed, .cancelled:
            return false // Terminal states
        }
    }

    /// Whether this state is terminal (no further transitions allowed).
    var isTerminal: Bool {
        return self == .completed || self == .cancelled
    }
}
/// Explicit verification outcome for a task step (P1).
/// Task state records whether a step's result was independently verified —
/// it is never inferred from state/output text after the fact.
enum VerificationOutcome: String, Sendable, Codable {
    /// Tool executed and verification passed (observed state deterministically satisfies expected postcondition).
    case passed
    /// Verification ran and failed — observed state deterministically contradicts expected postcondition.
    case failed
    /// The system cannot establish whether the expected postcondition is true (cannot convert to passed).
    case inconclusive
    /// The required observation mechanism is unavailable (cannot convert to passed).
    case unavailable
    /// No verification applied (e.g. LLM composition step with no tool effect).
    case notApplicable

    /// Returns true ONLY if the outcome deterministically passed.
    var isVerified: Bool {
        return self == .passed
    }
}

/// A discrete step within a compound task.
struct TaskStep: Identifiable, Sendable, Codable {
    let id: UUID
    let stepNumber: Int
    let description: String
    let toolName: String?
    let arguments: [String: String]
    var state: TaskState
    var output: String?
    var error: String?
    var verification: VerificationOutcome?

    init(
        id: UUID = UUID(),
        stepNumber: Int,
        description: String,
        toolName: String? = nil,
        arguments: [String: String] = [:],
        state: TaskState = .created,
        output: String? = nil,
        error: String? = nil,
        verification: VerificationOutcome? = nil
    ) {
        self.id = id
        self.stepNumber = stepNumber
        self.description = description
        self.toolName = toolName
        self.arguments = arguments
        self.state = state
        self.output = output
        self.error = error
        self.verification = verification
    }
}

/// Represents an end-to-end task managed by the state machine.
struct JarvisTask: Identifiable, Sendable {
    let id: UUID
    let title: String
    let goal: String
    var state: TaskState
    var steps: [TaskStep]
    var currentStepIndex: Int
    var maxRetries: Int
    var retryCount: Int
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var error: String?
    var resolutionRecords: [StepResolutionRecord]
    var environmentContext: TaskEnvironmentContext?

    init(
        id: UUID = UUID(),
        title: String,
        goal: String,
        state: TaskState = .created,
        steps: [TaskStep] = [],
        currentStepIndex: Int = 0,
        maxRetries: Int = 3,
        retryCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        error: String? = nil,
        resolutionRecords: [StepResolutionRecord] = [],
        environmentContext: TaskEnvironmentContext? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.state = state
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.maxRetries = maxRetries
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.error = error
        self.resolutionRecords = resolutionRecords
        self.environmentContext = environmentContext
    }

    /// Progress completion percentage (0.0 to 1.0).
    var progress: Double {
        guard !steps.isEmpty else {
            return state == .completed ? 1.0 : 0.0
        }
        let completedSteps = steps.filter { $0.state == .completed }.count
        return Double(completedSteps) / Double(steps.count)
    }
}

/// Persistent task state machine enforcing state transitions and history.
/// Thread-safe via NSLock, callable synchronously or asynchronously from any actor or thread.
final class TaskStateMachine: @unchecked Sendable {
    private struct PersistedTask: Codable {
        let id: UUID
        let title: String
        let goal: String
        var state: TaskState
        var steps: [TaskStep]
        var currentStepIndex: Int
        var maxRetries: Int
        var retryCount: Int
        let createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
        var error: String?
        var resolutionRecords: [StepResolutionRecord]

        init(_ task: JarvisTask) {
            id = task.id
            title = task.title
            goal = task.goal
            state = task.state
            steps = task.steps
            currentStepIndex = task.currentStepIndex
            maxRetries = task.maxRetries
            retryCount = task.retryCount
            createdAt = task.createdAt
            updatedAt = task.updatedAt
            completedAt = task.completedAt
            error = task.error
            resolutionRecords = task.resolutionRecords
        }

        var task: JarvisTask {
            JarvisTask(id: id, title: title, goal: goal, state: state, steps: steps,
                       currentStepIndex: currentStepIndex, maxRetries: maxRetries,
                       retryCount: retryCount, createdAt: createdAt, updatedAt: updatedAt,
                       completedAt: completedAt, error: error, resolutionRecords: resolutionRecords)
        }
    }

    private struct PersistenceSnapshot: Codable {
        let schemaVersion: Int
        let tasks: [PersistedTask]
    }

    private struct InMemoryState {
        let tasks: [UUID: JarvisTask]
        let stateHistory: [UUID: [(TaskState, Date)]]
        let runAttribution: [UUID: UUID]
        let stepsHistory: [UUID: [(cycle: Int, steps: [TaskStep], at: Date)]]
        let persistentTaskIDs: Set<UUID>
        let persistenceHealthy: Bool
        let persistenceSuspended: Bool
    }

    static let shared = TaskStateMachine()

    private let lock = NSLock()
    private var tasks: [UUID: JarvisTask] = [:]
    private var stateHistory: [UUID: [(TaskState, Date)]] = [:]
    // Evidence-integrity pass: explicit run→task attribution. The harness uses
    // this INSTEAD of "latest task matching the goal" heuristics, which misattribute
    // evidence when several tasks share a goal string.
    private var runAttribution: [UUID: UUID] = [:]  // ledgerRunID -> taskID
    // Evidence-integrity pass: every setSteps() snapshot is preserved (indexed by
    // planning cycle) so a replan NEVER overwrites the evidence of earlier plans.
    private var stepsHistory: [UUID: [(cycle: Int, steps: [TaskStep], at: Date)]] = [:]
    private let persistenceURL: URL?
    private var persistentTaskIDs = Set<UUID>()
    private var persistenceHealthy = true
    private var persistenceSuspended = false

    private static let persistenceSchemaVersion = 1
    private static let maxPersistedTasks = 64
    private static let maxSnapshotBytes = 8 * 1_024 * 1_024

    private static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("task-state-v1.json", isDirectory: false)
    }

    init(storageURL: URL? = TaskStateMachine.defaultPersistenceURL) {
        persistenceURL = storageURL
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            guard data.count <= Self.maxSnapshotBytes else {
                throw JarvisError.actionFailed(action: "TaskState.restore", reason: "TaskState snapshot exceeds size limit")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let snapshot = try decoder.decode(PersistenceSnapshot.self, from: data)
            guard snapshot.schemaVersion == Self.persistenceSchemaVersion,
                  snapshot.tasks.count <= Self.maxPersistedTasks else {
                throw JarvisError.actionFailed(action: "TaskState.restore", reason: "TaskState snapshot schema or size is invalid")
            }

            var restored: [UUID: JarvisTask] = [:]
                        let restoreDate = Date()
            for persisted in snapshot.tasks {
                var task = persisted.task
                guard restored[task.id] == nil, Self.isValidPersistedTask(task) else {
                    throw JarvisError.actionFailed(action: "TaskState.restore", reason: "TaskState snapshot contains invalid or duplicate task evidence")
                }
                if [.created, .planning, .running, .verifying, .recovering, .replanning].contains(task.state) {
                    let interruptedState = task.state.rawValue
                    task.state = .cancelled
                    task.error = "Process interrupted while task was \(interruptedState)"
                    task.updatedAt = restoreDate
                    task.completedAt = task.updatedAt
                    for index in task.steps.indices where TaskContinuity.independentlyVerified(task.steps[index], task: task) {
                        task.steps[index].state = .completed
                        if task.steps[index].output == nil,
                           let record = task.resolutionRecords.last(where: { $0.stepNumber == task.steps[index].stepNumber }) {
                            task.steps[index].output = record.rawOutput
                        }
                    }
                }
                restored[task.id] = task
                stateHistory[task.id] = [(.created, task.createdAt), (task.state, task.updatedAt)]
                if !task.steps.isEmpty {
                    stepsHistory[task.id] = [(cycle: 0, steps: task.steps, at: task.updatedAt)]
                }
            }
            tasks = restored
            persistentTaskIDs = Set(restored.keys)
        } catch {
            tasks.removeAll()
            stateHistory.removeAll()
            stepsHistory.removeAll()
            persistentTaskIDs.removeAll()
            persistenceHealthy = false
            JarvisLogger.security.error("TaskState snapshot rejected; continuation is disabled: \(error.localizedDescription)")
        }
    }

    var isPersistenceAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return persistenceHealthy
    }

    /// Persist only after the caller has validated the exact plan with PlanValidator.
    @discardableResult
    func enablePersistence(for taskId: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !persistenceSuspended else { return false }
        guard persistenceHealthy, let persistenceURL else {
            throw JarvisError.actionFailed(action: "TaskState.persist", reason: "Durable TaskState is unavailable")
        }
        guard let task = tasks[taskId], Self.isValidPersistedTask(task) else {
            throw JarvisError.actionFailed(action: "TaskState.persist", reason: "Task is not valid for persistence")
        }
        guard Self.isSafeToPersist(task) else { return false }
        guard persistentTaskIDs.count < Self.maxPersistedTasks || persistentTaskIDs.contains(taskId) else {
            throw JarvisError.actionFailed(action: "TaskState.persist", reason: "TaskState snapshot task limit reached")
        }
        let inserted = persistentTaskIDs.insert(taskId).inserted
        do {
            try writeSnapshotLocked(to: persistenceURL)
            return true
        } catch {
            if inserted { persistentTaskIDs.remove(taskId) }
            persistenceHealthy = false
            throw error
        }
    }

    /// Isolate the shared owner during SelfTest without reading or writing production task state.
    func beginIsolatedTesting() -> () -> Void {
        lock.lock()
        let original = InMemoryState(tasks: tasks, stateHistory: stateHistory,
                                     runAttribution: runAttribution, stepsHistory: stepsHistory,
                                     persistentTaskIDs: persistentTaskIDs,
                                     persistenceHealthy: persistenceHealthy,
                                     persistenceSuspended: persistenceSuspended)
        tasks = [:]
        stateHistory = [:]
        runAttribution = [:]
        stepsHistory = [:]
        persistentTaskIDs = []
        persistenceSuspended = true
        lock.unlock()

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.tasks = original.tasks
            self.stateHistory = original.stateHistory
            self.runAttribution = original.runAttribution
            self.stepsHistory = original.stepsHistory
            self.persistentTaskIDs = original.persistentTaskIDs
            self.persistenceHealthy = original.persistenceHealthy
            self.persistenceSuspended = original.persistenceSuspended
            self.lock.unlock()
        }
    }

    private func persistIfEnabledLocked() {
        guard !persistenceSuspended, persistenceHealthy, let persistenceURL else { return }
        for taskID in Array(persistentTaskIDs) {
            guard let task = tasks[taskID] else {
                persistenceHealthy = false
                return
            }
            if !Self.isSafeToPersist(task) {
                persistentTaskIDs.remove(taskID)
                JarvisLogger.security.warning("TaskState persistence disabled for highly sensitive task \(taskID.uuidString.prefix(8))")
            } else if !Self.isValidPersistedTask(task) {
                return
            }
        }
        do {
            try writeSnapshotLocked(to: persistenceURL)
        } catch {
            persistenceHealthy = false
            JarvisLogger.security.error("TaskState checkpoint failed; restart continuation is disabled: \(error.localizedDescription)")
        }
    }

    private func writeSnapshotLocked(to url: URL) throws {
        let persistedTasks = persistentTaskIDs.compactMap { tasks[$0] }
            .sorted { $0.createdAt < $1.createdAt }
            .map(PersistedTask.init)
                guard persistedTasks.count <= Self.maxPersistedTasks,
                            persistedTasks.allSatisfy({ Self.isValidPersistedTask($0.task) && Self.isSafeToPersist($0.task) }) else {
                        throw JarvisError.actionFailed(action: "TaskState.persist", reason: "TaskState snapshot contains invalid or sensitive task data")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(PersistenceSnapshot(schemaVersion: Self.persistenceSchemaVersion,
                                                          tasks: persistedTasks))
        guard data.count <= Self.maxSnapshotBytes else {
            throw JarvisError.actionFailed(action: "TaskState.persist", reason: "TaskState snapshot exceeds size limit")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func isSafeToPersist(_ task: JarvisTask) -> Bool {
        let highSensitivityMarkers = ["password", "api_key", "apikey", "api key", "api-key", "sk-",
                                      "secret", "private_key", "bearer ", "token", "id_rsa", "ssn",
                                      "credit card", "payment card", "sudo "]
        let values = [task.title, task.goal, task.error ?? ""]
            + task.steps.flatMap { step in
                [step.description, step.output ?? "", step.error ?? ""]
                    + step.arguments.flatMap { [$0.key, $0.value] }
            }
            + task.resolutionRecords.map(\.rawOutput)
        let combined = values.joined(separator: "\n").lowercased()
        return !highSensitivityMarkers.contains(where: { combined.contains($0) })
    }

    private static func isValidPersistedTask(_ task: JarvisTask) -> Bool {
        guard !task.goal.isEmpty, !task.steps.isEmpty, task.steps.count <= 6,
              task.maxRetries > 0, task.retryCount >= 0, task.retryCount <= task.maxRetries,
              task.currentStepIndex >= 0, task.currentStepIndex <= task.steps.count else { return false }
        guard task.steps.enumerated().allSatisfy({ index, step in
            step.stepNumber == index + 1 && (step.toolName == nil || !step.toolName!.isEmpty)
        }) else { return false }
        guard task.resolutionRecords.allSatisfy({ record in
            record.stepNumber > 0 && record.stepNumber <= task.steps.count
                && task.steps[record.stepNumber - 1].toolName == record.toolName
                && record.rawOutput.utf8.count <= 1_048_576
        }) else { return false }
        for step in task.steps {
            let latestRecord = task.resolutionRecords.last(where: {
                $0.stepNumber == step.stepNumber && $0.toolName == step.toolName
            })
            if step.toolName != nil && step.state == .completed {
                guard step.verification == .passed, latestRecord?.verification == .passed else { return false }
            }
            if step.verification == .passed {
                guard step.toolName != nil, latestRecord?.verification == .passed,
                      step.state == .completed || step.state == .running || step.state == .cancelled else { return false }
            }
            if step.toolName == nil && step.state == .completed && step.verification != .notApplicable {
                return false
            }
        }
        if task.state == .completed {
            guard task.steps.allSatisfy({ TaskContinuity.isResolved($0, task: task) }) else { return false }
        }
        return true
    }

    // MARK: - Evidence attribution (instrumentation pass)

    /// Map a planner ledger runID to the task it belongs to. One agent run =
    /// one runID + one taskID, regardless of how many replan cycles occur.
    func registerRunAttribution(runID: UUID, taskID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        runAttribution[runID] = taskID
    }

    /// The task ID attributed to a planner ledger runID (nil if unattributed).
    func taskID(forRunID runID: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runAttribution[runID]
    }

    /// ALL tasks whose goal matches, in creation order (oldest first). Evidence
    /// consumers index this list explicitly (e.g. tasks[runIndex]) — they never
    /// rely on an implicit "last" match.
    func tasks(matchingGoal goal: String) -> [JarvisTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.values
            .filter { $0.goal == goal }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Preserved plan snapshots for a task: index 0 = initial planning,
    /// 1..n = successive replans. A replan appends; it never replaces history.
    func stepsHistory(for taskId: UUID) -> [(cycle: Int, steps: [TaskStep], at: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return stepsHistory[taskId] ?? []
    }

    // MARK: - Task Management

    /// Create and register a new task.
    @discardableResult
    func createTask(
        id: UUID = UUID(),
        title: String,
        goal: String,
        steps: [TaskStep] = [],
        environmentContext: TaskEnvironmentContext? = nil
    ) -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        let task = JarvisTask(id: id, title: title, goal: goal, steps: steps, environmentContext: environmentContext)
        tasks[task.id] = task
        stateHistory[task.id] = [(.created, Date())]

        JarvisLogger.actions.info("Created task [\(task.id.uuidString.prefix(8))]: '\(title)'")
        return task
    }

    /// Retrieve a task by ID.
    func getTask(id: UUID) -> JarvisTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]
    }

    /// Retrieve all active (non-terminal) tasks.
    var activeTasks: [JarvisTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.values.filter { !$0.state.isTerminal }
    }

    /// Retrieve all tasks.
    var allTasks: [JarvisTask] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values)
    }

    /// Transition a task to a new state if valid.
    @discardableResult
    func transition(taskId: UUID, to newState: TaskState, error: String? = nil) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.transition", reason: "Task \(taskId) not found")
        }

        guard task.state.canTransition(to: newState) else {
            JarvisLogger.actions.error("Invalid state transition for [\(taskId.uuidString.prefix(8))]: \(task.state.rawValue) -> \(newState.rawValue)")
            throw JarvisError.actionFailed(
                action: "TaskStateMachine.transition",
                reason: "Invalid transition from \(task.state.rawValue) to \(newState.rawValue)"
            )
        }

        let oldState = task.state
        task.state = newState
        task.updatedAt = Date()
        task.error = error

        if newState == .completed || newState == .cancelled {
            task.completedAt = Date()
        }

        tasks[taskId] = task
        stateHistory[taskId, default: []].append((newState, Date()))
        persistIfEnabledLocked()

        JarvisLogger.actions.info("Task [\(taskId.uuidString.prefix(8))] transitioned: \(oldState.rawValue) -> \(newState.rawValue)")
        return task
    }

    /// Explicitly resume only a failed/cancelled task with unresolved steps and remaining retry budget.
    /// CANCELLED remains terminal for every ordinary transition; this operation is the user-authorized path.
    @discardableResult
    func beginContinuation(taskId: UUID) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.beginContinuation", reason: "Task \(taskId) not found")
        }
        guard task.state == .failed || task.state == .cancelled else {
            throw JarvisError.invalidState(expected: "FAILED or CANCELLED", actual: task.state.rawValue)
        }
        guard task.retryCount < task.maxRetries else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.beginContinuation", reason: "Task retry limit exhausted")
        }
        guard TaskContinuity.firstIncompleteStepIndex(task: task) != nil else {
            throw JarvisError.invalidState(expected: "at least one unresolved task step", actual: "all steps resolved")
        }

        for index in task.steps.indices where TaskContinuity.independentlyVerified(task.steps[index], task: task)
            && task.steps[index].state != .completed {
            task.steps[index].state = .completed
            if task.steps[index].output == nil,
               let record = task.resolutionRecords.last(where: { $0.stepNumber == task.steps[index].stepNumber }) {
                task.steps[index].output = record.rawOutput
            }
        }
        task.retryCount += 1
        task.error = nil
        task.completedAt = nil
        for state in [TaskState.recovering, .replanning, .running] {
            task.state = state
            task.updatedAt = Date()
            stateHistory[taskId, default: []].append((state, task.updatedAt))
        }
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Starts a fresh attempt without carrying stale verification/error state forward.
    @discardableResult
    func beginStepAttempt(taskId: UUID, stepIndex: Int) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.beginStepAttempt", reason: "Task \(taskId) not found")
        }
        guard stepIndex >= 0 && stepIndex < task.steps.count else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.beginStepAttempt", reason: "Invalid step index \(stepIndex)")
        }

        task.steps[stepIndex].state = .running
        task.steps[stepIndex].output = nil
        task.steps[stepIndex].error = nil
        task.steps[stepIndex].verification = nil
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Record the verification outcome of a specific step (P1: verification
    /// result is explicit task state, not reconstructed from error text).
    @discardableResult
    func markStepVerification(taskId: UUID, stepIndex: Int, outcome: VerificationOutcome) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.markStepVerification", reason: "Task \(taskId) not found")
        }
        guard stepIndex >= 0 && stepIndex < task.steps.count else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.markStepVerification", reason: "Invalid step index \(stepIndex)")
        }

        task.steps[stepIndex].verification = outcome
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Record which step the task is currently positioned at (P1).
    /// Index is clamped to 0...steps.count so a replan-shortened plan stays valid.
    @discardableResult
    func setCurrentStepIndex(taskId: UUID, index: Int) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.setCurrentStepIndex", reason: "Task \(taskId) not found")
        }

        task.currentStepIndex = max(0, min(index, task.steps.count))
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Increment the task's retry/replan counter (P1).
    @discardableResult
    func incrementRetryCount(taskId: UUID) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.incrementRetryCount", reason: "Task \(taskId) not found")
        }

        task.retryCount += 1
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Update the status and output of a specific step.
    @discardableResult
    func updateStep(taskId: UUID, stepIndex: Int, state: TaskState, output: String? = nil, error: String? = nil) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.updateStep", reason: "Task \(taskId) not found")
        }

        guard stepIndex >= 0 && stepIndex < task.steps.count else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.updateStep", reason: "Invalid step index \(stepIndex)")
        }

        task.steps[stepIndex].state = state
        if let output = output {
            task.steps[stepIndex].output = output
        }
        if let error = error {
            task.steps[stepIndex].error = error
        }
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()

        return task
    }

    /// Update task steps (used during planning/replanning). Every snapshot is
    /// appended to the task's steps history (cycle 0 = initial plan) so replans
    /// preserve — never overwrite — earlier planning evidence.
    @discardableResult
    func setSteps(taskId: UUID, steps: [TaskStep]) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.setSteps", reason: "Task \(taskId) not found")
        }

        task.steps = steps
        task.updatedAt = Date()
        tasks[taskId] = task

        let cycle = stepsHistory[taskId]?.count ?? 0
        stepsHistory[taskId, default: []].append((cycle: cycle, steps: steps, at: Date()))
        persistIfEnabledLocked()

        return task
    }

    /// Retrieve state history for auditability.
    func getHistory(taskId: UUID) -> [(TaskState, Date)] {
        lock.lock()
        defer { lock.unlock() }
        return stateHistory[taskId] ?? []
    }

    /// Append a completed step resolution record to the task (P1 Reference Resolution).
    @discardableResult
    func appendResolutionRecord(_ record: StepResolutionRecord, for taskId: UUID) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.appendResolutionRecord", reason: "Task \(taskId) not found")
        }

        task.resolutionRecords.append(record)
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Retrieve step resolution records indexed by stepNumber for reference resolution.
    func resolutionRecords(for taskId: UUID) -> [Int: StepResolutionRecord] {
        lock.lock()
        defer { lock.unlock() }

        guard let task = tasks[taskId] else { return [:] }
        var map: [Int: StepResolutionRecord] = [:]
        for record in task.resolutionRecords {
            map[record.stepNumber] = record
        }
        return map
    }

    /// Set or update the ambient environment context snapshot for the task.
    @discardableResult
    func setEnvironmentContext(_ context: TaskEnvironmentContext, for taskId: UUID) throws -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[taskId] else {
            throw JarvisError.actionFailed(action: "TaskStateMachine.setEnvironmentContext", reason: "Task \(taskId) not found")
        }

        task.environmentContext = context
        task.updatedAt = Date()
        tasks[taskId] = task
        persistIfEnabledLocked()
        return task
    }

    /// Retrieve the environment context for the task.
    func environmentContext(for taskId: UUID) -> TaskEnvironmentContext? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskId]?.environmentContext
    }

    /// Record a failure and enter the recovery/replanning cycle.
    /// Encapsulates the real recovery transition chain used by AgentLoop:
    ///   RUNNING -> FAILED -> RECOVERING -> REPLANNING -> RUNNING
    @discardableResult
    func recordFailureAndRecover(taskId: UUID, error: String) throws -> JarvisTask {
        try transition(taskId: taskId, to: .failed, error: error)
        try transition(taskId: taskId, to: .recovering)
        try transition(taskId: taskId, to: .replanning)
        return try transition(taskId: taskId, to: .running)
    }
}
