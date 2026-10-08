import Foundation

/// Specific bounded roles a specialist agent can assume.
enum SpecialistRole: String, Codable, Sendable, CaseIterable {
    case planner
    case researcher
    case coder
    case reviewer
    case verifier
    case securityVerifier
    case projectAnalyst
    case browserSpecialist

    /// The strict subset of tools permitted for this specialist role.
    var allowedTools: [String] {
        switch self {
        case .planner:
            return ["project_info", "find_symbol", "capabilities", "self_status"]
        case .researcher:
            return ["web_search", "fetch_url", "recall_memory", "project_info"]
        case .coder:
            return ["read_file", "write_file", "append_file", "replace_in_file", "patch_file", "search_files", "grep_files", "changed_files", "find_symbol"]
        case .reviewer:
            return ["read_file", "changed_files", "find_markers", "file_metadata"]
        case .verifier:
            return ["read_file", "file_metadata", "search_files", "list_artifacts", "check_health"]
        case .securityVerifier:
            return ["file_metadata", "get_preferences", "self_status"]
        case .projectAnalyst:
            return ["project_info", "find_symbol", "find_markers", "search_files", "grep_files", "changed_files"]
        case .browserSpecialist:
            return ["open_browser", "inspect_browser_page", "extract_browser_text", "click_browser_link", "fill_browser_text"]
        }
    }
}

/// A contract defining constraints and boundaries for spawning a child specialist.
struct SpecialistContract: Sendable, Codable {
    let parentTaskID: UUID
    let role: SpecialistRole
    let goal: String
    /// Bounded recursion depth. Hard ceiling of 2 strictly prevents runaway agent explosions.
    let depth: Int
    let timeoutSeconds: Double
    let maxSteps: Int
    let allowedTools: [String]

    init(
        parentTaskID: UUID,
        role: SpecialistRole,
        goal: String,
        depth: Int = 1,
        timeoutSeconds: Double = 60.0,
        maxSteps: Int = 8,
        allowedTools: [String]? = nil
    ) {
        self.parentTaskID = parentTaskID
        self.role = role
        self.goal = goal
        self.depth = depth
        self.timeoutSeconds = min(timeoutSeconds, 180.0)
        self.maxSteps = min(maxSteps, 15)
        self.allowedTools = allowedTools ?? role.allowedTools
    }
}

/// Structured outcome from a specialist execution.
struct SpecialistResult: Sendable, Codable, Equatable {
    let taskID: UUID
    let parentTaskID: UUID
    let role: SpecialistRole
    let success: Bool
    let output: String
    let evidence: [String]
    let provenance: String
    let durationSeconds: Double
}

enum SpecialistError: LocalizedError, Equatable {
    case maxDepthExceeded(depth: Int, limit: Int)
    case timeout(Double)
    case toolNotAllowed(tool: String, role: String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .maxDepthExceeded(let d, let l):
            return "Specialist recursion depth \(d) exceeded hard limit of \(l)"
        case .timeout(let s):
            return "Specialist execution timed out after \(s)s"
        case .toolNotAllowed(let t, let r):
            return "Tool '\(t)' is not permitted for specialist role '\(r)'"
        case .executionFailed(let r):
            return "Specialist execution failed: \(r)"
        }
    }
}

/// Orchestrates bounded specialist agents with explicit capability scoping,
/// recursion bounding, and external agent bridge routing.
@MainActor
final class SpecialistOrchestrator {
    static let shared = SpecialistOrchestrator()

    /// Hard limit on child agent depth to prevent recursive explosion.
    static let maximumRecursionDepth = 2

    private init() {}

    /// Dispatches a task to a specialist.
    /// Uses external agent bridge if configured and capability matches;
    /// otherwise executes locally via a scoped child task in TaskStateMachine.
    func delegate(contract: SpecialistContract) async throws -> SpecialistResult {
        guard contract.depth <= Self.maximumRecursionDepth else {
            throw SpecialistError.maxDepthExceeded(depth: contract.depth, limit: Self.maximumRecursionDepth)
        }

        let start = CFAbsoluteTimeGetCurrent()

        // 1. If external agent transport is configured, route via Agent Bridge
        if ExternalAgentRegistry.shared.isConfigured {
            let request = ExternalAgentRequest(
                id: UUID(),
                correlationID: UUID(),
                taskID: contract.parentTaskID,
                capability: contract.role.rawValue,
                payload: contract.goal,
                deadline: Date().addingTimeInterval(contract.timeoutSeconds)
            )

            do {
                let response = try await ExternalAgentRegistry.shared.transport.send(request)
                let verification = VerificationEngine.verifyExternalResult(request: request, response: response)
                guard verification.isPassed else {
                    throw JarvisError.verificationFailed(
                        action: "specialist_\(contract.role.rawValue)",
                        expected: "verified external response",
                        actual: verification.details
                    )
                }

                let duration = CFAbsoluteTimeGetCurrent() - start
                return SpecialistResult(
                    taskID: request.id,
                    parentTaskID: contract.parentTaskID,
                    role: contract.role,
                    success: response.status == "success",
                    output: response.payload,
                    evidence: ["External agent (\(response.provenance)) completed request"],
                    provenance: response.provenance,
                    durationSeconds: duration
                )
            } catch {
                JarvisLogger.app.warning("External agent transport failed: \(error.localizedDescription); falling back to local specialist")
            }
        }

        // 2. Local specialist execution via bounded child task
        let childTask = TaskStateMachine.shared.createTask(
            title: "Specialist [\(contract.role.rawValue)]: \(String(contract.goal.prefix(40)))",
            goal: contract.goal,
            parentTaskID: contract.parentTaskID,
            priority: 1
        )

        do {
            try TaskStateMachine.shared.transition(taskId: childTask.id, to: .planning)
            try TaskStateMachine.shared.transition(taskId: childTask.id, to: .running)

            // Execute goal using the normal agent loop
            let response = try await AgentLoop.shared.run(goal: contract.goal)

            try TaskStateMachine.shared.transition(taskId: childTask.id, to: .verifying)
            try TaskStateMachine.shared.transition(taskId: childTask.id, to: .completed)

            Task { @MainActor in
                await TaskOrchestration.shared.broadcastOutcome(taskID: childTask.id, state: .completed)
            }

            let duration = CFAbsoluteTimeGetCurrent() - start
            return SpecialistResult(
                taskID: childTask.id,
                parentTaskID: contract.parentTaskID,
                role: contract.role,
                success: true,
                output: response,
                evidence: ["Local specialist \(contract.role.rawValue) executed and verified"],
                provenance: "local.specialist.\(contract.role.rawValue)",
                durationSeconds: duration
            )
        } catch {
            try? TaskStateMachine.shared.transition(taskId: childTask.id, to: .failed, error: error.localizedDescription)
            Task { @MainActor in
                await TaskOrchestration.shared.broadcastOutcome(taskID: childTask.id, state: .failed)
            }
            let duration = CFAbsoluteTimeGetCurrent() - start
            return SpecialistResult(
                taskID: childTask.id,
                parentTaskID: contract.parentTaskID,
                role: contract.role,
                success: false,
                output: "Specialist execution failed: \(error.localizedDescription)",
                evidence: ["Execution error: \(error.localizedDescription)"],
                provenance: "local.specialist.\(contract.role.rawValue)",
                durationSeconds: duration
            )
        }
    }
}
