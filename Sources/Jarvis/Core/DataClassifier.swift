import Foundation

/// Classifies data sensitivity to enforce privacy boundaries before LLM routing.
/// Rule 11 & Guardrail 7: HIGHLY_SENSITIVE data must NEVER leave the device.
@MainActor
final class DataClassifier {
    static let shared = DataClassifier()

    enum SensitivityLevel: String, Sendable, Comparable {
        case publicLevel = "PUBLIC"               // General knowledge, math, dictionary
        case personal = "PERSONAL"                 // Contacts, general notes, schedule
        case sensitive = "SENSITIVE"               // Local paths, personal docs, private code
        case highlySensitive = "HIGHLY_SENSITIVE" // Passwords, tokens, private keys, credit cards

        private var sortOrder: Int {
            switch self {
            case .publicLevel: return 0
            case .personal: return 1
            case .sensitive: return 2
            case .highlySensitive: return 3
            }
        }

        static func < (lhs: SensitivityLevel, rhs: SensitivityLevel) -> Bool {
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    // High sensitivity detection patterns
    private let highlySensitivePatterns = [
        "password",
        "api_key",
        "apikey",
        "secret",
        "private_key",
        "bearer ",
        "token",
        "id_rsa",
        "ssn",
        "credit card",
        "sudo "
    ]

    private let sensitivePatterns = [
        "/users/",
        ".env",
        ".gitconfig",
        "confidential",
        "bank",
        "account balance",
        "salary",
        "tax"
    ]

    private init() {}

    // MARK: - Public API

    /// Classify the sensitivity level of a text prompt or payload.
    func classify(_ text: String) -> SensitivityLevel {
        let lower = text.lowercased()

        // 1. Check highly sensitive indicators
        for pattern in highlySensitivePatterns {
            if lower.contains(pattern) {
                JarvisLogger.security.warning("Data classified as HIGHLY_SENSITIVE: contains pattern '\(pattern)'")
                return .highlySensitive
            }
        }

        // 2. Check sensitive indicators
        for pattern in sensitivePatterns {
            if lower.contains(pattern) {
                JarvisLogger.security.info("Data classified as SENSITIVE: contains pattern '\(pattern)'")
                return .sensitive
            }
        }

        // 3. Check personal indicators
        if lower.contains("my calendar") || lower.contains("my schedule") || lower.contains("my contact") || lower.contains("my email") {
            return .personal
        }

        return .publicLevel
    }

    /// Check if a cloud provider is permitted for this sensitivity level.
    func isCloudAllowed(for level: SensitivityLevel) -> Bool {
        switch level {
        case .publicLevel:
            return true
        case .personal:
            return true // Allowed with standard policy
        case .sensitive:
            return false // On-device MLX only by default
        case .highlySensitive:
            return false // STRICT RULE: NEVER cloud under any circumstance
        }
    }
}
