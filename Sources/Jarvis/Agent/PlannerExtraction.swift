import Foundation
import CryptoKit

// MARK: - Bounded Planner Extraction (decomposed planning pipeline)
//
// Architectural position (frozen pipeline, unchanged):
//
//   MODEL OUTPUT
//     ↓ bounded structured extraction   (this file: PlannerExtraction)
//     ↓ typed intermediate representation (ExtractedAction)
//     ↓ deterministic compiler          (PlannerExtraction.compile)
//     ↓ existing AgentPlan / PlanStep   (PlanValidator.swift types)
//     ↓ PlanValidator (authoritative, untouched authority)
//     ↓ ToolExecutor (untouched)
//
// The model is asked for a SMALLER thing than a whole plan: one tool choice,
// the user's literal argument text copied from the goal, and an explicit
// `literal` anchor identifying the user's payload span. Everything structural
// — ids, purposes, argument dictionaries, plan shapes — is produced by
// deterministic compilation, not by the model. When required user content is
// genuinely unavailable or fabricated, extraction fails CLOSED instead of
// substituting content.

// MARK: - Extraction IR

/// Bounded output of the extraction stage: the model's ONE tool choice plus
/// the argument values the model claims the goal contains.
/// No plan shape, no ids, no purposes — those are compiled deterministically.
struct ExtractedAction: Equatable, Sendable {
    /// Tool name the model selected (validated against the live registry by the compiler).
    let toolName: String
    /// Argument dictionary produced from the model's extraction.
    let arguments: [String: String]
    /// The user-literal ANCHOR: the span of the goal the model identified as
    /// the user's payload (e.g. `jarvis_planner_e2e_verified`). The compiler
    /// verifies this span survives into the compiled arguments byte-for-byte.
    /// nil when the model declared no user literal (preservation = N/A).
    let literal: String?
}

/// Deterministic failure modes of the bounded extraction. Each one is
/// diagnosable and none of them silently substitutes content.
enum ExtractionFailure: Error, Equatable, Sendable {
    case noJSONFound
    case malformedJSON
    case missingToolField
    /// The model emitted the malformed `{"command": X, "args": Y}` shape
    /// (array/object valued argument). Repairable by structuralRepair only.
    case malformedCommandShape
}

// MARK: - Argument-preservation recorder

/// Explicit instrumentation for the pipeline:
///   original user literal → extracted literal → compiled literal → executed
///   literal → observed artifact
///
/// This is an EXPLICIT metric, deliberately not folded into any general
/// semantic score. The chain is only "preserved" when the model-declared
/// literal anchor (a gated span of the user's goal) survives byte-for-byte
/// into BOTH the compiled arguments and the executed arguments. Runs without
/// an extraction stage (legacy whole-plan path) report `preserved = nil`
/// (not applicable) — they never masquerade as preservation passes.
@MainActor
final class ArgumentPreservationRecorder {
    static let shared = ArgumentPreservationRecorder()

    struct Record: Sendable {
        let id: UUID
        let at: Date
        /// The goal text as the user gave it.
        let originalGoal: String
        /// The literal anchor the extraction stage returned (nil = no
        /// extraction stage ran, e.g. legacy whole-plan path).
        let extractedLiteral: String?
        /// The compiled argument value carrying the anchor (nil when absent).
        let compiledLiteral: String?
        /// The executed (post-reference-resolution) argument value carrying
        /// the anchor (nil when execution has not completed).
        let executedLiteral: String?
        /// Byte-exact preservation verdict. true only when the anchor survived
        /// into both compiled and executed values byte-for-byte; nil = N/A.
        let preserved: Bool?
    }

    private let records = LockedValue<[Record]>([])

    private init() {}

    /// Record the extracted → compiled stage of one planner run. Called only
    /// on compilation success (a failed compile never reaches execution).
    func recordCompilation(originalGoal: String, extractedLiteral: String?, compiledLiteral: String?) {
        let record = Record(
            id: UUID(), at: Date(), originalGoal: originalGoal,
            extractedLiteral: extractedLiteral, compiledLiteral: compiledLiteral,
            executedLiteral: nil, preserved: nil)
        var current = records.value
        current.append(record)
        records.value = current
    }

    /// Complete a record with the executed value and compute the byte-exact
    /// preservation verdict. Called by AgentLoop after a planner-routed step
    /// executes. Records without an extracted anchor are left N/A on purpose.
    func noteExecution(goal: String, resolvedArguments: [String: String]) {
        var current = records.value
        guard let index = current.lastIndex(where: {
            $0.executedLiteral == nil && $0.originalGoal == goal && $0.extractedLiteral != nil
        }) else { return }
        let record = current[index]
        guard let anchor = record.extractedLiteral else { return }
        // The executed value carrying the anchor (first argument value that
        // contains it byte-for-byte or case-insensitively).
        let executed = resolvedArguments.values.first { $0.contains(anchor) || $0.range(of: anchor, options: .caseInsensitive) != nil }
        // Preserved = anchor survived to execution AND the compiled value
        // reached execution unchanged (byte-for-byte compiled == executed).
        let preserved = (executed != nil) && (record.compiledLiteral != nil) && (record.compiledLiteral == executed)
        current[index] = Record(
            id: record.id, at: record.at, originalGoal: record.originalGoal,
            extractedLiteral: record.extractedLiteral, compiledLiteral: record.compiledLiteral,
            executedLiteral: executed, preserved: preserved)
        records.value = current
    }

    /// All records (newest last). Read-only evidence access.
    func allRecords() -> [Record] { records.value }

    /// Records for one goal (newest last).
    func records(forGoal goal: String) -> [Record] {
        records.value.filter { $0.originalGoal == goal }
    }

    /// Reset (test hygiene).
    func reset() { records.value = [] }
}

// MARK: - Bounded extractor + deterministic compiler

enum PlannerExtraction {

    /// Hard bound on accepted model output, same bound class as AgentPlanParser.
    static let maxExtractionOutputCharacters = 2_000

    /// Deterministically capture an explicit, single shell-echo request where
    /// the payload is visibly delimited by the user's wording. This avoids
    /// asking a small model to copy arbitrary prose (the benchmark repeatedly
    /// showed truncation/substitution on multi-word and punctuation literals).
    /// The accepted payload is bounded, single-line, and excludes apostrophes
    /// so one POSIX single-quoted argument is unambiguous. Everything else
    /// falls through to normal planning; this is deliberately not a shell DSL.
    static func explicitShellEchoExtraction(goal: String) -> ExtractedAction? {
        let pattern = #"^\s*(?:write|print)\s+the\s+(?:word|words|phrase|line)\s+(.+?)\s+using\s+(?:run_shell|echo\s+in\s+the\s+shell|the\s+shell)\s*[.?]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsGoal = goal as NSString
        let fullRange = NSRange(location: 0, length: nsGoal.length)
        guard let match = regex.firstMatch(in: goal, range: fullRange), match.numberOfRanges == 2 else { return nil }
        var literal = nsGoal.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Quotation marks in this grammar can delimit the requested payload
        // (they are not themselves part of what should be printed).
        if literal.count >= 2,
           (literal.first == "\"" && literal.last == "\"") ||
            (literal.first == "“" && literal.last == "”") {
            literal.removeFirst()
            literal.removeLast()
        }
        guard !literal.isEmpty,
              literal.utf8.count <= 2_048,
              !literal.contains("'"),
              !literal.contains("\n"),
              !literal.contains("\r"),
              !literal.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return ExtractedAction(
            toolName: "run_shell",
            arguments: ["command": "echo '\(literal)'"],
            literal: literal)
    }

    /// Deterministically capture a polite or indirect open-application request
    /// whose prefix unambiguously identifies the tool and whose remainder is
    /// the application name. This covers forms that `DeterministicRouter`
    /// intentionally does not handle (it requires crisp structural prefixes and
    /// an `AppLauncher.canResolve()` guard; this layer does neither — it only
    /// extracts a typed argument).
    ///
    /// IMPORTANT: The L0 `DeterministicRouter.matchAppCommand()` handles the
    /// canonical `open/launch/start/switch to <app>` forms with 0 model calls
    /// BEFORE this extractor is ever reached. Do NOT add those prefixes here;
    /// doing so would silently compete with the L0 router (which runs first).
    ///
    /// Accepted prefix forms (longest-first to avoid short-prefix shadowing):
    ///   open the app called <app>   · launch the app called <app>
    ///   open the app <app>          · launch the app <app>
    ///   please open <app>           · please launch <app>  · please start <app>
    ///   can you open <app>          · can you launch <app>
    ///
    /// All other forms (including `open <app>`, `launch <app>`, `switch to
    /// <app>`) fall through to the 0.5B model or the L0 router respectively.
    static func explicitOpenAppExtraction(goal: String) -> ExtractedAction? {
        let lower = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        // Compound guard: multi-action utterances must go to the planner.
        // Applied before prefix matching so an adversarial compound request
        // that happens to start with a recognised prefix is never matched.
        let compoundMarkers = [" and then", ", then", " then ", " & ", " also ",
                               " and open", " and launch", " and start", " or "]
        if compoundMarkers.contains(where: { lower.contains($0) }) { return nil }

        // Negation guard: "don't open X", "do not launch X", etc.
        let negations = ["don't", "do not", "never ", "not open", "not launch",
                         "without opening", "without launching"]
        if negations.contains(where: { lower.contains($0) }) { return nil }

        // Question guard at the START of the utterance — except "can you …"
        // which is an accepted polite prefix, not a genuine question.
        let questionStarters = ["what ", "why ", "how ", "when ", "is ", "are ",
                                "does ", "which ", "who ", "where "]
        if questionStarters.contains(where: { lower.hasPrefix($0) }) { return nil }

        // Accepted prefix forms, ordered longest-first to prevent short-prefix
        // shadowing (e.g. "open the app" must not match before "open the app called").
        let prefixes: [String] = [
            "open the app called ",
            "launch the app called ",
            "open the app ",
            "launch the app ",
            "please open ",
            "please launch ",
            "please start ",
            "can you open ",
            "can you launch ",
        ]

        for prefix in prefixes {
            guard lower.hasPrefix(prefix) else { continue }
            // Slice the original goal (not the lowercased copy) to preserve
            // case for app names like "Xcode", "GitHub Desktop", etc.
            var appName = String(goal.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip common trailing punctuation.
            while let last = appName.last, ".?!,".contains(last) {
                appName = String(appName.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Post-strip validation guards.
            guard !appName.isEmpty,
                  appName.count <= 100,
                  !appName.lowercased().contains(" and "),
                  !appName.contains(", "),
                  !appName.contains(";"),
                  !appName.lowercased().contains(" or "),
                  !appName.lowercased().contains(" then ") else { return nil }
            // The app name is the literal anchor: the compiler's adoption gate
            // will verify it is a contiguous span of the original goal.
            return ExtractedAction(
                toolName: "open_app",
                arguments: ["app_name": appName],
                literal: appName)
        }
        return nil
    }

    /// Deterministically capture an explicit, bounded volume-setting request
    /// where the prefix identifies the intent and the remainder is a volume level (0-100).
    ///
    /// IMPORTANT: L0 `DeterministicRouter.matchVolumeCommand()` handles:
    ///   - "set volume to <N>"
    ///   - "set volume <N>"
    ///   - "volume <N>%"
    /// BEFORE this extractor is reached.
    ///
    /// Accepted prefix forms (polite, indirect, and article-qualified):
    ///   please set the volume to <N>   · please set volume to <N>
    ///   can you set the volume to <N>  · can you set volume to <N>
    ///   set the volume to <N>          · set the volume <N>
    ///   adjust the volume to <N>       · change the volume to <N>
    ///   turn the volume up to <N>      · turn the volume down to <N>
    ///   turn the volume to <N>         · turn volume to <N>
    ///
    /// All other forms fall through to the model or L0 router respectively.
    static func explicitSetVolumeExtraction(goal: String) -> ExtractedAction? {
        let lower = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        // Compound guard: multi-action utterances must go to the planner.
        let compoundMarkers = [" and then", ", then", " then ", " & ", " also ",
                               " and set", " and turn", " or "]
        if compoundMarkers.contains(where: { lower.contains($0) }) { return nil }

        // Negation guard: "don't set the volume", "do not change volume", etc.
        let negations = ["don't", "do not", "never ", "not set", "not change",
                         "without setting", "without changing"]
        if negations.contains(where: { lower.contains($0) }) { return nil }

        // Question guard at the START of the utterance — except "can you …"
        let questionStarters = ["what ", "why ", "how ", "when ", "is ", "are ",
                                "does ", "which ", "who ", "where "]
        if questionStarters.contains(where: { lower.hasPrefix($0) }) { return nil }

        // Accepted prefix forms, ordered longest-first to prevent short-prefix shadowing.
        let prefixes: [String] = [
            "please set the volume to ",
            "can you set the volume to ",
            "please set volume to ",
            "can you set volume to ",
            "turn the volume up to ",
            "turn the volume down to ",
            "turn the volume to ",
            "set the volume to ",
            "adjust the volume to ",
            "change the volume to ",
            "set the volume ",
            "turn volume to ",
        ]

        for prefix in prefixes {
            guard lower.hasPrefix(prefix) else { continue }
            var levelStr = String(goal.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = levelStr.last, ".?!,".contains(last) {
                levelStr = String(levelStr.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if levelStr.hasSuffix("%") {
                levelStr = String(levelStr.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !levelStr.isEmpty,
                  let level = Int(levelStr),
                  (0...100).contains(level) else { return nil }
            return ExtractedAction(
                toolName: "set_volume",
                arguments: ["level": String(level)],
                literal: levelStr)
        }
        return nil
    }

    /// Deterministically capture an explicit, bounded file-writing request
    /// where the content is explicitly quoted and the target path is non-ambiguous.
    ///
    /// Grammar requirements:
    ///   - Must begin with an explicit write or save verb (with optional polite prefix "please" / "can you")
    ///   - Content MUST be explicitly delimited by single quotes '...', double quotes "...", or smart quotes “...”
    ///   - Target path must follow an explicit connector ("to", "to file", "to the file")
    ///   - Path must be safe (no directory traversal `..`, no quotes, no bare directory, no blocked system directories, no sensitive home paths)
    ///
    /// Any ambiguous, unquoted, multi-command, negation, or question input returns nil (soft fall-through).
    static func explicitWriteFileExtraction(goal: String) -> ExtractedAction? {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return nil }
        let lower = trimmedGoal.lowercased()

        // Compound guard: multi-action utterances must go to the planner.
        let compoundMarkers = [" and then", ", then", " then ", " & ", " also ", " or "]
        if compoundMarkers.contains(where: { lower.contains($0) }) { return nil }

        // Multiple write/save verbs in one sentence indicate a compound or multi-file request.
        if lower.components(separatedBy: "write").count > 2 || lower.components(separatedBy: "save").count > 2 {
            return nil
        }

        // Negation guard: "don't write ...", "do not save ...", etc.
        let negations = ["don't", "do not", "never ", "not write", "not save",
                         "without writing", "without saving"]
        if negations.contains(where: { lower.contains($0) }) { return nil }

        // Question guard at the START of the utterance — except "can you …"
        let questionStarters = ["what ", "why ", "how ", "when ", "is ", "are ",
                                "does ", "which ", "who ", "where ", "can i "]
        if questionStarters.contains(where: { lower.hasPrefix($0) }) { return nil }

        // Instructions merely discussing write_file or meta queries
        if lower.contains("how to") || lower.contains("write_file") || lower.contains("explain") {
            return nil
        }

        // Pattern matching explicit quoted content and explicit path.
        // Captures:
        // Group 1: single-quoted content
        // Group 2: double-quoted content
        // Group 3: smart-quoted content
        // Group 4: target path
        let pattern = #"^\s*(?:please\s+|can\s+you\s+)?(?:write|save)(?:\s+the\s+(?:text|line|string|words|phrase|content))?\s+(?:'([^']*)'|"([^"]*)"|“([^”]*)”)\s+(?:to\s+file|to\s+the\s+file|to)\s+([^\s'"]+)\s*[.!]?\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsGoal = trimmedGoal as NSString
        let fullRange = NSRange(location: 0, length: nsGoal.length)
        guard let match = regex.firstMatch(in: trimmedGoal, range: fullRange), match.numberOfRanges == 5 else {
            return nil
        }

        // Extract content from whichever quote group matched
        let content: String
        let r1 = match.range(at: 1)
        let r2 = match.range(at: 2)
        let r3 = match.range(at: 3)
        if r1.location != NSNotFound {
            content = nsGoal.substring(with: r1)
        } else if r2.location != NSNotFound {
            content = nsGoal.substring(with: r2)
        } else if r3.location != NSNotFound {
            content = nsGoal.substring(with: r3)
        } else {
            return nil
        }

        // Extract path
        let r4 = match.range(at: 4)
        guard r4.location != NSNotFound else { return nil }
        var path = nsGoal.substring(with: r4).trimmingCharacters(in: .whitespacesAndNewlines)

        while let last = path.last, ".?!,".contains(last) {
            path = String(path.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Content validation: non-empty, bounded length, no null bytes
        guard !content.isEmpty,
              content.utf8.count <= 100_000,
              !content.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }

        // Path validation: non-empty, not a directory, no traversal, no quotes, no newlines/nulls
        guard !path.isEmpty,
              !path.hasSuffix("/"),
              !path.contains(".."),
              !path.contains("//"),
              !path.contains("'"),
              !path.contains("\""),
              !path.contains("“"),
              !path.contains("”"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }

        // Path sandbox / containment safety checks:
        let lowerPath = path.lowercased()
        let blockedSystemPrefixes = [
            "/system", "/library", "/usr", "/bin", "/sbin",
            "/private", "/etc", "/var", "/dev"
        ]
        for prefix in blockedSystemPrefixes {
            if lowerPath == prefix || lowerPath.hasPrefix(prefix + "/") {
                return nil
            }
        }
        let expanded = (path as NSString).expandingTildeInPath.lowercased()
        for prefix in blockedSystemPrefixes {
            if expanded == prefix || expanded.hasPrefix(prefix + "/") {
                return nil
            }
        }
        let blockedSubpaths = [
            ".ssh", ".gnupg", ".aws", ".kube", ".config/gcloud",
            ".env", ".netrc", ".zsh_history", ".bash_history"
        ]
        for subpath in blockedSubpaths {
            if lowerPath.contains(subpath) || expanded.contains(subpath) {
                return nil
            }
        }

        return ExtractedAction(
            toolName: "write_file",
            arguments: ["path": path, "content": content],
            literal: content
        )
    }

    // MARK: Parsing

    /// Parse the bounded extraction JSON the decomposition prompt requests:
    ///   {"tool": "<registry tool name>", "arguments": {<declared args>},
    ///    "literal": "<the user's payload copied from the goal>"}
    ///
    /// The parser accepts ONLY the bounded shape; it performs no semantic
    /// repair. `literal` is an extraction-level field (never a tool argument,
    /// so it cannot reach PlanValidator as an undeclared argument).
    static func parse(_ text: String) -> Result<ExtractedAction, ExtractionFailure> {
        let bounded = String(text.prefix(maxExtractionOutputCharacters))
        guard let start = bounded.firstIndex(of: "{"),
              let end = bounded.lastIndex(of: "}"),
              start < end else {
            return .failure(.noJSONFound)
        }
        let jsonText = String(bounded[start...end])
        guard let data = jsonText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        guard let toolRaw = object["tool"] else {
            return .failure(.missingToolField)
        }
        guard let toolName = toolRaw as? String, !toolName.isEmpty else {
            return .failure(.missingToolField)
        }
        guard let argsRaw = object["arguments"] as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        var arguments: [String: String] = [:]
        for (key, value) in argsRaw {
            switch value {
            case let s as String:
                arguments[key] = s
            case let n as NSNumber:
                // Distinguish real JSON booleans from numeric 0/1 (same rule
                // as AgentPlanParser's normalization).
                if CFGetTypeID(n) == CFBooleanGetFalseType() {
                    arguments[key] = n.boolValue ? "true" : "false"
                } else {
                    arguments[key] = n.stringValue
                }
            default:
                // Arrays/objects are exactly the malformed command shape the
                // pipeline has observed ({"command": ..., "args": [...]}) —
                // reject deterministically; structuralRepair is the only path.
                return .failure(.malformedCommandShape)
            }
        }
        let literal = object["literal"] as? String
        return .success(ExtractedAction(
            toolName: toolName,
            arguments: arguments,
            literal: literal))
    }

    // MARK: Literal adoption gate (anti-fabrication; NOT a generic substring heuristic)

    /// Deterministic anti-fabrication gate for the ONE field the model is
    /// allowed to fill with user content.
    ///
    /// Rule: the extracted literal must be a CONTIGUOUS SPAN of the user's
    /// own goal text (byte-exact, or byte-exact after whitespace
    /// normalization for goals wrapped across lines). The model's job in the
    /// extraction stage is to COPY, not to compose. If its "literal" is not a
    /// span of the user's text, it fabricated content, and the pipeline must
    /// fail closed rather than execute invented text.
    ///
    /// This is the single documented adoption rule for this field — not a
    /// substring check scattered elsewhere, and not a repair mechanism.
    static func literalAdoptionGate(goal: String, extracted: String) -> Bool {
        let whitespace = CharacterSet.whitespacesAndNewlines
        let candidate = extracted.trimmingCharacters(in: whitespace)
        guard !candidate.isEmpty else { return false }
        // Byte-exact contiguous span of the goal.
        if goal.contains(candidate) { return true }
        // Whitespace-normalized contiguous span (goal wrapped across lines).
        let normalizedGoal = goal.components(separatedBy: whitespace)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let normalizedCandidate = candidate.components(separatedBy: whitespace)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if normalizedGoal.contains(normalizedCandidate) { return true }
        // Case-insensitive contiguous span (0.5B tokenization case drift):
        if goal.range(of: candidate, options: .caseInsensitive) != nil { return true }
        return normalizedGoal.range(of: normalizedCandidate, options: .caseInsensitive) != nil
    }

    // MARK: Deterministic compilation

    /// Deterministically compile an ExtractedAction into the EXISTING AgentPlan
    /// representation. The compiler owns ALL structure: step ids, purposes,
    /// argument-dictionary shapes. Unknown tools, undeclared arguments, and
    /// fabricated literals are rejected here (fail-closed) — the compiler
    /// never invents a plan and never substitutes a user argument.
    @MainActor
    static func compile(_ extracted: ExtractedAction, goal: String) -> Result<AgentPlan, PlanValidationError> {
        // The tool must exist in the live registry. No exceptions.
        guard let tool = ToolRegistry.shared.getTool(named: extracted.toolName) else {
            return .failure(.unknownTool(extracted.toolName))
        }
        let declared = Dictionary(uniqueKeysWithValues: tool.parameterSpec.map { ($0.name, $0) })

        // Every emitted argument must be declared. Undeclared keys are the
        // model inventing schema — rejected, never silently dropped.
        for key in extracted.arguments.keys where declared[key] == nil {
            return .failure(.unknownArgument(tool: extracted.toolName, argument: key))
        }

        var arguments = extracted.arguments
        // Anti-fabrication + preservation gate on the user-literal anchor:
        // 1. The anchor must be a span of the user's goal (adoption gate).
        // 2. The anchor must SURVIVE into the compiled arguments byte-for-byte.
        // A model output like {"command": "echo hello"} for the goal "write
        // the word jarvis_planner_e2e_verified…" fails here: either its anchor
        // is fabricated (not a goal span) or the anchor did not survive.
        if let literal = extracted.literal {
            guard literalAdoptionGate(goal: goal, extracted: literal) else {
                return .failure(.unsafeOperation(
                    tool: extracted.toolName,
                    reason: "extracted literal is not a span of the user's goal text (argument fabrication rejected)"))
            }
            // Align literal and argument values to the user's exact goal casing if case drifted.
            // This preserves the user's exact original casing from their goal.
            var effectiveLiteral = literal
            if !goal.contains(literal), let range = goal.range(of: literal, options: .caseInsensitive) {
                let exactCasing = String(goal[range])
                effectiveLiteral = exactCasing
                for (k, v) in arguments {
                    if let argRange = v.range(of: literal, options: .caseInsensitive) {
                        arguments[k] = v.replacingCharacters(in: argRange, with: exactCasing)
                    }
                }
            }
            let preservedInCompiled = arguments.values.contains { $0.contains(effectiveLiteral) }
            guard preservedInCompiled else {
                return .failure(.unsafeOperation(
                    tool: extracted.toolName,
                    reason: "user literal '\(String(literal.prefix(60)))' is not preserved in the compiled arguments (argument substitution rejected)"))
            }
        }

        // Required arguments the model did not provide fail closed.
        for spec in tool.parameterSpec where spec.required && arguments[spec.name] == nil {
            return .failure(.missingArgument(tool: extracted.toolName, argument: spec.name))
        }

        let step = PlanStep(
            id: "step_1",
            toolName: extracted.toolName,
            arguments: arguments,
            purpose: "extracted from goal: \(goal.prefix(80))")
        // The decomposition compiler is not an alternate authority path.
        // Apply the canonical validator after constructing the typed plan so
        // shell sandboxing, reference rules, argument constraints, and every
        // future PlanValidator invariant remain mandatory for this route too.
        switch PlanValidator.validate(AgentPlan(goal: goal, steps: [step])) {
        case .success(let validatedPlan):
            return .success(validatedPlan)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The compiled argument value carrying the literal anchor, for the
    /// preservation recorder. nil when the extraction declared no anchor.
    static func compiledValue(carrying literal: String?, in plan: AgentPlan) -> String? {
        guard let literal else { return nil }
        for step in plan.steps {
            if let value = step.arguments.values.first(where: { $0.contains(literal) || $0.range(of: literal, options: .caseInsensitive) != nil }) {
                return value
            }
        }
        return nil
    }

    // MARK: Structural-only repair (bounded, semantic-preserving)

    /// Deterministic STRUCTURAL repair of the observed 0.5B malformed shapes.
    /// This is the code-level answer to the Experiment-B failure mode: instead
    /// of sending malformed output back to the model (where repair
    /// contamination replaced user literals with prompt-example text), the
    /// pipeline repairs the SHAPE deterministically and never re-asks.
    ///
    /// Repair 1 — the split run_shell shape:
    ///   {"command": "echo", "args": "hello world"}   (args: string or [..])
    ///   → re-joins the model's OWN verb with the model's OWN args. The user
    ///     content is the model's extracted content, byte-for-byte; nothing
    ///     new is invented (no "hello", no "example").
    ///
    /// Repair 2 — single-element array value for a scalar argument:
    ///   {"tool": "web_search", "arguments": {"query": ["capital of France"]}}
    ///   → unwraps the scalar the model wrapped in a list.
    ///
    /// Returns nil when the shape is not one of the bounded repairable forms —
    /// callers then fall back to the legacy whole-plan prompt. No other
    /// repair exists, and no repair ever rewrites user content.
    static func structuralRepair(_ raw: String) -> ExtractedAction? {
        let bounded = String(raw.prefix(maxExtractionOutputCharacters))
        guard let start = bounded.firstIndex(of: "{"),
              let end = bounded.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonText = String(bounded[start...end])
        guard let data = jsonText.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any] else { return nil }
        let literal = object["literal"] as? String

        // Repair 1a: split run_shell shape INSIDE the arguments object —
        // {"tool": "run_shell", "arguments": {"command": "echo", "args": "x"}}
        // (the prompt-example failure documented in the task description).
        if let argsObject = object["arguments"] as? [String: Any],
           let command = argsObject["command"] as? String,
           argsObject["args"] != nil {
            let argsValue = argsObject["args"]!
            let argsText: String
            switch argsValue {
            case let s as String:
                argsText = s
            case let arr as [Any]:
                let parts: [String] = arr.compactMap { element in
                    if let s = element as? String { return s }
                    if let n = element as? NSNumber { return n.stringValue }
                    return nil
                }
                guard !parts.isEmpty else { return nil }
                argsText = parts.joined(separator: " ")
            default:
                return nil
            }
            let trimmedArgs = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedArgs.isEmpty else { return nil }
            let repairedCommand = "\(command.trimmingCharacters(in: .whitespacesAndNewlines)) \(trimmedArgs)"
            var repairedArguments = argsObject
            repairedArguments["command"] = repairedCommand
            repairedArguments.removeValue(forKey: "args")
            var stringArguments: [String: String] = [:]
            for (key, value) in repairedArguments {
                if let s = value as? String { stringArguments[key] = s }
                else if let n = value as? NSNumber { stringArguments[key] = n.stringValue }
                else { return nil }
            }
            // The model's args value IS the user payload: anchor it for the
            // preservation chain (overriding a missing/fabricated literal).
            return ExtractedAction(
                toolName: object["tool"] as? String ?? "run_shell",
                arguments: stringArguments,
                literal: literal ?? trimmedArgs)
        }

        // Repair 1b: bare arguments-object shape at the ROOT —
        // {"command": "echo", "args": "x"} (the Experiment-B replay form).
        if let command = object["command"] as? String, object["args"] != nil {
            let argsValue = object["args"]!
            let argsText: String
            switch argsValue {
            case let s as String:
                argsText = s
            case let arr as [Any]:
                let parts: [String] = arr.compactMap { element in
                    if let s = element as? String { return s }
                    if let n = element as? NSNumber { return n.stringValue }
                    return nil
                }
                guard !parts.isEmpty else { return nil }
                argsText = parts.joined(separator: " ")
            default:
                return nil
            }
            let trimmedArgs = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedArgs.isEmpty else { return nil }
            let repairedCommand = "\(command.trimmingCharacters(in: .whitespacesAndNewlines)) \(trimmedArgs)"
            return ExtractedAction(
                toolName: "run_shell",
                arguments: ["command": repairedCommand],
                literal: literal ?? trimmedArgs)
        }

        // Repair 2: single-element array values unwrapped to scalars.
        guard let toolName = object["tool"] as? String, !toolName.isEmpty,
              let args = object["arguments"] as? [String: Any] else { return nil }
        var repairedArgs: [String: String] = [:]
        for (key, value) in args {
            switch value {
            case let s as String:
                repairedArgs[key] = s
            case let n as NSNumber:
                repairedArgs[key] = n.stringValue
            case let arr as [Any] where arr.count == 1:
                if let s = arr[0] as? String {
                    repairedArgs[key] = s
                } else if let n = arr[0] as? NSNumber {
                    repairedArgs[key] = n.stringValue
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        guard !repairedArgs.isEmpty else { return nil }
        return ExtractedAction(toolName: toolName, arguments: repairedArgs, literal: literal)
    }

    // MARK: Recency guard (deterministic freshness safety net)

    /// Strong recency signals. A request containing any of these MUST NOT be
    /// answered from a model's stale training knowledge: it is forced onto the
    /// web/tool path. The bias is deliberately toward unnecessary lookup.
    static let recencySignals: [String] = [
        "current", "currently", "today", "today's", "todays", "latest",
        "right now", "as of", "this week", "this month", "this year",
        "now", "up to date", "up-to-date", "updated", "recent", "recently",
        "this morning", "yesterday"
    ]

    /// Deterministic recency check on the raw goal text. Short signals match
    /// on word boundaries ("now" must not match "know"); multi-word signals
    /// match as substrings.
    static func requiresFreshData(_ goal: String) -> Bool {
        let g = " \(goal.lowercased()) "
        for signal in recencySignals {
            if signal.contains(" ") {
                if g.contains(signal) { return true }
            } else {
                // Space-padded so "now" cannot match inside "know"/"known".
                if g.contains(" \(signal) ") { return true }
                // Punctuation-attached forms: "today," "today?" "today." etc.
                for terminator in [",", ".", "!", "?", "'s ", ":"] {
                    if g.contains(" \(signal)\(terminator)") { return true }
                }
                // Possessive: "today's" (signal + apostrophe-s at word end).
                if g.contains(" \(signal)'s ") || g.contains(" \(signal)'s,")
                    || g.contains(" \(signal)'s.") {
                    return true
                }
            }
        }
        return false
    }

    /// Deterministic recency enforcement on a VALIDATED plan (PART E).
    /// A recency-sensitive goal whose plan contains NO tool step would be
    /// answered from the model's stale knowledge by the direct composer —
    /// that is exactly the CASE 3 bypass. This compiler-level override
    /// replaces a composition-only plan for a recency goal with a real
    /// web_search step (query = the goal). Generic across all goals; the
    /// model never bypasses it because it runs after validation, in the
    /// deterministic compilation layer.
    static func enforceRecency(plan: AgentPlan, goal: String) -> AgentPlan {
        guard requiresFreshData(goal) else { return plan }
        let hasToolStep = plan.steps.contains { $0.toolName != nil }
        if hasToolStep { return plan }
        let step = PlanStep(
            id: "step_1",
            toolName: "web_search",
            arguments: ["query": goal],
            purpose: "recency-safe web lookup for a current-information request")
        return AgentPlan(goal: goal, steps: [step])
    }
}

// MARK: - Route attribution

/// Explicit, mandatory route attribution for every pipeline run (PART F).
/// Benchmark results and SelfTest assertions read this type: direct-answer
/// successes must never inflate planner statistics, and deterministic command
/// successes must never inflate planner statistics either.
enum PipelineRoute: String, Sendable, Equatable {
    /// L0 router fast path (0 model calls).
    case deterministic
    /// DirectAnswerRouter direct answer (0 planner calls).
    case directAnswer
    /// Typed DirectAnswerRouter refusal.
    case refusal
    /// Tier-A planner route (decomposed extraction or whole-plan prompt).
    case planner
    /// Tier-B / Tier-C escalation produced the plan.
    case escalation
}

/// CFBoolean type-ID helper (same rule as PlanValidator's normalization).
private func CFBooleanGetFalseType() -> CFTypeID {
    CFGetTypeID(false as NSNumber)
}
