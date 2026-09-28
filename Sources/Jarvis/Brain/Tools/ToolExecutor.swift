import Foundation

/// Executes tools with permission checks, observation, and verification.
/// Adheres strictly to Rule 7: execute -> observe -> verify.
@MainActor
final class ToolExecutor {
    static let shared = ToolExecutor()

    private init() {}

    // MARK: - Public API

    /// Execute a tool by name with full observation and verification.
    func execute(toolName: String, arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let tool = ToolRegistry.shared.getTool(named: toolName) else {
            throw JarvisError.actionFailed(action: toolName, reason: "Tool '\(toolName)' is not registered")
        }

        // 1. Permission check
        _ = try PermissionGate.shared.isAuthorized(actionName: tool.name, impact: tool.impact)

        let timer = PipelineTimer()
        timer.mark(.actionStart)

        // 2. Execute
        var expected = try await tool.execute(arguments: arguments)
        timer.mark(.actionExecuted)

        // 3. Observe
        let observed = try await tool.observe()
        timer.mark(.actionObserved)

        // 4. Verify
        let verification = tool.verifyDetailed(expected: expected, observed: observed)
        expected.verification = verification
        timer.mark(.actionVerified)

        guard verification.isSuccess else {
            let reasonStr = verification.reason ?? observed.observations.description
            JarvisLogger.actions.error("Verification failed for tool '\(toolName)': [\(verification.outcome.rawValue)] \(reasonStr)")
            throw JarvisError.verificationFailed(
                action: toolName,
                expected: verification.expectedState ?? expected.output,
                actual: verification.observedState ?? "[\(verification.outcome.rawValue)] \(reasonStr)"
            )
        }

        let elapsed = timer.elapsed(from: .actionStart, to: .actionVerified) ?? 0
        JarvisLogger.actions.info("Tool '\(toolName)' executed and verified [\(verification.outcome.rawValue)] in \(String(format: "%.1f", elapsed))ms")

        return expected
    }
}
