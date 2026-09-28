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

    private init() {}

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
        title: String,
        goal: String,
        steps: [TaskStep] = [],
        environmentContext: TaskEnvironmentContext? = nil
    ) -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        let task = JarvisTask(title: title, goal: goal, steps: steps, environmentContext: environmentContext)
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

        JarvisLogger.actions.info("Task [\(taskId.uuidString.prefix(8))] transitioned: \(oldState.rawValue) -> \(newState.rawValue)")
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
