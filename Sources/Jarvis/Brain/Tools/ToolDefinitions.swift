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

/// Core protocol defining every JARVIS tool.
/// Rule 7 & Guardrail 8: Requires execute -> observe -> verify lifecycle and Sendable concurrency.
protocol JarvisTool: Sendable {
    var name: String { get }
    var description: String { get }
    var impact: PermissionGate.ActionImpact { get }

    /// Step 1: Execute the action
    func execute(arguments: [String: Any]) async throws -> ToolResult

    /// Step 2: Observe the real-world state of the system
    func observe() async throws -> ObservationResult

    /// Step 3: Verify that the expected result matches the observed state
    func verify(expected: ToolResult, observed: ObservationResult) -> Bool
}

// Default verification implementation
extension JarvisTool {
    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success
    }
}
