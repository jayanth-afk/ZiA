import Foundation

// MARK: - Plan Schema

/// One planned step. `toolName` is optional: a step without a tool is an
/// LLM-composition step (answer synthesis), which needs no execution.
struct PlanStep: Sendable, Equatable {
    let id: String
    let toolName: String?
    let arguments: [String: String]
    let purpose: String
}

/// A structured machine-readable plan produced by the MLX planner.
struct AgentPlan: Sendable, Equatable {
    let goal: String
    let steps: [PlanStep]

    var toolNames: [String] { steps.compactMap(\.toolName) }
}

// MARK: - Validation Errors

/// Distinct, honest failure reasons so callers (and the audit) can tell a
/// hallucinated tool from malformed JSON from an unsafe operation.
enum PlanValidationError: Error, Sendable, Equatable {
    case noJSONFound
    /// `underlying` = JSONSerialization reason; `raw` = excerpt of the actual
    /// model output so failures are diagnosable (audit/logs) without hiding them.
    case malformedJSON(underlying: String, raw: String?)
    case missingField(String)
    case wrongType(field: String)
    case emptySteps
    case tooManySteps(limit: Int)
    case unknownTool(String)
    case missingArgument(tool: String, argument: String)
    case unknownArgument(tool: String, argument: String)
    case wrongArgumentType(tool: String, argument: String, expected: String)
    case unsafeOperation(tool: String, reason: String)
    case stepLimitArgument(tool: String)

    var description: String {
        switch self {
        case .noJSONFound:
            return "No JSON object found in planner output"
        case .malformedJSON(let underlying, let raw):
            let excerpt = raw.map { " | raw: \(String($0.prefix(140)))" } ?? ""
            return "Planner output is not valid JSON: \(underlying)\(excerpt)"
        case .missingField(let field):
            return "Plan is missing required field '\(field)'"
        case .wrongType(let field):
            return "Plan field '\(field)' has the wrong JSON type"
        case .emptySteps:
            return "Plan contains no steps"
        case .tooManySteps(let limit):
            return "Plan exceeds the maximum of \(limit) steps"
        case .unknownTool(let name):
            return "Plan references unknown tool '\(name)' (not in ToolRegistry)"
        case .missingArgument(let tool, let argument):
            return "Step for '\(tool)' is missing required argument '\(argument)'"
        case .unknownArgument(let tool, let argument):
            return "Step for '\(tool)' declares undeclared argument '\(argument)'"
        case .wrongArgumentType(let tool, let argument, let expected):
            return "Step for '\(tool)' argument '\(argument)' must be \(expected)"
        case .unsafeOperation(let tool, let reason):
            return "Step for '\(tool)' rejected as unsafe: \(reason)"
        case .stepLimitArgument(let tool):
            return "Step for '\(tool)' uses the reserved internal argument"
        }
    }
}

// MARK: - Parser

enum AgentPlanParser {
    /// Maximum planner output accepted, bounded so a runaway generation
    /// cannot stall validation.
    static let maxPlannerOutputCharacters = 4_000

    /// Extract the outermost JSON object from arbitrary model output
    /// (handles prose wrapping and ```json fences) and decode it.
    static func parse(_ text: String) -> Result<AgentPlan, PlanValidationError> {
        let bounded = String(text.prefix(maxPlannerOutputCharacters))
        guard let jsonText = extractJSONObject(in: bounded) else {
            return .failure(.noJSONFound)
        }

        guard let data = jsonText.data(using: .utf8) else {
            return .failure(.noJSONFound)
        }

        do {
            let raw = try JSONSerialization.jsonObject(with: data)
            guard let object = raw as? [String: Any] else {
                return .failure(.wrongType(field: "root"))
            }
            return validateSchema(object)
        } catch {
            return .failure(.malformedJSON(underlying: error.localizedDescription, raw: jsonText))
        }
    }

    // MARK: Schema-level validation (shape only; tool semantics live in the validator)

    private static func validateSchema(_ object: [String: Any]) -> Result<AgentPlan, PlanValidationError> {
        guard let goal = object["goal"] as? String, !goal.isEmpty else {
            return .failure(.missingField("goal"))
        }

        guard let stepsRaw = object["steps"] else {
            return .failure(.missingField("steps"))
        }
        guard let stepsArray = stepsRaw as? [[String: Any]] else {
            return .failure(.wrongType(field: "steps"))
        }

        var steps: [PlanStep] = []
        for (index, stepRaw) in stepsArray.enumerated() {
            let id = (stepRaw["id"] as? String) ?? "step_\(index + 1)"
            // Small models frequently emit the JSON literal null as the STRING
            // "null" (tool:"null"), and omit "tool" entirely when answering
            // directly. Both mean the same thing: a composition step. Real
            // NSNull (tool: null in JSON) is normalized the same way.
            var toolName: String?
            let toolRaw = stepRaw["tool"]
            if toolRaw == nil || toolRaw is NSNull {
                toolName = nil
            } else if let value = toolRaw as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                toolName = (trimmed.isEmpty || trimmed == "null" || trimmed == "none" || trimmed == "<tool name>") ? nil : value
            } else {
                return .failure(.wrongType(field: "tool"))
            }

            var arguments: [String: String] = [:]
            if let argsRaw = stepRaw["arguments"] {
                guard let args = argsRaw as? [String: Any] else {
                    return .failure(.wrongType(field: "arguments"))
                }
                for (key, value) in args {
                    // Scalar arguments only; nested structures are rejected
                    // so no object ever reaches tool execution unvalidated.
                    switch value {
                    case let s as String: arguments[key] = s
                    case let n as NSNumber: arguments[key] = n.stringValue
                    default:
                        return .failure(.wrongArgumentType(tool: toolName ?? "?", argument: key, expected: "a scalar"))
                    }
                }
            }

            // Empty/missing purpose must not produce empty observation output.
            let purposeRaw = (stepRaw["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let purpose = (purposeRaw?.isEmpty == false) ? purposeRaw! : (toolName ?? "composed answer")
            steps.append(PlanStep(id: id, toolName: toolName, arguments: arguments, purpose: purpose))
        }

        return .success(AgentPlan(goal: goal, steps: steps))
    }

    /// Extract the first balanced `{ ... }` block. String-aware so braces
    /// inside JSON string values (e.g. shell commands) do not break extraction.
    private static func extractJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var index = start

        while index < text.endIndex {
            let char = text[index]
            if escape {
                escape = false
            } else if char == "\\" && inString {
                escape = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Validator

/// Grounds every plan against the LIVE ToolRegistry before anything executes.
/// This is the only gate between model output and tool execution: unknown
/// tools, invented arguments, wrong types, and unsafe operations are all
/// rejected here. The model can never bypass it.
///
/// @MainActor: reads ToolRegistry/CommandSandbox, which are MainActor-bound.
/// MLXPlanner awaits validateAsync() from its own actor; MainActor callers
/// (SelfTest, IntegrationAudit) use validate() directly.
@MainActor
enum PlanValidator {
    /// Hard ceiling on plan length — a 0.5B model looping on steps must be cut off.
    static let maxPlanSteps = 6

    static func validate(_ plan: AgentPlan) -> Result<AgentPlan, PlanValidationError> {
        guard !plan.steps.isEmpty else { return .failure(.emptySteps) }
        guard plan.steps.count <= maxPlanSteps else {
            return .failure(.tooManySteps(limit: maxPlanSteps))
        }

        let registry = ToolRegistry.shared
        let stepLimitArguments: Set<String> = ["jarvis_step_limit"]

        for step in plan.steps {
            // Steps without a tool are composition-only (final answer synthesis).
            guard let toolName = step.toolName else { continue }

            guard let tool = registry.getTool(named: toolName) else {
                return .failure(.unknownTool(toolName))
            }

            let declared = Dictionary(uniqueKeysWithValues: tool.parameterSpec.map { ($0.name, $0) })

            for (argName, value) in step.arguments {
                if stepLimitArguments.contains(argName) {
                    return .failure(.stepLimitArgument(tool: toolName))
                }
                guard let spec = declared[argName] else {
                    return .failure(.unknownArgument(tool: toolName, argument: argName))
                }
                switch spec.kind {
                case .int:
                    guard Int(value) != nil else {
                        return .failure(.wrongArgumentType(tool: toolName, argument: argName, expected: "an integer"))
                    }
                case .string:
                    break
                }
            }

            for spec in tool.parameterSpec where spec.required {
                guard step.arguments[spec.name] != nil else {
                    return .failure(.missingArgument(tool: toolName, argument: spec.name))
                }
            }

            // Defense in depth: the model cannot smuggle a shell command past
            // the sandbox by planning around run_shell's permission impact.
            // (ToolExecutor re-checks permissions at execution time; this check
            // rejects unsafe commands at plan time with a clear reason.)
            if toolName == "run_shell", let command = step.arguments["command"] {
                guard CommandSandbox.shared.isSafe(command) else {
                    return .failure(.unsafeOperation(tool: toolName, reason: "command rejected by CommandSandbox"))
                }
            }
        }

        return .success(plan)
    }

    /// Awaitable entry point for non-MainActor callers (MLXPlanner actor).
    nonisolated static func validateAsync(_ plan: AgentPlan) async -> Result<AgentPlan, PlanValidationError> {
        await MainActor.run { validate(plan) }
    }
}
