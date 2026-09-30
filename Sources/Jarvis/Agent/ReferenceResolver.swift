import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Match of a reference token inside a template argument.
struct ReferenceTokenMatch: Sendable, Equatable {
    let token: String
    let target: ReferenceTarget
}

/// Strongly typed task argument representing either a literal string, a direct reference,
/// or a template with embedded references.
enum TaskArgument: Sendable, Equatable {
    case literal(String)
    case reference(ReferenceTarget)
    case template(template: String, references: [ReferenceTokenMatch])
}

/// Target of a deterministic reference.
enum ReferenceTarget: Sendable, Equatable {
    /// Reference to a prior step output.
    /// Example: $step.1.output, $step.1.url, $step.1
    case stepOutput(stepNumber: Int, field: String?)

    /// Reference to an ambient environment slot.
    /// Example: $ambient.current_app
    case ambient(AmbientSlot)
}

/// Supported ambient slots in Jarvis.
enum AmbientSlot: String, Sendable, Equatable, CaseIterable {
    case currentApp = "current_app"
    case currentFile = "current_file"
    case currentWebpage = "current_webpage"
    case currentSelection = "current_selection"
    case lastSearchResults = "last_search_results"
    case lastArtifact = "last_artifact"
    case pendingConfirmation = "pending_confirmation"
}

/// Structured record of a completed and verified step execution for reference resolution.
struct StepResolutionRecord: Sendable, Equatable {
    let stepNumber: Int
    let toolName: String
    let rawOutput: String
    let structuredOutput: [String: String]?
    let completedAt: Date
    let verification: VerificationOutcome

    init(
        stepNumber: Int,
        toolName: String,
        rawOutput: String,
        structuredOutput: [String: String]? = nil,
        completedAt: Date = Date(),
        verification: VerificationOutcome = .passed
    ) {
        self.stepNumber = stepNumber
        self.toolName = toolName
        self.rawOutput = rawOutput
        self.structuredOutput = structuredOutput
        self.completedAt = completedAt
        self.verification = verification
    }
}

/// Ambient environment context snapshot for a task.
struct TaskEnvironmentContext: Sendable, Equatable {
    var currentApp: String?
    var currentFile: String?
    var currentWebpage: String?
    var currentSelection: String?
    var lastSearchResults: [String]?
    var lastArtifactPath: String?
    var pendingConfirmation: String?
    let snapshotTimestamp: Date

    init(
        currentApp: String? = nil,
        currentFile: String? = nil,
        currentWebpage: String? = nil,
        currentSelection: String? = nil,
        lastSearchResults: [String]? = nil,
        lastArtifactPath: String? = nil,
        pendingConfirmation: String? = nil,
        snapshotTimestamp: Date = Date()
    ) {
        self.currentApp = currentApp
        self.currentFile = currentFile
        self.currentWebpage = currentWebpage
        self.currentSelection = currentSelection
        self.lastSearchResults = lastSearchResults
        self.lastArtifactPath = lastArtifactPath
        self.pendingConfirmation = pendingConfirmation
        self.snapshotTimestamp = snapshotTimestamp
    }

    /// Capture authoritative live system context (e.g. frontmost application via NSWorkspace).
    static func captureLive() -> TaskEnvironmentContext {
        var appName: String?
        #if canImport(AppKit)
        appName = NSWorkspace.shared.frontmostApplication?.localizedName
        #endif
        return TaskEnvironmentContext(currentApp: appName, snapshotTimestamp: Date())
    }

    /// Maximum age allowed for volatile ambient slots (e.g. currentApp) before being considered stale.
    static let maxVolatileAgeSeconds: Double = 300.0 // 5 minutes
}

/// Deterministic errors emitted during reference parsing, validation, or resolution.
enum ReferenceResolutionError: Error, Sendable, Equatable, LocalizedError {
    case malformedReference(String, reason: String)
    case forwardReference(referencedStep: Int, currentStep: Int)
    case selfReference(stepNumber: Int)
    case missingStepOutput(stepNumber: Int)
    case unverifiedStep(stepNumber: Int, outcome: String)
    case fieldExtractionFailed(stepNumber: Int, field: String, reason: String)
    case ambientSlotUnavailable(AmbientSlot)
    case staleAmbientSlot(AmbientSlot, ageSeconds: Double)
    case typeMismatch(argument: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .malformedReference(let token, let reason):
            return "Malformed reference '\(token)': \(reason)"
        case .forwardReference(let refStep, let curStep):
            return "Forward reference error: Step \(curStep) cannot reference future Step \(refStep)"
        case .selfReference(let step):
            return "Self-reference error: Step \(step) cannot reference its own output"
        case .missingStepOutput(let step):
            return "Missing step output: Step \(step) has not produced an output record"
        case .unverifiedStep(let step, let outcome):
            return "Unverified step output: Step \(step) ended with verification outcome '\(outcome)'"
        case .fieldExtractionFailed(let step, let field, let reason):
            return "Field extraction failed for Step \(step) field '\(field)': \(reason)"
        case .ambientSlotUnavailable(let slot):
            return "Ambient state slot '\(slot.rawValue)' is currently unavailable"
        case .staleAmbientSlot(let slot, let age):
            return "Ambient state slot '\(slot.rawValue)' is stale (\(String(format: "%.1f", age))s old)"
        case .typeMismatch(let arg, let expected, let actual):
            return "Type mismatch for argument '\(arg)': expected \(expected), resolved '\(actual)'"
        }
    }
}

/// Deterministic parser and resolver for task references.
enum ReferenceResolver {

    enum CrossTurnFileReference: Sendable, Equatable {
        case notApplicable
        case unavailable
        case ambiguous
        case resolved(path: String)
    }

    /// Resolve a small set of file anaphora using only completed TaskState
    /// writes with matching passed resolution evidence. Conversation and user
    /// memory are never read here. The resulting path is passed back through
    /// the existing `$ambient.last_artifact` resolver before it is returned.
    static func resolveCrossTurnFileReference(
        goal: String,
        tasks: [JarvisTask],
        now: Date = .now,
        maxAge: TimeInterval = 15 * 60,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> CrossTurnFileReference {
        var normalized = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = normalized.last, ".?!".contains(last) { normalized.removeLast() }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileFollowUps: Set<String> = [
            "open that file", "read that file", "show that file",
            "open the file you created", "read the file you created",
            "open the file you just created", "read the file you just created",
            "open the file from earlier", "read the file from earlier"
        ]
        guard fileFollowUps.contains(normalized) else { return .notApplicable }

        let cutoff = now.addingTimeInterval(-maxAge)
        // A bare anaphor such as "that file" is grounded in the latest task
        // that actually attempted a file write, not an arbitrary set of old
        // outputs. A newer failed/unverified write is a barrier: never fall
        // back to an older file and pretend it was the one just created.
        let recentWriteTasks = tasks
            .filter({ task in
                (task.completedAt ?? task.updatedAt) >= cutoff
                    && task.steps.contains(where: { $0.toolName == "write_file" })
            })
        guard let latestWriteTimestamp = recentWriteTasks
            .map({ $0.completedAt ?? $0.updatedAt }).max() else { return .unavailable }
        let latestWriteTasks = recentWriteTasks.filter {
            ($0.completedAt ?? $0.updatedAt) == latestWriteTimestamp
        }
        // Concurrent/same-timestamp writes have no deterministic recency order.
        // Do not let collection iteration order decide which task "that file" means.
        guard latestWriteTasks.count == 1,
              let latestWriteTask = latestWriteTasks.first,
              latestWriteTask.state == .completed else { return .unavailable }

        var paths = Set<String>()
        for step in latestWriteTask.steps where step.state == .completed
            && step.verification == .passed
            && step.toolName == "write_file" {
            guard let path = step.arguments["path"], !path.isEmpty,
                  !path.contains("\n"), !path.contains("\r"),
                  !path.contains("\""), !path.contains("'"),
                  latestWriteTask.resolutionRecords.contains(where: {
                      $0.stepNumber == step.stepNumber
                          && $0.toolName == "write_file"
                          && $0.verification == .passed
                  }),
                  fileExists(path) else { continue }
            paths.insert(path)
        }

        guard !paths.isEmpty else { return .unavailable }
        guard paths.count == 1, let path = paths.first else { return .ambiguous }

        do {
            let resolved = try resolveTarget(
                target: .ambient(.lastArtifact),
                currentStepNumber: 1,
                resolutionRecords: [:],
                environmentContext: TaskEnvironmentContext(lastArtifactPath: path, snapshotTimestamp: now))
            return .resolved(path: resolved)
        } catch {
            return .unavailable
        }
    }

    // MARK: - Parsing

    /// Parse an argument string into a TaskArgument.
    /// If the string is a pure reference (e.g. "$step.1.output", "$ambient.current_app"), returns .reference.
    /// If the string contains embedded reference tokens (e.g. "echo $step.1.output", "cat $step.1.output"),
    /// all tokens are extracted and validated; returns .template.
    /// If an invalid reference syntax is detected anywhere, throws ReferenceResolutionError.
    /// All other strings remain .literal.
    static func parseArgument(_ value: String) throws -> TaskArgument {
        // If it starts with $step or $ambient and has no spaces/delimiters, it's a direct reference candidate
        if (value.hasPrefix("$step") || value.hasPrefix("$ambient")) && !value.contains(" ") {
            let target = try parseReferenceTarget(value)
            return .reference(target)
        }

        // Check if there are any candidate reference tokens in the string
        guard value.contains("$step") || value.contains("$ambient") else {
            return .literal(value)
        }

        // Scan for reference tokens: tokens starting with $step or $ambient
        var matches: [ReferenceTokenMatch] = []
        var remaining = value[...]

        while let dollarRange = remaining.range(of: "$") {
            let candidateStart = dollarRange.lowerBound
            let candidateRemainder = remaining[candidateStart...]

            if candidateRemainder.hasPrefix("$step") || candidateRemainder.hasPrefix("$ambient") {
                // Find token end (space, quote, semicolon, or end of string)
                var tokenEnd = candidateRemainder.startIndex
                while tokenEnd < candidateRemainder.endIndex {
                    let c = candidateRemainder[tokenEnd]
                    if c.isWhitespace || c == "\"" || c == "'" || c == ";" || c == "\n" || c == ")" || c == "}" {
                        break
                    }
                    tokenEnd = candidateRemainder.index(after: tokenEnd)
                }
                let token = String(candidateRemainder[candidateRemainder.startIndex..<tokenEnd])
                let target = try parseReferenceTarget(token)
                matches.append(ReferenceTokenMatch(token: token, target: target))
                remaining = candidateRemainder[tokenEnd...]
            } else {
                remaining = remaining[dollarRange.upperBound...]
            }
        }

        if matches.isEmpty {
            return .literal(value)
        }

        if matches.count == 1 && matches[0].token == value {
            return .reference(matches[0].target)
        }

        return .template(template: value, references: matches)
    }

    /// Parse a strict reference target token.
    static func parseReferenceTarget(_ token: String) throws -> ReferenceTarget {
        if token.hasPrefix("$step.") {
            let remainder = String(token.dropFirst("$step.".count))
            let parts = remainder.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 1 && parts.count <= 2 else {
                throw ReferenceResolutionError.malformedReference(token, reason: "Expected $step.<N> or $step.<N>.<field>")
            }
            guard !parts[0].isEmpty, let stepNum = Int(parts[0]), stepNum > 0 else {
                throw ReferenceResolutionError.malformedReference(token, reason: "Step number must be a positive integer > 0")
            }
            if parts.count == 1 {
                return .stepOutput(stepNumber: stepNum, field: nil)
            }
            let fieldPart = String(parts[1])
            guard !fieldPart.isEmpty else {
                throw ReferenceResolutionError.malformedReference(token, reason: "Field name cannot be empty")
            }
            if fieldPart == "output" {
                return .stepOutput(stepNumber: stepNum, field: nil)
            }
            return .stepOutput(stepNumber: stepNum, field: fieldPart)
        } else if token.hasPrefix("$ambient.") {
            let slotName = String(token.dropFirst("$ambient.".count))
            guard let slot = AmbientSlot(rawValue: slotName) else {
                throw ReferenceResolutionError.malformedReference(token, reason: "Unknown ambient slot '\(slotName)'")
            }
            return .ambient(slot)
        } else {
            throw ReferenceResolutionError.malformedReference(token, reason: "References must start with $step. or $ambient.")
        }
    }

    // MARK: - Validation

    /// Validate structural constraints of a TaskArgument against a current step number.
    static func validateArgument(
        _ argument: TaskArgument,
        currentStepNumber: Int
    ) throws {
        switch argument {
        case .literal:
            break
        case .reference(let target):
            try validateReference(target, currentStepNumber: currentStepNumber)
        case .template(_, let references):
            for match in references {
                try validateReference(match.target, currentStepNumber: currentStepNumber)
            }
        }
    }

    /// Validate structural constraints of a reference against a current step number.
    /// Enforces M < currentStepNumber.
    static func validateReference(
        _ target: ReferenceTarget,
        currentStepNumber: Int
    ) throws {
        switch target {
        case .stepOutput(let stepNumber, _):
            if stepNumber == currentStepNumber {
                throw ReferenceResolutionError.selfReference(stepNumber: stepNumber)
            }
            if stepNumber > currentStepNumber {
                throw ReferenceResolutionError.forwardReference(referencedStep: stepNumber, currentStep: currentStepNumber)
            }
        case .ambient:
            break
        }
    }

    // MARK: - Resolution

    /// Resolve a reference target to a concrete string value.
    static func resolveTarget(
        target: ReferenceTarget,
        currentStepNumber: Int,
        resolutionRecords: [Int: StepResolutionRecord],
        environmentContext: TaskEnvironmentContext?
    ) throws -> String {
        try validateReference(target, currentStepNumber: currentStepNumber)

        switch target {
        case .stepOutput(let stepNumber, let field):
            guard let record = resolutionRecords[stepNumber] else {
                throw ReferenceResolutionError.missingStepOutput(stepNumber: stepNumber)
            }

            guard record.verification == .passed else {
                throw ReferenceResolutionError.unverifiedStep(stepNumber: stepNumber, outcome: "\(record.verification)")
            }

            if let field = field {
                // 1. Check pre-extracted structuredOutput
                if let preExtracted = record.structuredOutput?[field] {
                    return preExtracted
                }
                // 2. Parse rawOutput as JSON dictionary
                guard let data = record.rawOutput.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ReferenceResolutionError.fieldExtractionFailed(
                        stepNumber: stepNumber,
                        field: field,
                        reason: "Step output is not a JSON object"
                    )
                }
                guard let val = json[field] else {
                    throw ReferenceResolutionError.fieldExtractionFailed(
                        stepNumber: stepNumber,
                        field: field,
                        reason: "JSON does not contain field '\(field)'"
                    )
                }
                if let str = val as? String {
                    return str
                } else if let num = val as? NSNumber {
                    return num.stringValue
                } else {
                    return String(describing: val)
                }
            } else {
                return record.rawOutput
            }

        case .ambient(let slot):
            guard let env = environmentContext else {
                throw ReferenceResolutionError.ambientSlotUnavailable(slot)
            }
            switch slot {
            case .currentApp:
                guard let app = env.currentApp, !app.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                let age = Date().timeIntervalSince(env.snapshotTimestamp)
                if age > TaskEnvironmentContext.maxVolatileAgeSeconds {
                    throw ReferenceResolutionError.staleAmbientSlot(slot, ageSeconds: age)
                }
                return app
            case .currentFile:
                guard let file = env.currentFile, !file.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                return file
            case .currentWebpage:
                guard let page = env.currentWebpage, !page.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                return page
            case .currentSelection:
                guard let sel = env.currentSelection, !sel.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                return sel
            case .lastSearchResults:
                guard let results = env.lastSearchResults, !results.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                return results.joined(separator: "\n")
            case .lastArtifact:
                guard let art = env.lastArtifactPath, !art.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                return art
            case .pendingConfirmation:
                guard let conf = env.pendingConfirmation, !conf.isEmpty else {
                    throw ReferenceResolutionError.ambientSlotUnavailable(slot)
                }
                return conf
            }
        }
    }

    /// Resolve a single TaskArgument to a concrete string value.
    static func resolveValue(
        argument: TaskArgument,
        currentStepNumber: Int,
        resolutionRecords: [Int: StepResolutionRecord],
        environmentContext: TaskEnvironmentContext?
    ) throws -> String {
        switch argument {
        case .literal(let val):
            return val

        case .reference(let target):
            return try resolveTarget(
                target: target,
                currentStepNumber: currentStepNumber,
                resolutionRecords: resolutionRecords,
                environmentContext: environmentContext
            )

        case .template(let template, let references):
            var result = template
            for match in references {
                let resolvedTargetValue = try resolveTarget(
                    target: match.target,
                    currentStepNumber: currentStepNumber,
                    resolutionRecords: resolutionRecords,
                    environmentContext: environmentContext
                )
                result = result.replacingOccurrences(of: match.token, with: resolvedTargetValue)
            }
            return result
        }
    }

    /// Resolve an entire dictionary of arguments for a step, performing type adaptation
    /// for parameters declared as .int in tool parameter specs.
    static func resolveStepArguments(
        rawArguments: [String: String],
        currentStepNumber: Int,
        toolParameterSpecs: [ToolParameterSpec],
        resolutionRecords: [Int: StepResolutionRecord],
        environmentContext: TaskEnvironmentContext?
    ) throws -> [String: any Sendable] {
        let specMap = Dictionary(uniqueKeysWithValues: toolParameterSpecs.map { ($0.name, $0) })
        var resolved: [String: any Sendable] = [:]

        for (argName, rawValue) in rawArguments {
            let taskArg = try parseArgument(rawValue)
            let concreteStr = try resolveValue(
                argument: taskArg,
                currentStepNumber: currentStepNumber,
                resolutionRecords: resolutionRecords,
                environmentContext: environmentContext
            )

            if let spec = specMap[argName], spec.kind == .int {
                let trimmed = concreteStr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let intVal = Int(trimmed) else {
                    throw ReferenceResolutionError.typeMismatch(
                        argument: argName,
                        expected: "an integer",
                        actual: concreteStr
                    )
                }
                resolved[argName] = intVal
            } else {
                resolved[argName] = concreteStr
            }
        }

        return resolved
    }
}
