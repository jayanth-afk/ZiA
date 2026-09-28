import Foundation

/// Result produced by executing a tool.
struct ToolResult: Sendable {
    let success: Bool
    let output: String
    let sideEffects: [String]
    let metadata: [String: String]
    var verification: ToolVerificationResult?

    init(
        success: Bool,
        output: String,
        sideEffects: [String] = [],
        metadata: [String: String] = [:],
        verification: ToolVerificationResult? = nil
    ) {
        self.success = success
        self.output = output
        self.sideEffects = sideEffects
        self.metadata = metadata
        self.verification = verification
    }
}
/// System observation recorded after executing an action.
struct ObservationResult: Sendable {
    let observations: [String: String]
    let isAvailable: Bool
    let reason: String?

    init(observations: [String: String] = [:], isAvailable: Bool = true, reason: String? = nil) {
        self.observations = observations
        self.isAvailable = isAvailable
        self.reason = reason
    }

    static let unavailable = ObservationResult(
        observations: [:],
        isAvailable: false,
        reason: "Observation mechanism unavailable"
    )

    static func unavailable(reason: String) -> ObservationResult {
        ObservationResult(observations: [:], isAvailable: false, reason: reason)
    }
}

/// Explicit, structured outcome of post-action verification.
/// Disallows silent conversion of inconclusive or unavailable observations to passed.
struct ToolVerificationResult: Sendable, Equatable {
    let outcome: VerificationOutcome
    let reason: String?
    let expectedState: String?
    let observedState: String?

    init(outcome: VerificationOutcome, reason: String? = nil, expectedState: String? = nil, observedState: String? = nil) {
        self.outcome = outcome
        self.reason = reason
        self.expectedState = expectedState
        self.observedState = observedState
    }

    static let passed = ToolVerificationResult(outcome: .passed)

    static func passed(reason: String? = nil, expected: String? = nil, observed: String? = nil) -> ToolVerificationResult {
        ToolVerificationResult(outcome: .passed, reason: reason, expectedState: expected, observedState: observed)
    }

    static func failed(_ reason: String, expected: String? = nil, observed: String? = nil) -> ToolVerificationResult {
        ToolVerificationResult(outcome: .failed, reason: reason, expectedState: expected, observedState: observed)
    }

    static func inconclusive(_ reason: String, expected: String? = nil, observed: String? = nil) -> ToolVerificationResult {
        ToolVerificationResult(outcome: .inconclusive, reason: reason, expectedState: expected, observedState: observed)
    }

    static func unavailable(_ reason: String, expected: String? = nil, observed: String? = nil) -> ToolVerificationResult {
        ToolVerificationResult(outcome: .unavailable, reason: reason, expectedState: expected, observedState: observed)
    }

    var isSuccess: Bool {
        outcome == .passed
    }
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

    /// Metadata-aware observation avoids shared mutable "last target" state when
    /// multiple tool executions are in flight.
    func observe(expected: ToolResult) async throws -> ObservationResult

    /// Step 3: Detailed verification distinguishing passed, failed, inconclusive, and unavailable
    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult

    /// Step 3 (Boolean): Returns true ONLY if verifyDetailed is .passed
    func verify(expected: ToolResult, observed: ObservationResult) -> Bool
}

// Default implementations
extension JarvisTool {
    func observe(expected: ToolResult) async throws -> ObservationResult { try await observe() }
    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return verifyDetailed(expected: expected, observed: observed).isSuccess
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("Tool execution returned failure")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "Observation mechanism unavailable")
        }
        if let err = observed.observations["error"], !err.isEmpty {
            return .failed("Observation detected error: \(err)")
        }
        return .passed
    }

    /// Tools may opt out of declaring parameters (empty by default).
    var parameterSpec: [ToolParameterSpec] { [] }
}
