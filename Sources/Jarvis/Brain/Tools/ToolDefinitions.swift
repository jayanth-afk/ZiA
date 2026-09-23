import Foundation

/// Result produced by executing a tool.
struct ToolResult: Sendable {
    let success: Bool
    let output: String
    let sideEffects: [String]
}

/// System observation recorded after executing an action.
struct ObservationResult: Sendable {
    let observations: [String: String]
}

/// Declared parameter schema for a tool. Used by the MLX planner's prompt
/// (compact tool catalog) and by the plan validator to check that every
/// model-provided argument exists, has the right type, and is present when
/// required. The planner can never invent arguments that pass validation.
struct ToolParameterSpec: Sendable {
    enum Kind: String, Sendable { case string, int }

    let name: String
    let kind: Kind
    let required: Bool
    let description: String

    init(name: String, kind: Kind = .string, required: Bool = true, description: String) {
        self.name = name
        self.kind = kind
        self.required = required
        self.description = description
    }
}

/// Core protocol defining every JARVIS tool.
/// Rule 7 & Guardrail 8: Requires execute -> observe -> verify lifecycle and Sendable concurrency.
protocol JarvisTool: Sendable {
    var name: String { get }
    var description: String { get }
    var impact: PermissionGate.ActionImpact { get }

    /// Declared parameters for LLM planning and validation.
    /// Empty by default for tools without typed arguments.
    var parameterSpec: [ToolParameterSpec] { get }

    /// Step 1: Execute the action
    func execute(arguments: [String: any Sendable]) async throws -> ToolResult

    /// Step 2: Observe the real-world state of the system
    func observe() async throws -> ObservationResult

    /// Step 3: Verify that the expected result matches the observed state
    func verify(expected: ToolResult, observed: ObservationResult) -> Bool
}

// Default implementations
extension JarvisTool {
    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success
    }

    /// Tools may opt out of declaring parameters (empty by default).
    var parameterSpec: [ToolParameterSpec] { [] }
}
