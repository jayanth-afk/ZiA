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

    init(
        id: UUID = UUID(),
        stepNumber: Int,
        description: String,
        toolName: String? = nil,
        arguments: [String: String] = [:],
        state: TaskState = .created,
        output: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.stepNumber = stepNumber
        self.description = description
        self.toolName = toolName
        self.arguments = arguments
        self.state = state
        self.output = output
        self.error = error
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
        error: String? = nil
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

    private init() {}

    // MARK: - Task Management

    /// Create and register a new task.
    @discardableResult
    func createTask(title: String, goal: String, steps: [TaskStep] = []) -> JarvisTask {
        lock.lock()
        defer { lock.unlock() }

        let task = JarvisTask(title: title, goal: goal, steps: steps)
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

    /// Update task steps (used during planning/replanning).
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

        return task
    }

    /// Retrieve state history for auditability.
    func getHistory(taskId: UUID) -> [(TaskState, Date)] {
        lock.lock()
        defer { lock.unlock() }
        return stateHistory[taskId] ?? []
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
