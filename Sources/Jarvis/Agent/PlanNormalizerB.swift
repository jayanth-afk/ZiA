import Foundation

/// EXPERIMENT B — deterministic single-shape normalizer.
///
/// Hypothesis under test (predeclared): the 0.5B planner sometimes emits the
/// malformed run_shell shape `{command: <bare program>, args: <string | [string]>}`
/// instead of the declared scalar `{command: "<complete shell command>"}`. When
/// that shape enters model-regenerated repair, the model's own literal can be
/// replaced by a prompt-example value (`echo hello`). If this ONE observed
/// malformed shape is normalized deterministically BEFORE validation, the
/// model's own literal reaches execution unchanged.
///
/// Scope guard (hard boundary):
/// - Activates ONLY for tool == "run_shell" whose arguments contain EXACTLY
///   `command` + `args`, with a whitespace-free `command` token and a
///   non-empty, whitespace-free `args` string, or a list of non-empty,
///   whitespace-free `args` strings.
/// - Uses ONLY values already present in the malformed arguments. It never
///   reads the goal, the prompt, examples, or any benchmark fixture. It can
///   therefore never introduce `echo hello` unless the model itself emitted it.
/// - Any ambiguity → FAIL CLOSED: the original structure is passed through to
///   the existing validation/repair path, unchanged.
/// - Reporting-only in production code: a `normalizerBEnabled` flag gates it,
///   and NO production call site is modified by Experiment B. It is exercised
///   through the offline replay harness, unit tests, and the benchmark's
///   treatment toggle only.
///
/// The normalizer does NOT weaken validation: its output is re-entered into
/// the unchanged AgentPlanParser + PlanValidator pipeline (see ReplayMain.swift
/// and Tests/JarvisTests/PlanNormalizerBTests.swift).
enum PlanNormalizerB {

    /// Outcome of one normalization attempt.
    enum Outcome: Equatable {
        /// The shape matched the single defect class and was rewritten.
        case normalized(from: String, to: String)
        /// The shape did not match; nothing was touched (fail closed).
        case notApplicable(reason: String)
    }

    /// Master toggle. Default OFF: production behavior is unchanged unless an
    /// experiment harness explicitly enables it in-process.
    nonisolated(unsafe) private static var enabledFlag = false
    private static let flagLock = NSLock()

    static var normalizerBEnabled: Bool {
        get { flagLock.withLock { enabledFlag } }
        set { flagLock.withLock { enabledFlag = newValue } }
    }

    // MARK: - Public entry point

    /// Attempt normalization of one candidate JSON object (as decoded by the
    /// existing parser's raw-JSON stage). Returns the possibly-rewritten
    /// object plus a reason string for instrumentation.
    ///
    /// `enabled == false` → immediately `notApplicable("disabled")` (control
    /// arm; identical behavior to pre-Experiment-B code).
    static func normalizeObject(
        _ object: [String: Any],
        enabled: Bool = normalizerBEnabled
    ) -> (result: Outcome, rewritten: [String: Any]) {
        guard enabled else {
            return (.notApplicable(reason: "normalizerB disabled (control)"), object)
        }
        guard case .normalized(let from, let to) = analyze(object) else {
            // Fail closed: return the original object untouched.
            return (analyze(object), object)
        }
        var rewritten = object
        // Step 4 invariant: the complete command string is built ONLY from
        // values already present in the malformed arguments.
        rewritten["steps"] = rewrittenSteps(object, joined: to)
        return (.normalized(from: from, to: to), rewritten)
    }

    // MARK: - Shape analysis (pure, no side effects, no I/O, no model)

    /// Decides whether the object contains the exact defect shape. Public so
    /// the offline replay can classify attempts without rewriting anything.
    static func analyze(_ object: [String: Any]) -> Outcome {
        guard let stepsRaw = object["steps"] else {
            return .notApplicable(reason: "no steps array")
        }
        guard let steps = stepsRaw as? [[String: Any]] else {
            return .notApplicable(reason: "steps is not an array of objects")
        }
        // Single-defect-class guard: only a single-step plan is considered.
        // A malformed multi-step plan has more than one way to fail and is
        // NOT part of the tested defect class.
        guard steps.count == 1, let step = steps.first else {
            return .notApplicable(reason: "steps.count != 1")
        }
        guard let tool = step["tool"] as? String, tool == "run_shell" else {
            return .notApplicable(reason: "tool != run_shell")
        }
        guard let argsRaw = step["arguments"] else {
            return .notApplicable(reason: "no arguments")
        }
        guard let args = argsRaw as? [String: Any] else {
            return .notApplicable(reason: "arguments is not an object")
        }
        // Exactly two keys: command + args. Any extra/missing field makes the
        // reconstruction ambiguous → fail closed (Step 5).
        guard args.count == 2, args["command"] != nil, args["args"] != nil else {
            return .notApplicable(reason: "arguments are not exactly {command, args}")
        }
        guard let command = args["command"] as? String else {
            return .notApplicable(reason: "command is not a string")
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Condition 3: command is a single whitespace-free token (a bare
        // program word). "echo hi" as command is already a complete command
        // and must NOT be split or rewritten.
        guard !trimmedCommand.isEmpty,
              !trimmedCommand.contains(where: { $0.isWhitespace }) else {
            return .notApplicable(reason: "command is not a single whitespace-free token")
        }
        // Condition 4: args is a non-empty whitespace-free string OR a list of
        // non-empty whitespace-free strings.
        let argValues: [String]
        switch args["args"] {
        case let s as String:
            argValues = [s]
        case let list as [Any]:
            var values: [String] = []
            for item in list {
                guard let s = item as? String else {
                    return .notApplicable(reason: "args list contains a non-string element")
                }
                values.append(s)
            }
            argValues = values
        default:
            return .notApplicable(reason: "args is neither string nor list of strings")
        }
        guard !argValues.isEmpty else {
            return .notApplicable(reason: "args is empty")
        }
        for value in argValues {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .notApplicable(reason: "args contains an empty value")
            }
            guard !trimmed.contains(where: { $0.isWhitespace }) else {
                // A whitespace-containing arg value has no unambiguous join
                // semantics (quoting, multi-word tokens) → fail closed.
                return .notApplicable(reason: "args value contains whitespace: cannot deterministically reconstruct")
            }
        }
        // Condition 5: unambiguous interpretation as `command + args`.
        // With a whitespace-free command token and whitespace-free arg values,
        // the only deterministic reading is concatenation with single spaces.
        // Shell quoting: every arg is joined as a bare token because
        // whitespace-free values cannot introduce quoting/injection ambiguity
        // through this join. Values are still shell-escaped defensively below.
        let joinedArgs = argValues
            .map { shellSafeToken($0) }
            .joined(separator: " ")
        let completeCommand = "\(trimmedCommand) \(joinedArgs)"
        let from = "run_shell{command=\"\(trimmedCommand)\", args=\(describeArgs(argValues))}"
        return .normalized(from: from, to: completeCommand)
    }

    // MARK: - Deterministic shell token safety

    /// A whitespace-free token is passed through verbatim IF it cannot change
    /// shell semantics on its own; otherwise it is single-quoted. This keeps
    /// the model's literal byte-identical in the common case (Step 4) while
    /// guaranteeing the joined command cannot gain new shell operators that
    /// were not already present in the model's own values.
    private static func shellSafeToken(_ token: String) -> String {
        let dangerous = CharacterSet(charactersIn: ";|&$`\\\"'()<>*?[]#~=!{}")
        if token.rangeOfCharacter(from: dangerous) != nil {
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return token
    }

    private static func describeArgs(_ values: [String]) -> String {
        values.count == 1 ? "\"\(values[0])\"" : "[\(values.joined(separator: ", "))]"
    }

    // MARK: - Rewrite

    /// Produces the rewritten steps array: same step id/tool/purpose, with the
    /// arguments object replaced by the single scalar `command`. Only
    /// `arguments` changes; nothing else in the plan is touched.
    private static func rewrittenSteps(_ object: [String: Any], joined: String) -> [[String: Any]] {
        guard let steps = object["steps"] as? [[String: Any]], let step = steps.first else {
            return []
        }
        var newStep = step
        newStep["arguments"] = ["command": joined]
        // Drop the malformed args key entirely — the declared schema has one
        // scalar `command`. `args` must not survive into validation.
        newStep.removeValue(forKey: "args")
        return [newStep]
    }
}
