import Foundation
import CoreFoundation

/// Type ID of a genuine JSON boolean (CFBoolean) as bridged to NSNumber.
/// Used to keep booleans distinct from numeric 0/1 when normalizing arguments.
private func CFBooleanGetFalseTypeID() -> CFTypeID {
    let falseBoolean = false as NSNumber
    return CFGetTypeID(falseBoolean)
}

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
    case invalidReference(tool: String, argument: String, reason: String)

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
        case .invalidReference(let tool, let argument, let reason):
            return "Step for '\(tool)' argument '\(argument)' has invalid reference: \(reason)"
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
    ///
    /// The 0.5B model frequently emits MULTIPLE plan objects for multi-step
    /// goals (one per sub-goal). Candidates are tried in order; the first
    /// schema-valid object wins.
    static func parse(_ text: String) -> Result<AgentPlan, PlanValidationError> {
        // The repair prompt embeds an example skeleton containing the goal text.
        // Small models sometimes echo it verbatim alongside their real plan;
        // a skeleton echo is never a plan (it has a placeholder tool value).
        let boundedRaw = String(text.prefix(maxPlannerOutputCharacters))
        let bounded = stripJSONTerminatorEcho(stripSkeletonEcho(boundedRaw))
        let candidates = extractJSONObjectCandidates(in: bounded)
        guard !candidates.isEmpty else {
            return .failure(.noJSONFound)
        }

        var firstFailure: PlanValidationError?
        for jsonText in candidates {
            guard let data = jsonText.data(using: .utf8) else { continue }
            do {
                let raw = try JSONSerialization.jsonObject(with: data)
                guard let object = raw as? [String: Any] else {
                    if firstFailure == nil { firstFailure = .wrongType(field: "root") }
                    continue
                }
                switch validateSchema(object) {
                case .success(let plan):
                    return .success(plan)
                case .failure(let error):
                    if firstFailure == nil { firstFailure = error }
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = .malformedJSON(underlying: error.localizedDescription, raw: jsonText)
                }
            }
        }

        // Attempt prefix-join repair of an unterminated JSON string at the end
        // of the output (truncated mid-value by the token cap). Joining a
        // string that was split across an object boundary preserves the model's
        // intended value verbatim — no new content is invented. This is a
        // formatting repair only: every semantic check still runs afterward.
        let repairCandidate = firstFailure.map({ error -> PlanValidationError? in
            if case .malformedJSON = error { return error }
            return nil
        })
        if repairCandidate != nil {
            // Formatting repair 1: orphaned purpose — the model closes the step
            // object early and emits "purpose" at array level
            // (`}},"purpose":"X"}]`). Removing one brace reattaches it to the
            // step it belongs to.
            let orphanFixed = bounded.replacingOccurrences(
                of: "}},\"purpose\":\"",
                with: "},\"purpose\":\"")
            if orphanFixed != bounded,
               let data = orphanFixed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               case .success(let plan) = validateSchema(object) {
                return .success(plan)
            }

            // Formatting repair 2: prefix-join of a string truncated by the
            // token cap (value split across an object boundary).
            if let joined = joinSplitJSONString(in: bounded),
               let joinedData = joined.data(using: .utf8),
               let joinedObject = try? JSONSerialization.jsonObject(with: joinedData) as? [String: Any],
               case .success(let repairedPlan) = validateSchema(joinedObject) {
                return .success(repairedPlan)
            }
        }

        return .failure(firstFailure ?? .noJSONFound)
    }

    /// Remove a verbatim echo of the repair-prompt skeleton. The skeleton ends
    /// with `"tool":"<tool>"` — the placeholder distinguishes it from real plans.
    private static func stripSkeletonEcho(_ text: String) -> String {
        guard text.contains("\"tool\":\"<tool>\"") || text.contains("\"tool\": \"<tool>\"") else {
            return text
        }
        var result = text
        for needle in ["\"tool\":\"<tool>\"", "\"tool\": \"<tool>\""] {
            if let range = result.range(of: needle) {
                result.removeSubrange(range)
            }
        }
        return result
    }

    /// The prompt terminates with `JSON:`; a 0.5B model frequently glues the
    /// terminator onto the end of the echoed goal (`"goal":"echo hiJSON",
    /// ... "echo hiJSON"}`, or `hiJSON:` before a newline). Strip terminator
    /// suffixes from string values so echoed command text stays byte-identical
    /// to the user's actual goal.
    private static func stripJSONTerminatorEcho(_ text: String) -> String {
        var result = text
        // Observed 0.5B echo variants of the "JSON: " prompt terminator glued
        // to string values: `valueJSON: "` (colon+space), `valueJSON"` (bare
        // word), and `valueJSON:\n"` (colon+newline).
        for needle in ["JSON: \"", "JSON\"", "JSON:\n\""] {
            while let range = result.range(of: needle) {
                result.replaceSubrange(range, with: "\"")
            }
        }
        return result
    }

    /// Observed 0.5B truncation mode: a string value is cut by the token cap
    /// and the remaining tail restarts mid-string in the next emitted object
    /// (`"command":"echo foo\nbarbaz"}`). Join the head (minus the dangling
    /// key quote) with the tail (minus its opening quote) to recover the
    /// intended value. Returns nil when the text does not match this pattern.
    private static func joinSplitJSONString(in text: String) -> String? {
        guard let quoteSplit = text.range(of: "\"\n", options: .backwards) else { return nil }
        var head = String(text[..<quoteSplit.lowerBound])
        let tail = String(text[quoteSplit.upperBound...])
        guard let colon = head.lastIndex(of: ":") else { return nil }
        head = String(head[..<colon])
        guard head.hasSuffix("\"") else { return nil }
        head += ": \"" + tail
        return head
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
                    case let n as NSNumber:
                        // Distinguish real JSON booleans (CFBoolean) from numeric
                        // 0/1 before stringifying — 40 must stay "40", not "true".
                        if CFGetTypeID(n) == CFBooleanGetFalseTypeID() {
                            arguments[key] = n.boolValue ? "true" : "false"
                        } else {
                            arguments[key] = n.stringValue
                        }
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

    /// Extract ALL balanced top-level `{ ... }` blocks. String-aware so braces
    /// inside JSON string values (e.g. shell commands) do not break extraction.
    private static func extractJSONObjectCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var inString = false
        var escape = false
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if escape {
                escape = false
            } else if char == "\\" && inString {
                escape = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                }
                if char == "}" {
                    depth -= 1
                    if depth == 0, let s = start {
                        candidates.append(String(text[s...index]))
                        start = nil
                    }
                }
            }
            index = text.index(after: index)
        }
        return candidates
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

        for (stepIndex, step) in plan.steps.enumerated() {
            let currentStepNumber = stepIndex + 1
            // Steps without a tool are composition-only (final answer synthesis).
            guard let toolName = step.toolName else { continue }

            guard let tool = registry.getTool(named: toolName) else {
                return .failure(.unknownTool(toolName))
            }

            // An empty command is not a real plan — reject instead of
            // executing a no-op shell invocation.
            if toolName == "run_shell",
               let command = step.arguments["command"],
               command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.unsafeOperation(tool: toolName, reason: "empty shell command"))
            }

            let declared = Dictionary(uniqueKeysWithValues: tool.parameterSpec.map { ($0.name, $0) })

            for (argName, value) in step.arguments {
                if stepLimitArguments.contains(argName) {
                    return .failure(.stepLimitArgument(tool: toolName))
                }
                guard let spec = declared[argName] else {
                    return .failure(.unknownArgument(tool: toolName, argument: argName))
                }

                // Reference validation vs scalar type validation
                let taskArg: TaskArgument
                do {
                    taskArg = try ReferenceResolver.parseArgument(value)
                } catch {
                    return .failure(.invalidReference(tool: toolName, argument: argName, reason: error.localizedDescription))
                }

                do {
                    try ReferenceResolver.validateArgument(taskArg, currentStepNumber: currentStepNumber)
                } catch {
                    return .failure(.invalidReference(tool: toolName, argument: argName, reason: error.localizedDescription))
                }

                switch taskArg {
                case .literal(let literalStr):
                    switch spec.kind {
                    case .int:
                        guard Int(literalStr) != nil else {
                            return .failure(.wrongArgumentType(tool: toolName, argument: argName, expected: "an integer"))
                        }
                    case .string:
                        break
                    }
                case .reference, .template:
                    // References and templates will be validated for scalar types at execution time after resolution
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
                if !command.contains("$step") && !command.contains("$ambient") {
                    guard CommandSandbox.shared.isSafe(command) else {
                        return .failure(.unsafeOperation(tool: toolName, reason: "command rejected by CommandSandbox"))
                    }
                }
            }

            if toolName == "read_file" || toolName == "write_file", let path = step.arguments["path"] {
                if !path.contains("$step") && !path.contains("$ambient") {
                    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        return .failure(.unsafeOperation(tool: toolName, reason: "empty file path"))
                    }
                    if trimmed.contains("..") {
                        return .failure(.unsafeOperation(tool: toolName, reason: "directory traversal '..' forbidden"))
                    }
                    let lower = trimmed.lowercased()
                    let sensitiveSubpaths = [".ssh", ".gnupg", ".aws", ".kube", ".config/gcloud", ".env", ".netrc", ".zsh_history", ".bash_history"]
                    if sensitiveSubpaths.contains(where: { lower.contains($0) }) {
                        return .failure(.unsafeOperation(tool: toolName, reason: "access to sensitive subpath forbidden"))
                    }
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
