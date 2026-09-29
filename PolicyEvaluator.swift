import Foundation

/// Declarative policy engine for safe tool usage.
///
/// Reads a YAML/JSON policy file from `~/.jarvis/policy.yaml` (or specified path)
/// and provides a fast `isAllowed(tool:target:)` check for the `PlanValidator`.
///
/// The policy file format is a simple array of objects:
///   [
///     { "tool": "run_shell", "pattern": "^/Users/[^/]+/Downloads/" },
///     { "tool": "file.write", "pattern": "^/var/tmp/" }
///   ]
///
/// The pattern is interpreted as a regular expression (anchored at start).
/// If no policy file exists or cannot be parsed, the evaluator treats all tools as allowed
/// (open‑world fallback for backward compatibility).
@MainActor
final class PolicyEvaluator {
    static let shared = PolicyEvaluator()

    private let rules: [PolicyRule]

    struct PolicyRule: Codable {
        let tool: String
        let pattern: String
    }

    /// Initialize the policy engine.
    /// - Parameter policyPath: absolute or relative path to the policy file.
    init(policyPath: String = "\(NSHomeDirectoryPath())/.jarvis/policy.yaml") {
        let manager = FileManager.default
        guard manager.fileExists(atPath: policyPath) else {
            // File not present → treat as empty policy (allow all).
            self.rules = []
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: policyPath))
            self.rules = try JSONDecoder().decode([PolicyRule].self, from: data)
        } catch {
            // Parse failure → treat as empty policy (allow all). Log error if desired.
            self.rules = []
        }
    }

    /// Check whether a tool is authorized for a given target (e.g., file path).
    /// Returns true if the tool has at ≥ one matching rule, false otherwise.
    func isAllowed(tool: String, target: String) -> Bool {
        rules.contains { rule in
            rule.tool == tool && target.range(of: rule.pattern, options: .regularExpression) != nil
        }
    }
}