import Foundation

/// Enforces autonomy level permissions (L0-L3) before executing tool actions.
@MainActor
final class PermissionGate {
    static let shared = PermissionGate()

    enum AutonomyLevel: Int, Sendable, Comparable {
        case l0ReadOnly = 0    // Read-only inspection, no state changes
        case l1Supervised = 1  // Safe modifications permitted; destructive requires user confirmation
        case l2Autonomous = 2  // Autonomous execution of safe actions; log destructive actions
        case l3Full = 3        // Full execution of permitted actions

        static func < (lhs: AutonomyLevel, rhs: AutonomyLevel) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    enum ActionImpact: Sendable {
        case readOnly     // Requires L0
        case safeMutation // Requires L1
        case destructive  // Requires L2 or confirmation
    }

    private init() {}

    // MARK: - Public API

    /// Current system autonomy level from configuration.
    var currentLevel: AutonomyLevel {
        let levelInt = Config.shared.autonomyLevel
        return AutonomyLevel(rawValue: levelInt) ?? .l1Supervised
    }

    /// Check if an action of given impact is authorized to run.
    func isAuthorized(actionName: String, impact: ActionImpact) throws -> Bool {
        let required: AutonomyLevel
        switch impact {
        case .readOnly:
            required = .l0ReadOnly
        case .safeMutation:
            required = .l1Supervised
        case .destructive:
            required = .l2Autonomous
        }

        guard currentLevel >= required else {
            JarvisLogger.security.warning("Permission denied for '\(actionName)': requires L\(required.rawValue), current is L\(currentLevel.rawValue)")
            throw JarvisError.permissionDenied(action: actionName, requiredLevel: required.rawValue, currentLevel: currentLevel.rawValue)
        }

        return true
    }
}
