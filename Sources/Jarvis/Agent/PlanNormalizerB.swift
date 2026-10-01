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
public final class PlanNormalizerB: @unchecked Sendable {
    public static let shared = PlanNormalizerB()

    private static let jsonBlockRegex = try! NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)\\s*```", options: [.caseInsensitive])
    private static let trailingCommaRegex = try! NSRegularExpression(pattern: ",\\s*([}\\]])", options: [])

    public init() {}

    public func normalize(_ rawText: String) -> Data? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        var candidateText = trimmed

        let nsRange = NSRange(candidateText.startIndex..<candidateText.endIndex, in: candidateText)
        if let match = Self.jsonBlockRegex.firstMatch(in: candidateText, options: [], range: nsRange),
           let contentRange = Range(match.range(at: 1), in: candidateText) {
            candidateText = String(candidateText[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let firstBrace = candidateText.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let lastBrace = candidateText.lastIndex(where: { $0 == "}" || $0 == "]" }),
           firstBrace <= lastBrace {
            candidateText = String(candidateText[firstBrace...lastBrace])
        }

        if let data = candidateText.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        let mutableString = NSMutableString(string: candidateText)
        let fullRange = NSRange(location: 0, length: mutableString.length)
        Self.trailingCommaRegex.replaceMatches(in: mutableString, options: [], range: fullRange, withTemplate: "$1")
        
        let cleanedText = mutableString as String
        return cleanedText.data(using: .utf8)
    }

    /// Outcome of one normalization attempt.
    public enum Outcome: Equatable, Sendable {
        /// The shape matched the single defect class and was rewritten.
        case normalized(from: String, to: String)
        /// The shape did not match; nothing was touched (fail closed).
        case notApplicable(reason: String)
    }

    /// Master toggle. Default OFF: production behavior is unchanged unless an
    /// experiment harness explicitly enables it in-process.
    nonisolated(unsafe) private static var enabledFlag = false
    private static let flagLock = NSLock()

    public static var normalizerBEnabled: Bool {
        get { flagLock.withLock { enabledFlag } }
        set { flagLock.withLock { enabledFlag = newValue } }
    }

    // MARK: - Public entry point

    /// Attempt normalization of one candidate JSON object (as decoded by the
    /// existing parser's raw-JSON stage). Returns the possibly-rewritten
    /// object plus a reason string for instrumentation.
    public static func normalizeObject(
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
        rewritten["steps"] = rewrittenSteps(object, joined: to)
        return (.normalized(from: from, to: to), rewritten)
    }

    // MARK: - Shape analysis (pure, no side effects, no I/O, no model)

    /// Decides whether the object contains the exact defect shape. Public so
    /// the offline replay can classify attempts without rewriting anything.
    public static func analyze(_ object: [String: Any]) -> Outcome {
        guard let stepsRaw = object["steps"] else {
            return .notApplicable(reason: "no steps array")
        }
        guard let steps = stepsRaw as? [[String: Any]] else {
            return .notApplicable(reason: "steps is not an array of objects")
        }
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
        guard args.count == 2, args["command"] != nil, args["args"] != nil else {
            return .notApplicable(reason: "arguments are not exactly {command, args}")
        }
        guard let command = args["command"] as? String else {
            return .notApplicable(reason: "command is not a string")
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty,
              !trimmedCommand.contains(where: { $0.isWhitespace }) else {
            return .notApplicable(reason: "command is not a single whitespace-free token")
        }
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
                return .notApplicable(reason: "args value contains whitespace: cannot deterministically reconstruct")
            }
        }
        let joinedArgs = argValues
            .map { shellSafeToken($0) }
            .joined(separator: " ")
        let completeCommand = "\(trimmedCommand) \(joinedArgs)"
        let from = "run_shell{command=\"\(trimmedCommand)\", args=\(describeArgs(argValues))}"
        return .normalized(from: from, to: completeCommand)
    }

    // MARK: - Deterministic shell token safety

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

    private static func rewrittenSteps(_ object: [String: Any], joined: String) -> [[String: Any]] {
        guard let steps = object["steps"] as? [[String: Any]], let step = steps.first else {
            return []
        }
        var newStep = step
        newStep["arguments"] = ["command": joined]
        newStep.removeValue(forKey: "args")
        return [newStep]
    }
}