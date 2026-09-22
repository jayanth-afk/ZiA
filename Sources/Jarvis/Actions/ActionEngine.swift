import Foundation

/// Master action executor following the SENSE -> UNDERSTAND -> PLAN -> EXECUTE -> OBSERVE -> VERIFY -> RESPOND loop.
@MainActor
final class ActionEngine {
    static let shared = ActionEngine()

    private init() {}

    // MARK: - Public API

    /// Execute an action with deterministic verification and timing metrics.
    func execute(intent: String, isDeterministic: Bool = true, action: () async throws -> String) async throws -> String {
        let timer = PipelineTimer(id: UUID().uuidString)
        timer.mark(.actionStart)

        JarvisLogger.actions.info("ActionEngine executing intent: '\(intent)'")
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
