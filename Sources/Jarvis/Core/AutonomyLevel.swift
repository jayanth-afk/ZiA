import Foundation

/// Explicit autonomy model for Zia.
///
/// This is the capability contract that sits ABOVE the per-action
/// `PermissionGate` check. It answers two questions the per-action gate cannot:
///
///  1. How much may Zia decide to do *on its own* (background work, multi-step
///     execution) without the user in the loop?
///  2. Which higher-level behaviors (background workflows, self-improvement)
///     are permitted at all?
///
/// Every higher level inherits every lower level's safety gate. Raising the
/// level never removes authority checks: an action still passes through
/// PermissionGate, CommandSandbox, ProcessAuthority, PlanValidator, and the
/// destructive-action commit gate. Autonomy is built ABOVE authority.
enum AutonomyLevel: Int, CaseIterable, Sendable, Comparable {
    /// Conversational only: answer questions; take no actions.
    case conversational = 0
    /// Suggest: propose actions/plans but do not execute them.
    case suggest = 1
    /// Execute safe actions: read-only + safe mutations; destructive requires confirmation.
    case executeSafe = 2
    /// Autonomous multi-step work: chain verified steps toward a stated goal.
    case autonomousMultiStep = 3
    /// Background workflows: run scheduled, queued, and resumed tasks without the user present.
    case backgroundWorkflows = 4
    /// Controlled self-improvement: propose isolated changes for review (never auto-install).
    case controlledSelfImprovement = 5

    static func < (lhs: AutonomyLevel, rhs: AutonomyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .conversational: return "L0: Conversational"
        case .suggest: return "L1: Suggest"
        case .executeSafe: return "L2: Execute Safe Actions"
        case .autonomousMultiStep: return "L3: Autonomous Multi-Step"
        case .backgroundWorkflows: return "L4: Background Workflows"
        case .controlledSelfImprovement: return "L5: Controlled Self-Improvement"
        }
    }

    var summary: String {
        switch self {
        case .conversational:
            return "Answer questions and converse. Take no actions."
        case .suggest:
            return "Propose plans and actions without executing them."
        case .executeSafe:
            return "Execute read-only and safe actions; destructive actions require confirmation."
        case .autonomousMultiStep:
            return "Chain verified steps toward a goal without step-by-step supervision."
        case .backgroundWorkflows:
            return "Run scheduled, queued, and resumed tasks while the user is away."
        case .controlledSelfImprovement:
            return "Propose isolated improvements for review; never install them automatically."
        }
    }

    /// Whether Zia may start work that continues while the user is away.
    var permitsBackgroundExecution: Bool { self >= .backgroundWorkflows }

    /// Whether Zia may propose self-modifications. Proposals still require the
    /// full validation/review pipeline and are never auto-installed.
    var permitsSelfImprovementProposals: Bool { self >= .controlledSelfImprovement }

    /// Whether Zia may execute an action of a given impact directly. Destructive
    /// actions at or below `.executeSafe` always route through the destructive
    /// commit gate; this only states whether the level is high enough to try.
    func permitsExecution(of impact: PermissionGate.ActionImpact) -> Bool {
        switch impact {
        case .readOnly:
            return self >= .executeSafe
        case .safeMutation:
            return self >= .executeSafe
        case .destructive:
            return self >= .autonomousMultiStep
        }
    }
}

/// The current, configured autonomy policy. Derived from `Config.autonomyLevel`
/// so there is exactly one source of truth. Legacy per-action levels (0-3) map
/// onto the lower half of this model; 4 and 5 are explicit opt-ins.
@MainActor
enum AutonomyPolicy {
    static var current: AutonomyLevel {
        let raw = min(max(Config.shared.autonomyLevel, 0), AutonomyLevel.allCases.count - 1)
        return AutonomyLevel(rawValue: raw) ?? .suggest
    }

    static func allows(_ level: AutonomyLevel) -> Bool {
        current >= level
    }

    static var backgroundExecutionEnabled: Bool {
        current.permitsBackgroundExecution
    }
}
