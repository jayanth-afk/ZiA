import Foundation

/// Executes tools with permission checks, observation, and verification.
/// Adheres strictly to Rule 7: execute -> observe -> verify (Evidence Before Green).
@MainActor
final class ToolExecutor {
    static let shared = ToolExecutor()

    /// Registry used for tool resolution. The shared instance resolves
    /// `ToolRegistry.shared` at execution time; dependency-injected instances
    /// (deterministic tests, isolated contexts) use the provided registry.
    private let injectedRegistry: ToolRegistry?

    private init() {
        self.injectedRegistry = nil
    }

    /// Dependency-injected executor. `nonisolated` so deterministic test
    /// harnesses can construct it off the main actor (a ToolRegistry reference
    /// is an immutable, Sendable global-actor-isolated object).
    nonisolated init(registry: ToolRegistry) {
        self.injectedRegistry = registry
    }

    // MARK: - Public API

    /// Execute a tool by name with full observation and verification.
    func execute(toolName: String, arguments: [String: any Sendable]) async throws -> ToolResult {
        try await execute(toolName: toolName, arguments: arguments, environmentContext: nil)
    }

    /// Full lifecycle with optional task environment context. The context is
    /// the integration seam for context-aware verification (ambient state
    /// carried with the execution); current verifiers are stateless and do
    /// not require it.
    func execute(
        toolName: String,
        arguments: [String: any Sendable],
        environmentContext: TaskEnvironmentContext?
    ) async throws -> ToolResult {
        let registry = injectedRegistry ?? ToolRegistry.shared
        guard let tool = registry.getTool(named: toolName) else {
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
            JarvisLogger.actions.error("Verification for tool '\(toolName)' ended [\(verification.outcome.rawValue)]: \(reasonStr)")
            // Contract: the thrown error carries verification.outcome.rawValue
            // in the 'expected' slot so callers can distinguish .failed from
            // .inconclusive/.unavailable — an inconclusive or unavailable
            // verification is NEVER a success (Evidence Before Green).
            throw JarvisError.verificationFailed(
                action: toolName,
                expected: verification.outcome.rawValue,
                actual: "\(reasonStr) (expected: \(verification.expectedState ?? "n/a"), observed: \(verification.observedState ?? "n/a"))"
            )
        }

        let elapsed = timer.elapsed(from: .actionStart, to: .actionVerified) ?? 0
        JarvisLogger.actions.info("Tool '\(toolName)' executed and verified [\(verification.outcome.rawValue)] in \(String(format: "%.1f", elapsed))ms")

        return expected
    }
}
