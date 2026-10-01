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

    public init() {}

    private func setRunningState(running: Bool, taskId: String?) {
        lock.withLock {
            self.isRunningState = running
            self.currentTaskIdState = taskId
        }
    }

    public func processUserQuery(_ query: String) async -> AgentLoopResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let taskId = UUID().uuidString

        setRunningState(running: true, taskId: taskId)

        defer {
            setRunningState(running: false, taskId: nil)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return AgentLoopResult(
                taskId: taskId,
                status: "failed",
                response: "Query cannot be empty.",
                executionTimeMs: elapsed
            )
        }

        // Fast Path 1: Direct Answer Router
        if let directAnswer = DirectAnswerRouter.shared.evaluateDirectAnswer(trimmedQuery) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let eventPayload: [String: String] = ["type": "taskCompleted", "taskId": taskId, "path": "directAnswer"]
            EventBus.shared.publish(eventPayload)
            return AgentLoopResult(
                taskId: taskId,
                status: "success",
                response: directAnswer,
                executionTimeMs: elapsed
            )
        }

        // Fast Path 2: Deterministic Action Router
        if let routeResult = DeterministicRouter.shared.route(trimmedQuery) {
            if let tool = ToolRegistry.shared.tool(named: routeResult.actionName) {
                do {
                    let toolOutput = try await tool.execute(parameters: routeResult.parameters)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    let eventPayload: [String: String] = ["type": "taskCompleted", "taskId": taskId, "path": "deterministicRoute"]
                    EventBus.shared.publish(eventPayload)
                    return AgentLoopResult(
                        taskId: taskId,
                        status: "success",
                        response: toolOutput,
                        executionTimeMs: elapsed
                    )
                } catch {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    return AgentLoopResult(
                        taskId: taskId,
                        status: "failed",
                        response: "Action execution failed: \(error.localizedDescription)",
                        executionTimeMs: elapsed
                    )
                }
            }
        }

        // Fallback / Intent Classification
        let intent = IntentClassifier.shared.classify(trimmedQuery)
        var responseText = "Processed query with intent: \(intent.type.rawValue) (Confidence: \(intent.confidence))"

        if !intent.extractedEntities.isEmpty {
            responseText += "\nEntities: \(intent.extractedEntities)"
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let eventPayload: [String: String] = ["type": "taskCompleted", "taskId": taskId, "path": "intentFallback"]
        EventBus.shared.publish(eventPayload)

        return AgentLoopResult(
            taskId: taskId,
            status: "success",
            response: responseText,
            executionTimeMs: elapsed
        )
    }

    public func cancelCurrentTask() {
        let activeTaskId: String? = lock.withLock {
            let taskId = currentTaskIdState
            self.isRunningState = false
            self.currentTaskIdState = nil
            return taskId
        }

        if let taskId = activeTaskId {
            let eventPayload: [String: String] = ["type": "taskCancelled", "taskId": taskId]
            EventBus.shared.publish(eventPayload)
        }
    }

    public var status: AgentStatus {
        lock.withLock {
            AgentStatus(isRunning: isRunningState, taskId: currentTaskIdState)
        }
    }
}