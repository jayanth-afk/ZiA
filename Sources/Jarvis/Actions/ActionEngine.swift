import Foundation

/// Master action executor following the SENSE -> UNDERSTAND -> PLAN -> EXECUTE -> OBSERVE -> VERIFY -> RESPOND loop.
@MainActor
final class ActionEngine {
    static let shared = ActionEngine()

    private init() {}

    // MARK: - Public API

    /// Execute an action with deterministic verification and timing metrics.
    ///
    /// P0 invariant enforcement: every action that reaches ActionEngine passes
    /// the PermissionGate here. This is the single choke point for BOTH callers
    /// (AgentLoop deterministic fast path and BrainRouter), so deterministic
    /// actions can never bypass the same authority policy that governs planned
    /// tool execution through ToolExecutor. The impact is declared by the
    /// router match — never inferred from the transcript's data sensitivity.
    func execute(
        intent: String,
        isDeterministic: Bool = true,
        impact: PermissionGate.ActionImpact = .readOnly,
        action: () async throws -> String
    ) async throws -> String {
        let timer = PipelineTimer(id: UUID().uuidString)
        timer.mark(.actionStart)

        // Permission check BEFORE any effect: mirrors ToolExecutor's per-tool
        // gate. Throws JarvisError.permissionDenied on insufficient autonomy.
        _ = try PermissionGate.shared.isAuthorized(actionName: intent, impact: impact)

        JarvisLogger.actions.info("ActionEngine executing intent: '\(intent)' (impact: \(String(describing: impact)))")
        EventBus.shared.publish(IntentDetectedEvent(intent: intent, confidence: 1.0, isDeterministic: isDeterministic))

        do {
            let result = try await action()
            timer.mark(.actionExecuted)

            let duration = timer.elapsed(from: .actionStart, to: .actionExecuted) ?? 0
            JarvisLogger.actions.info("ActionEngine completed '\(intent)' in \(String(format: "%.1f", duration))ms: '\(result)'")

            return result
        } catch {
            timer.mark(.actionExecuted)
            JarvisLogger.actions.error("ActionEngine failed '\(intent)': \(error.localizedDescription)")
            throw error
        }
    }
}
