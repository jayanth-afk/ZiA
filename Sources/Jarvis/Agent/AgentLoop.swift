import Foundation

public struct AgentStatus: Sendable {
    public let isRunning: Bool
    public let taskId: String?

    public init(isRunning: Bool, taskId: String?) {
        self.isRunning = isRunning
        self.taskId = taskId
    }
}

public struct AgentLoopResult: Sendable {
    public let taskId: String
    public let status: String
    public let response: String
    public let executionTimeMs: Double

    public init(taskId: String, status: String, response: String, executionTimeMs: Double) {
        self.taskId = taskId
        self.status = status
        self.response = response
        self.executionTimeMs = executionTimeMs
    }
}

public final class AgentLoop: @unchecked Sendable {
    public static let shared = AgentLoop()

    private let lock = NSLock()
    private var isRunningState: Bool = false
    private var currentTaskIdState: String? = nil
    private var emergencyCancellationRequested = false
    private var runGeneration = 0

    public init() {}

    nonisolated static func partialCompletionReport(
        completedStepCount: Int,
        lastFailure: (stepNumber: Int, purpose: String, tool: String?, error: String)?
    ) -> String {
        let stepWord = completedStepCount == 1 ? "step" : "steps"
        let completed = "Partial completion: \(completedStepCount) \(stepWord) completed and verified before failure"
        let failure = lastFailure.map { "; Step \($0.stepNumber) ('\($0.purpose)') failed: \($0.error)" }
            ?? "; Task incomplete: no step failure recorded"
        return completed + failure
    }

    public func processUserQuery(_ query: String) async -> AgentLoopResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let taskId = UUID().uuidString

        let generation = lock.withLock { () -> Int in
            runGeneration += 1
            emergencyCancellationRequested = false
            isRunningState = true
            currentTaskIdState = taskId
            return runGeneration
        }

        defer {
            lock.withLock {
                if runGeneration == generation {
                    isRunningState = false
                    currentTaskIdState = nil
                    emergencyCancellationRequested = false
                }
            }
        }

        do {
            let response = try await run(goal: query)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let eventPayload: [String: String] = ["type": "taskCompleted", "taskId": taskId,
                                                   "path": (await latestRoute())?.rawValue ?? "unknown"]
            EventBus.shared.publish(eventPayload)
            return AgentLoopResult(taskId: taskId, status: "success", response: response, executionTimeMs: elapsed)
        } catch is CancellationError {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return AgentLoopResult(taskId: taskId, status: "cancelled",
                                   response: "Action cancelled by emergency stop.", executionTimeMs: elapsed)
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return AgentLoopResult(taskId: taskId, status: "failed",
                                   response: error.localizedDescription, executionTimeMs: elapsed)
        }
    }

    func run(goal: String) async throws -> String {
        try await TaskExecutionCoordinator.shared.run(goal: goal)
    }

    func runUsingTaskStateMachineForTesting(goal: String, stateMachine: TaskStateMachine) async throws -> String {
        try await TaskExecutionCoordinator.shared.run(goal: goal, stateMachine: stateMachine)
    }

    func runUsingFixedPlanForTesting(goal: String, plan: AgentPlan) async throws -> String {
        try await TaskExecutionCoordinator.shared.run(goal: goal, fixedPlan: plan, stopRecoveryAfterAttempt: true)
    }

    func latestRoute() async -> PipelineRoute? { await TaskExecutionCoordinator.shared.latestRoute() }
    func latestReplanCount() async -> Int { await TaskExecutionCoordinator.shared.latestReplanCount() }
    func latestPlannerMetrics() async -> MLXPlanner.PlannerMetrics? { await TaskExecutionCoordinator.shared.latestPlannerMetrics() }

    @MainActor static func classifyRouteSync(for goal: String) -> PipelineRoute {
        if DeterministicRouter.shared.match(goal) != nil { return .deterministic }
        switch DirectAnswerRouter.decide(goal: goal) {
        case .directAnswer, .activitySummary, .verifiedArtifactSummary, .verifiedArtifactStatus,
             .taskContinuity, .informationAnswer: return .directAnswer
        case .refusal: return .refusal
        case .planner: return .planner
        }
    }

    static func classifyRoute(for goal: String) async -> PipelineRoute {
        await MainActor.run { classifyRouteSync(for: goal) }
    }

    public func cancelCurrentTask() {
        let activeTaskId: String? = lock.withLock {
            let taskId = currentTaskIdState
            emergencyCancellationRequested = true
            self.isRunningState = false
            self.currentTaskIdState = nil
            return taskId
        }

        if let taskId = activeTaskId {
            let eventPayload: [String: String] = ["type": "taskCancelled", "taskId": taskId]
            EventBus.shared.publish(eventPayload)
        }
    }

    public func emergencyCancel() {
        lock.withLock { emergencyCancellationRequested = true }
        JarvisLogger.security.fault("AgentLoop emergency cancellation requested")
    }

    public var isEmergencyCancelled: Bool {
        lock.withLock { emergencyCancellationRequested }
    }

    public func resetEmergencyCancellation() {
        lock.withLock { emergencyCancellationRequested = false }
    }

    public var status: AgentStatus {
        lock.withLock {
            AgentStatus(isRunning: isRunningState, taskId: currentTaskIdState)
        }
    }
}