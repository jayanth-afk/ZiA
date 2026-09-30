import Foundation

/// A read-only, bounded bridge from observed execution telemetry to recent
/// activity answers. TaskState supplies the task outcome; telemetry supplies
/// evidence that the task/action actually ran. This service never feeds
/// execution, permission, or reference resolution.
enum ActivityHistory {
    static func recentSummary(now: Date = .now) -> String {
        summary(
            tasks: TaskStateMachine.shared.allTasks,
            events: ExecutionTelemetry.shared.snapshot(),
            now: now)
    }

    /// Pure rendering seam for deterministic SelfTest coverage.
    static func summary(
        tasks: [JarvisTask],
        events: [ExecutionTelemetryEvent],
        now: Date = .now,
        window: TimeInterval = 15 * 60
    ) -> String {
        let cutoff = now.addingTimeInterval(-window)
        let grouped = Dictionary(grouping: events.filter { $0.timestamp >= cutoff }, by: \.taskID)
        let candidates = grouped.compactMap { id, taskEvents -> (UUID, [ExecutionTelemetryEvent], Date)? in
            // Conversational/direct-answer AgentLoop runs have a taskStarted /
            // taskCompleted envelope but no action and no TaskState. They are
            // not activity and must not answer later activity questions.
            let hasTaskState = tasks.contains { $0.id == id }
            let hasActionEvent = taskEvents.contains {
                $0.kind == .stepStarted || $0.kind == .stepCompleted || $0.kind == .stepFailed
            }
            guard hasTaskState || hasActionEvent else { return nil }
            let terminal = taskEvents.filter {
                $0.kind == .taskCompleted || $0.kind == .taskFailed || $0.kind == .stopped
            }.max { $0.timestamp < $1.timestamp }
            guard let terminal else { return nil }
            return (id, taskEvents, terminal.timestamp)
        }.sorted { $0.2 > $1.2 }

        guard let (taskID, taskEvents, _) = candidates.first else {
            return "I don't have a recent recorded action to report yet."
        }

        let task = tasks.first { $0.id == taskID }
        let terminalKind = taskEvents.last(where: {
            $0.kind == .taskCompleted || $0.kind == .taskFailed || $0.kind == .stopped
        })?.kind
        let actions = Array(Set(taskEvents.compactMap(\.action))).sorted()
        let actionSummary = actions.isEmpty ? nil : actions.joined(separator: ", ")
        let recoveryCount = taskEvents.filter { $0.kind == .recoveryAttempted }.count

        var response: String
        switch task?.state {
        case .completed:
            let goal = String((task?.goal ?? "").prefix(240))
            let verifiedCount = task?.steps.filter { $0.verification == .passed }.count ?? 0
            if !goal.isEmpty {
                response = "I completed “\(goal)”."
            } else {
                response = "I completed the recent action\(actionSummary.map { ": \($0)" } ?? "")."
            }
            if verifiedCount > 0 {
                response += " \(verifiedCount) step\(verifiedCount == 1 ? "" : "s") passed verification."
            }
        case .failed:
            let goal = String((task?.goal ?? "").prefix(240))
            response = goal.isEmpty
                ? "I couldn't complete the recent action\(actionSummary.map { ": \($0)" } ?? "")."
                : "I couldn't complete “\(goal)”."
        case .cancelled:
            response = "I stopped the recent task before it completed."
        default:
            // Deterministic AgentLoop actions have telemetry but no TaskState
            // object. Only report what their terminal event and action field say.
            switch terminalKind {
            case .taskCompleted:
                response = "I completed the recent action\(actionSummary.map { ": \($0)" } ?? "")."
            case .stopped:
                response = "I stopped the recent action before it completed."
            default:
                response = "The recent action failed\(actionSummary.map { ": \($0)" } ?? "")."
            }
        }
        if recoveryCount > 0 {
            response += " I attempted recovery \(recoveryCount) time\(recoveryCount == 1 ? "" : "s")."
        }
        return response
    }
}
