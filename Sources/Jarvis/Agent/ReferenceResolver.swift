import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct ReferenceTokenMatch: Sendable, Equatable {
    let token: String
    let target: ReferenceTarget
}

enum TaskArgument: Sendable, Equatable {
    case literal(String)
    case reference(ReferenceTarget)
    case template(template: String, references: [ReferenceTokenMatch])
}

enum ReferenceTarget: Sendable, Equatable {
    case stepOutput(stepNumber: Int, field: String?)
    case ambient(AmbientSlot)
}

enum AmbientSlot: String, Sendable, Equatable, CaseIterable {
    case currentApp = "current_app"
    case currentFile = "current_file"
    case currentWebpage = "current_webpage"
    case currentSelection = "current_selection"
    case lastSearchResults = "last_search_results"
    case lastArtifact = "last_artifact"
    case pendingConfirmation = "pending_confirmation"
}

struct StepResolutionRecord: Sendable, Equatable, Codable {
    let stepNumber: Int
    let toolName: String
    let rawOutput: String
    let structuredOutput: [String: String]?
    let completedAt: Date
    let verification: VerificationOutcome

    init(stepNumber: Int, toolName: String, rawOutput: String,
         structuredOutput: [String: String]? = nil, completedAt: Date = Date(),
         verification: VerificationOutcome = .passed) {
        self.stepNumber = stepNumber
        self.toolName = toolName
        self.rawOutput = rawOutput
        self.structuredOutput = structuredOutput
        self.completedAt = completedAt
        self.verification = verification
    }
}

struct TaskEnvironmentContext: Sendable, Equatable, Codable {
    var currentApp: String?
    var currentFile: String?
    var currentWebpage: String?
    var currentSelection: String?
    var lastSearchResults: [String]?
    var lastArtifactPath: String?
    var pendingConfirmation: String?
    let snapshotTimestamp: Date

    init(currentApp: String? = nil, currentFile: String? = nil, currentWebpage: String? = nil,
         currentSelection: String? = nil, lastSearchResults: [String]? = nil,
         lastArtifactPath: String? = nil, pendingConfirmation: String? = nil,
         snapshotTimestamp: Date = Date()) {
        self.currentApp = currentApp
        self.currentFile = currentFile
        self.currentWebpage = currentWebpage
        self.currentSelection = currentSelection
        self.lastSearchResults = lastSearchResults
        self.lastArtifactPath = lastArtifactPath
        self.pendingConfirmation = pendingConfirmation
        self.snapshotTimestamp = snapshotTimestamp
    }

    static func captureLive() -> TaskEnvironmentContext {
        #if canImport(AppKit)
        return TaskEnvironmentContext(currentApp: NSWorkspace.shared.frontmostApplication?.localizedName)
        #else
        return TaskEnvironmentContext()
        #endif
    }

    static let maxVolatileAgeSeconds: Double = 300
}

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
        case .malformedReference(let token, let reason): return "Malformed reference '\(token)': \(reason)"
        case .forwardReference(let referenced, let current): return "Step \(current) cannot reference future Step \(referenced)"
        case .selfReference(let step): return "Step \(step) cannot reference its own output"
        case .missingStepOutput(let step): return "Step \(step) has not produced an output record"
        case .unverifiedStep(let step, let outcome): return "Step \(step) is not verified (\(outcome))"
        case .fieldExtractionFailed(let step, let field, let reason): return "Cannot extract Step \(step) field '\(field)': \(reason)"
        case .ambientSlotUnavailable(let slot): return "Ambient state slot '\(slot.rawValue)' is unavailable"
        case .staleAmbientSlot(let slot, let age): return "Ambient state slot '\(slot.rawValue)' is stale (\(String(format: "%.1f", age))s)"
        case .typeMismatch(let argument, let expected, let actual): return "Argument '\(argument)' expects \(expected), got '\(actual)'"
        }
    }
}

enum ReferenceResolver {
    enum CrossTurnFileReference: Sendable, Equatable {
        case notApplicable, unavailable, ambiguous, resolved(path: String)
    }
    enum CrossTurnCommandReference: Sendable, Equatable {
        case notApplicable, unavailable, ambiguous, resolved(command: String)
    }
    enum CrossTurnURLReference: Sendable, Equatable {
        case notApplicable, unavailable, ambiguous, resolved(url: String)
    }

    static func parseArgument(_ value: String) throws -> TaskArgument {
        if (value.hasPrefix("$step") || value.hasPrefix("$ambient")) && !value.contains(" ") {
            return .reference(try parseReferenceTarget(value))
        }
        guard value.contains("$step") || value.contains("$ambient") else { return .literal(value) }
        var matches: [ReferenceTokenMatch] = []
        var remaining = value[...]
        while let dollar = remaining.range(of: "$") {
            let candidate = remaining[dollar.lowerBound...]
            guard candidate.hasPrefix("$step") || candidate.hasPrefix("$ambient") else {
                remaining = remaining[dollar.upperBound...]
                continue
            }
            var end = candidate.startIndex
            while end < candidate.endIndex {
                let character = candidate[end]
                if character.isWhitespace || ["\"", "'", ";", ")", "}"].contains(character) { break }
                end = candidate.index(after: end)
            }
            let token = String(candidate[..<end])
            matches.append(ReferenceTokenMatch(token: token, target: try parseReferenceTarget(token)))
            remaining = candidate[end...]
        }
        guard !matches.isEmpty else { return .literal(value) }
        if matches.count == 1, matches[0].token == value { return .reference(matches[0].target) }
        return .template(template: value, references: matches)
    }

    static func parseReferenceTarget(_ token: String) throws -> ReferenceTarget {
        if token.hasPrefix("$step.") {
            let parts = token.dropFirst("$step.".count).split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let first = parts.first,
                  !first.isEmpty, let step = Int(first), step > 0 else {
                throw ReferenceResolutionError.malformedReference(token, reason: "Expected $step.<N>[.<field>]")
            }
            guard parts.count == 2 else { return .stepOutput(stepNumber: step, field: nil) }
            let field = String(parts[1])
            guard !field.isEmpty else { throw ReferenceResolutionError.malformedReference(token, reason: "Field cannot be empty") }
            return .stepOutput(stepNumber: step, field: field == "output" ? nil : field)
        }
        if token.hasPrefix("$ambient.") {
            let name = String(token.dropFirst("$ambient.".count))
            guard let slot = AmbientSlot(rawValue: name) else {
                throw ReferenceResolutionError.malformedReference(token, reason: "Unknown ambient slot '\(name)'")
            }
            return .ambient(slot)
        }
        throw ReferenceResolutionError.malformedReference(token, reason: "References must start with $step. or $ambient.")
    }

    static func validateReference(_ target: ReferenceTarget, currentStepNumber: Int) throws {
        guard case .stepOutput(let step, _) = target else { return }
        if step == currentStepNumber { throw ReferenceResolutionError.selfReference(stepNumber: step) }
        if step > currentStepNumber { throw ReferenceResolutionError.forwardReference(referencedStep: step, currentStep: currentStepNumber) }
    }

    static func validateArgument(_ argument: TaskArgument, currentStepNumber: Int) throws {
        switch argument {
        case .literal:
            return
        case .reference(let target):
            try validateReference(target, currentStepNumber: currentStepNumber)
        case .template(_, let references):
            for reference in references {
                try validateReference(reference.target, currentStepNumber: currentStepNumber)
            }
        }
    }

    static func resolveTarget(target: ReferenceTarget, currentStepNumber: Int,
                              resolutionRecords: [Int: StepResolutionRecord],
                              environmentContext: TaskEnvironmentContext?) throws -> String {
        try validateReference(target, currentStepNumber: currentStepNumber)
        switch target {
        case .stepOutput(let step, let field):
            guard let record = resolutionRecords[step], record.stepNumber == step else {
                throw ReferenceResolutionError.missingStepOutput(stepNumber: step)
            }
            guard record.verification == .passed else {
                throw ReferenceResolutionError.unverifiedStep(stepNumber: step, outcome: record.verification.rawValue)
            }
            guard let field else { return record.rawOutput }
            if let value = record.structuredOutput?[field] { return value }
            guard let data = record.rawOutput.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json[field] else {
                throw ReferenceResolutionError.fieldExtractionFailed(stepNumber: step, field: field,
                                                                     reason: "Output is not JSON containing that field")
            }
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            throw ReferenceResolutionError.fieldExtractionFailed(stepNumber: step, field: field,
                                                                 reason: "Field is not scalar")
        case .ambient(let slot):
            guard let environmentContext else { throw ReferenceResolutionError.ambientSlotUnavailable(slot) }
            let age = Date().timeIntervalSince(environmentContext.snapshotTimestamp)
            guard age >= 0, age <= TaskEnvironmentContext.maxVolatileAgeSeconds else {
                throw ReferenceResolutionError.staleAmbientSlot(slot, ageSeconds: age)
            }
            let value: String?
            switch slot {
            case .currentApp: value = environmentContext.currentApp
            case .currentFile: value = environmentContext.currentFile
            case .currentWebpage: value = environmentContext.currentWebpage
            case .currentSelection: value = environmentContext.currentSelection
            case .lastSearchResults: value = environmentContext.lastSearchResults?.joined(separator: "\n")
            case .lastArtifact: value = environmentContext.lastArtifactPath
            case .pendingConfirmation: value = environmentContext.pendingConfirmation
            }
            guard let value, !value.isEmpty else { throw ReferenceResolutionError.ambientSlotUnavailable(slot) }
            return value
        }
    }

    static func resolveValue(argument: TaskArgument, currentStepNumber: Int,
                             resolutionRecords: [Int: StepResolutionRecord],
                             environmentContext: TaskEnvironmentContext?) throws -> String {
        switch argument {
        case .literal(let value): return value
        case .reference(let target):
            return try resolveTarget(target: target, currentStepNumber: currentStepNumber,
                                     resolutionRecords: resolutionRecords, environmentContext: environmentContext)
        case .template(let template, let references):
            return try references.reduce(template) { result, match in
                let value = try resolveTarget(target: match.target, currentStepNumber: currentStepNumber,
                                              resolutionRecords: resolutionRecords, environmentContext: environmentContext)
                return result.replacingOccurrences(of: match.token, with: value)
            }
        }
    }

    static func resolveStepArguments(rawArguments: [String: String], currentStepNumber: Int,
                                     toolParameterSpecs: [ToolParameterSpec],
                                     resolutionRecords: [Int: StepResolutionRecord],
                                     environmentContext: TaskEnvironmentContext?) throws -> [String: any Sendable] {
        let specs = Dictionary(uniqueKeysWithValues: toolParameterSpecs.map { ($0.name, $0) })
        var result: [String: any Sendable] = [:]
        for (name, rawValue) in rawArguments {
            let value = try resolveValue(argument: parseArgument(rawValue), currentStepNumber: currentStepNumber,
                                         resolutionRecords: resolutionRecords, environmentContext: environmentContext)
            if let spec = specs[name], spec.kind == .int {
                guard let integer = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw ReferenceResolutionError.typeMismatch(argument: name, expected: "an integer", actual: value)
                }
                result[name] = integer
            } else { result[name] = value }
        }
        return result
    }

    static func resolveCrossTurnCommandReference(goal: String, tasks: [JarvisTask],
                                                  now: Date = .now, maxAge: TimeInterval = 15 * 60) -> CrossTurnCommandReference {
        let phrases: Set<String> = ["run that command", "run that command again", "run that again", "run the command",
                                    "run the command again", "execute that command", "execute that again",
                                    "execute the command", "execute the command again", "rerun that command",
                                    "rerun the command", "run the last command", "execute the last command"]
        guard phrases.contains(normalize(goal)) else { return .notApplicable }
          let latest = latestTasks(tasks, action: { $0.toolName == "run_shell" }, now: now, maxAge: maxAge)
          guard !latest.isEmpty else { return .unavailable }
          // Equal-timestamp independent tasks have no deterministic "latest"
          // task, so fail closed (unavailable) rather than expose an arbitrary
          // collection-order winner. Per-task multiple-step ambiguity is handled
          // below and still surfaces as .ambiguous.
          guard latest.count == 1, let task = latest.first else { return .unavailable }
          guard task.state == .completed else { return .unavailable }
        let steps = task.steps.filter { $0.toolName == "run_shell" }
        guard steps.count == 1 else { return steps.isEmpty ? .unavailable : .ambiguous }
          let verified = steps.filter { TaskContinuity.independentlyVerified($0, task: task) }
        guard verified.count == 1, let step = verified.first,
              let command = step.arguments["command"], !command.isEmpty,
              !command.contains("\n"), !command.contains("\r") else { return .unavailable }
        return .resolved(command: command)
    }

    static func resolveCrossTurnURLReference(goal: String, tasks: [JarvisTask],
                                              now: Date = .now, maxAge: TimeInterval = 15 * 60) -> CrossTurnURLReference {
        let phrases: Set<String> = ["fetch that url", "fetch that", "fetch the url", "download that url", "download that",
                                    "go back to that webpage", "go back to that page", "return to that webpage",
                                    "open that webpage", "open that page", "visit that webpage", "open the webpage",
                                    "fetch that website", "download the url"]
        guard phrases.contains(normalize(goal)) else { return .notApplicable }
        let latest = latestTasks(tasks, action: { $0.toolName == "fetch_url" || $0.toolName == "open_browser" },
                     now: now, maxAge: maxAge)
        guard !latest.isEmpty else { return .unavailable }
        guard latest.count == 1, let task = latest.first else { return .unavailable }
        guard task.state == .completed else { return .unavailable }
        let steps = task.steps.filter { $0.toolName == "fetch_url" || $0.toolName == "open_browser" }
        guard steps.count == 1 else { return steps.isEmpty ? .unavailable : .ambiguous }
        let verified = steps.filter { TaskContinuity.independentlyVerified($0, task: task) }
        guard verified.count == 1, let step = verified.first,
              let url = step.arguments["url"], let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { return .unavailable }
        return .resolved(url: url)
    }

    static func resolveCrossTurnFileReference(goal: String, tasks: [JarvisTask], now: Date = .now,
                                              maxAge: TimeInterval = 15 * 60,
                                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CrossTurnFileReference {
        let phrases: Set<String> = ["open that file", "read that file", "show that file", "open the file you created",
                                    "read the file you created", "open the file you just created", "read the file you just created",
                                    "open the file from earlier", "read the file from earlier"]
        guard phrases.contains(normalize(goal)) else { return .notApplicable }
          let latest = latestTasks(tasks, action: { $0.toolName == "write_file" }, now: now, maxAge: maxAge)
          guard !latest.isEmpty else { return .unavailable }
          guard latest.count == 1, let task = latest.first else { return .unavailable }
          guard task.state == .completed else { return .unavailable }
        var paths = Set<String>()
        for step in task.steps where step.toolName == "write_file" && TaskContinuity.independentlyVerified(step, task: task) {
            guard let path = step.arguments["path"], !path.isEmpty, !path.contains("\n"), !path.contains("\r"),
                  !path.contains("\""), !path.contains("'"), fileExists(path) else { continue }
            paths.insert(path)
        }
        guard paths.count == 1, let path = paths.first else { return paths.isEmpty ? .unavailable : .ambiguous }
        return .resolved(path: path)
    }

    private static func normalize(_ goal: String) -> String {
        var result = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = result.last, ".?!".contains(last) { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Select the latest authoritative task among recent candidates.
    ///
    /// Freshness contract: a candidate is recent when its evidence timestamp
    /// (`completedAt ?? updatedAt`) falls inside the allowed freshness window
    /// `[now - maxAge, now + skew]`. The upper bound only tolerates minor clock
    /// skew so that future-dated synthetic/task-state snapshots are not silently
    /// discarded; genuinely future evidence is not selectable.
    /// The newest timestamp wins; ties are ambiguous and must fail closed.
    private static func latestTasks(_ tasks: [JarvisTask], action: (TaskStep) -> Bool,
                                    now: Date, maxAge: TimeInterval) -> [JarvisTask] {
        let skewTolerance: TimeInterval = 5
        let cutoff = now.addingTimeInterval(-maxAge)
        let recent = tasks.filter { task in
            let date = task.completedAt ?? task.updatedAt
            return date >= cutoff && date <= now.addingTimeInterval(skewTolerance)
                && task.steps.contains(where: action)
        }
        guard let latest = recent.map({ $0.completedAt ?? $0.updatedAt }).max() else { return [] }
        let matches = recent.filter { ($0.completedAt ?? $0.updatedAt) == latest }
        return matches
    }
}