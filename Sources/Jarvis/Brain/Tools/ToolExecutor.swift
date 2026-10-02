import Foundation

struct ToolVerificationFailure: LocalizedError, Sendable {
    let action: String
    let outcome: VerificationOutcome
    let expected: String
    let observed: String

    var errorDescription: String? {
        "Verification failed for \(action): expected \(expected), got [\(outcome.rawValue)] \(observed)"
    }
}

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

        // 1. Validate the concrete execution arguments at the final tool choke point.
        // Callers normally arrive here through PlanValidator/ReferenceResolver, but
        // ToolExecutor is also a public internal boundary. Never trust an upstream
        // planner, continuation, or direct caller to have performed schema checks.
        try validateArguments(arguments, against: tool)

        // 2. Permission check
        _ = try PermissionGate.shared.isAuthorized(actionName: tool.name, impact: tool.impact)

        let timer = PipelineTimer()
        timer.mark(.actionStart)

        // 2. Execute
        var expected = try await tool.execute(arguments: arguments)
        timer.mark(.actionExecuted)

        // 3. Observe
        let observed = try await tool.observe(expected: expected)
        timer.mark(.actionObserved)

        // 4. Verify
        let verification = tool.verifyDetailed(expected: expected, observed: observed)
        expected.verification = verification
        timer.mark(.actionVerified)

        guard verification.isSuccess else {
            let reasonStr = verification.reason ?? observed.observations.description
            JarvisLogger.actions.error("Verification failed for tool '\(toolName)': [\(verification.outcome.rawValue)] \(reasonStr)")
            throw ToolVerificationFailure(
                action: toolName,
                outcome: verification.outcome,
                expected: verification.expectedState ?? expected.output,
                observed: verification.observedState ?? reasonStr)
        }

        let elapsed = timer.elapsed(from: .actionStart, to: .actionVerified) ?? 0
        JarvisLogger.actions.info("Tool '\(toolName)' executed and verified [\(verification.outcome.rawValue)] in \(String(format: "%.1f", elapsed))ms")

        return expected
    }

    private func validateArguments(_ arguments: [String: any Sendable], against tool: any JarvisTool) throws {
        let specs = Dictionary(uniqueKeysWithValues: tool.parameterSpec.map { ($0.name, $0) })

        for (name, value) in arguments {
            guard let spec = specs[name] else {
                throw JarvisError.actionFailed(
                    action: tool.name,
                    reason: "Unknown argument '\(name)' rejected at execution boundary")
            }

            switch spec.kind {
            case .string:
                guard value is String else {
                    throw JarvisError.actionFailed(
                        action: tool.name,
                        reason: "Argument '\(name)' must be a string")
                }
            case .int:
                guard value is Int else {
                    throw JarvisError.actionFailed(
                        action: tool.name,
                        reason: "Argument '\(name)' must be an integer")
                }
            }
        }

        for spec in tool.parameterSpec where spec.required {
            guard arguments[spec.name] != nil else {
                throw JarvisError.actionFailed(
                    action: tool.name,
                    reason: "Missing required argument '\(spec.name)' at execution boundary")
            }
        }
    }
}
