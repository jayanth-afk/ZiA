import Foundation

/// What Zia should do about an interrupted or failed task found in durable
/// state (for example after a crash/restart).
enum InterruptedTaskDisposition: String, Sendable, Equatable {
    /// The remaining work is provably safe to replay (no uncertain destructive
    /// side effect); resume from the first unresolved step.
    case safeToResume
    /// The last action may have committed and cannot be assumed; verify before
    /// continuing.
    case needsVerification
    /// A destructive/unknown action may have committed; ask the user.
    case requiresConfirmation
}

/// A per-task recovery plan derived ONLY from authoritative durable state.
struct InterruptedTaskPlan: Sendable, Equatable {
    let taskID: UUID
    let goal: String
    let state: String
    let verifiedSteps: Int
    let totalSteps: Int
    let remainingSteps: Int
    let disposition: InterruptedTaskDisposition
    /// Tools whose side effect may have committed and therefore must not be
    /// blindly repeated.
    let uncertainTools: [String]
    let reason: String

    var summary: String {
        "\(String(goal.prefix(80))) [\(state)] — \(disposition.rawValue): \(reason)"
    }
}

struct CrashRecoveryReport: Sendable, Equatable {
    let plans: [InterruptedTaskPlan]
    let inspectedAt: Date

    var resumable: [InterruptedTaskPlan] {
        plans.filter { $0.disposition == .safeToResume }
    }

    var needsAttention: [InterruptedTaskPlan] {
        plans.filter { $0.disposition != .safeToResume }
    }

    var summary: String {
        guard !plans.isEmpty else { return "No interrupted work found in durable state." }
        var lines = ["Interrupted work (\(plans.count) task(s)):"]
        for plan in plans {
            lines.append("• \(plan.summary)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Deterministic, evidence-based crash recovery. It never blindly re-runs a
/// task: it classifies the remaining work and can only auto-resume work whose
/// remaining steps are provably safe to replay.
enum CrashRecovery {
    /// Only tasks not updated within this window are treated as genuinely
    /// interrupted rather than possibly still running in-process.
    static let staleThreshold: TimeInterval = 120

    static func inspect(tasks: [JarvisTask], now: Date = .now) -> CrashRecoveryReport {
        var plans: [InterruptedTaskPlan] = []
        for task in tasks {
            if let plan = plan(for: task, now: now) {
                plans.append(plan)
            }
        }
        plans.sort { $0.taskID.uuidString < $1.taskID.uuidString }
        return CrashRecoveryReport(plans: plans, inspectedAt: now)
    }

    static func isSafeToResume(_ plan: InterruptedTaskPlan) -> Bool {
        plan.disposition == .safeToResume
    }

    // MARK: - Internals

    private static func plan(for task: JarvisTask, now: Date) -> InterruptedTaskPlan? {
        switch task.state {
        case .completed, .cancelled:
            return nil
        case .created, .planning, .running, .verifying, .recovering, .replanning, .failed:
            break
        }

        let verified = task.steps.filter { TaskContinuity.isResolved($0, task: task) }.count
        let unresolved = task.steps.filter { !TaskContinuity.isResolved($0, task: task) }
        guard !unresolved.isEmpty || task.state == .failed else { return nil }

        // Which unresolved tool steps could have committed a destructive or
        // unknown side effect, and therefore must not be blindly repeated.
        var uncertain: [String] = []
        for step in unresolved {
            guard let tool = step.toolName else { continue }
            let impact = ToolRegistry.shared.getTool(named: tool)?.impact
            if impact == nil || impact == .destructive || step.state == .running {
                uncertain.append(tool)
            }
        }
        uncertain = Array(Set(uncertain)).sorted()

        let age = now.timeIntervalSince(task.updatedAt)
        let isFresh = age >= 0 && age < staleThreshold

        let disposition: InterruptedTaskDisposition
        let reason: String
        switch task.state {
        case .created, .planning:
            disposition = .safeToResume
            reason = "no step had begun; safe to start from the first step"
        case .failed:
            disposition = .requiresConfirmation
            reason = "task previously failed; needs your decision before retrying"
        case .running, .recovering, .replanning, .verifying:
            if isFresh {
                disposition = .needsVerification
                reason = "recently updated; verify it is not still active before resuming"
            } else if !uncertain.isEmpty {
                disposition = .requiresConfirmation
                reason = "uncertain side effect from \(uncertain.joined(separator: ", ")) may have committed"
            } else {
                disposition = .safeToResume
                reason = "remaining steps are read-only or low-impact; safe to replay"
            }
        case .completed, .cancelled:
            return nil
        }

        return InterruptedTaskPlan(
            taskID: task.id,
            goal: task.goal,
            state: task.state.rawValue,
            verifiedSteps: verified,
            totalSteps: task.steps.count,
            remainingSteps: unresolved.count,
            disposition: disposition,
            uncertainTools: uncertain,
            reason: reason)
    }
}
