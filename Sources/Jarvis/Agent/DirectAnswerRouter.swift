import Foundation

public final class DirectAnswerRouter: @unchecked Sendable {
    public static let shared = DirectAnswerRouter()

    enum RefusalReason: String, Sendable, Equatable {
        case unsupportedCapability, unsafeRequest, malformedRequest
        case unresolvedReference, unresolvedFileReference, unresolvedURLReference
        case unresolvedCommandReference, unresolvedSearchReference
        case unresolvedWriteReference, unresolvedVolumeReference

        var userFacingMessage: String {
            switch self {
            case .unsupportedCapability: return "I don't have a tool for that request, and I won't substitute an unrelated action."
            case .unsafeRequest: return "That request is unsafe or destructive, so I won't act on it."
            case .malformedRequest: return "The request was empty or malformed, so there is nothing to act on."
            case .unresolvedReference: return "Which app would you like me to open? Please specify its name."
            case .unresolvedFileReference: return "Which file would you like me to read? Please specify its path."
            case .unresolvedURLReference: return "Which URL would you like me to fetch? Please provide the URL."
            case .unresolvedCommandReference: return "Which command would you like me to run? Please specify it."
            case .unresolvedSearchReference: return "What would you like me to search for? Please specify the query."
            case .unresolvedWriteReference: return "What content and file path would you like to write? Please specify both."
            case .unresolvedVolumeReference: return "What volume level would you like to set? Please specify a level."
            }
        }
    }

    enum InformationSource: Sendable, Equatable {
        case conversationHistory, userMemory, developmentHistory
    }

    enum Decision: Sendable, Equatable {
        case directAnswer
        case activitySummary
        case verifiedArtifactSummary
        case verifiedArtifactStatus
        case taskContinuity(TaskContinuity.Query)
        case informationAnswer(InformationSource)
        case refusal(RefusalReason)
        case planner
    }

    private static let directQueries: Set<String> = [
        "time", "what time is it", "current time",
        "date", "what is today's date", "what date is it",
        "who are you", "what is your name", "version"
    ]

    private static let mathRegex = try! NSRegularExpression(pattern: "^[0-9\\.\\+\\-\\*/\\(\\)\\s]+$", options: [])

    public init() {}

    public func evaluateDirectAnswer(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if Self.directQueries.contains(lower) {
            if lower.contains("time") {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                return "The current time is \(formatter.string(from: Date()))."
            }
            if lower.contains("date") {
                let formatter = DateFormatter()
                formatter.dateStyle = .full
                return "Today is \(formatter.string(from: Date()))."
            }
            if lower.contains("who") || lower.contains("name") {
                return "I am Jarvis, your ultra-fast desktop assistant."
            }
            if lower.contains("version") {
                return "Jarvis v1.0.0 (Gemini 3.6 Flash Fast Mode)."
            }
        }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if trimmed.count > 2 && Self.mathRegex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
            let expr = NSExpression(format: trimmed)
            if let result = expr.expressionValue(with: nil, context: nil) as? NSNumber {
                return "Result: \(result)"
            }
        }

        return nil
    }

    static func requiresFreshData(_ goal: String) -> Bool {
        PlannerExtraction.requiresFreshData(goal)
    }

    static func decide(goal rawGoal: String) -> Decision {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return .refusal(.malformedRequest) }
        let lower = goal.lowercased()
        let normalized = normalize(goal)

        if let source = informationSource(for: normalized) { return .informationAnswer(source) }
        if ["is the file you created still there", "is the file you just created still there",
            "does the file you created still exist", "is that file still there"].contains(normalized) {
            return .verifiedArtifactStatus
        }
        if ["what happened when you tried writing that file", "what happened when you tried to write that file",
            "what happened when you tried creating that file"].contains(normalized) || normalized == "what happened" {
            return .activitySummary
        }
        if ["what did you do a few minutes ago", "what did you do recently", "what did you just do",
            "what did you do a moment ago"].contains(normalized) {
            return .activitySummary
        }
        if ["what file did you create", "what file did you write", "which file did you create"].contains(normalized) {
            return .verifiedArtifactSummary
        }
        if requiresFreshData(goal) { return .planner }
        if let query = TaskContinuity.query(for: normalized) { return .taskContinuity(query) }

        let unsafe = ["rm -rf", "rm -fr", "delete everything", "wipe the", "wipe my", "wipe all",
                      "format the disk", "erase the disk", "erase my disk", "factory reset", "kernel panic",
                      "destroy the", "destroy all"]
        if unsafe.contains(where: lower.contains) { return .refusal(.unsafeRequest) }

        let unresolved: [(Set<String>, RefusalReason)] = [
            (["open that app", "launch that app", "switch to that app", "open the app", "launch the app",
              "switch to the app", "open that", "launch that", "switch to that", "open that application",
              "open this app", "launch this app", "switch to this app", "open this", "launch this", "switch to this",
              "open it", "launch it", "switch to it", "focus it", "focus that",
              "open the application", "launch the application", "switch to the application",
              "list that folder", "open that folder", "show that folder", "list the folder",
              "list that directory", "open that directory", "show that directory"], .unresolvedReference),
            (["read that file", "read that", "read the file", "read the file i mentioned", "read this file",
              "read this", "read it", "view it", "show it", "cat it",
              "read that document", "read the document", "read that file again",
              "view that file", "view this file", "show that file", "show this file", "cat that file", "cat that",
              "open that file", "open the file you created", "open the file you just created",
              "open the file from earlier", "read the file you created", "read the file you just created"], .unresolvedFileReference),
            (["write that to the file", "write that to a file", "write it to the file", "write it", "write that",
              "write this to the file", "save that to the file", "save that to a file", "save that file",
              "save this to the file", "write to that file"], .unresolvedWriteReference),
            (["fetch that url", "fetch that", "fetch the url", "fetch this url", "fetch it", "download that url",
              "download that", "download this url", "fetch that website", "download the url", "fetch that page",
              "fetch that link", "go back to that webpage", "go back to that page", "return to that webpage",
              "open that webpage", "open that url"], .unresolvedURLReference),
            (["run that command", "run that command again", "run that", "run it", "run this command", "run this",
              "execute that command", "execute that", "execute it", "execute this command", "execute this",
              "run the command", "execute the command", "run that script", "execute that script",
              "run that again", "execute that again", "rerun the command", "rerun that"], .unresolvedCommandReference),
            (["search for that", "search that", "search it", "search this", "look that up", "look it up", "google that"], .unresolvedSearchReference),
            (["increase it", "decrease it", "set it to that", "set that to that", "turn it up", "turn it down", "turn that up", "turn that down"], .unresolvedVolumeReference)
        ]
        if let match = unresolved.first(where: { $0.0.contains(normalized) }) {
            return .refusal(match.1)
        }

        let questionStarters = ["what ", "who ", "when ", "why ", "how ", "explain ", "define ",
                                "describe ", "tell me about", "tell me what", "tell me why", "tell me how"]
        let actionVerbs = ["run ", "execute ", "open ", "launch ", "search for", "search the web", "search online",
                           "look up", "find ", "fetch", "download", "list ", "show ", "read ", "write ",
                           "create ", "delete ", "remove ", "copy ", "move ", "set ", "print ", "make ",
                           "kill ", "quit ", "close ", "empty ", "install ", "uninstall "]
        if questionStarters.contains(where: lower.hasPrefix), !actionVerbs.contains(where: lower.contains) {
            return .directAnswer
        }

        let bareFollowUps: Set<String> = ["why", "how", "when", "explain", "elaborate", "what happened"]
        if bareFollowUps.contains(normalized) { return .directAnswer }
        let words = normalized.split(separator: " ")
        let processVerbs: Set<String> = ["summarize", "summarise", "repeat", "restate", "rephrase", "rewrite", "shorten", "explain", "translate", "spell"]
        let conversationReferents: Set<String> = ["that", "this", "it", "them", "those", "these", "previous", "last"]
        if let first = words.first, processVerbs.contains(String(first)), words.count <= 10,
           words.contains(where: { conversationReferents.contains(String($0)) }) { return .directAnswer }

        let unsupported = ["send an email", "send the email", "email to", "send a text", "send a message",
                           "text message", "send a tweet", "post a tweet", "post on twitter", "post on facebook",
                           "post on instagram", "whatsapp", "slack message", "send a slack", "play music",
                           "play a song", "play some music", "spotify", "netflix", "order ", "buy ",
                           "purchase ", "set an alarm", "set a timer", "remind me", "make a call", "call someone", "dial "]
        if unsupported.contains(where: lower.contains) { return .refusal(.unsupportedCapability) }
        return .planner
    }

    static func refusalReason(for goal: String) -> RefusalReason? {
        if case .refusal(let reason) = decide(goal: goal) { return reason }
        return nil
    }

    private static func informationSource(for normalized: String) -> InformationSource? {
        if ["what did we talk about recently", "what have we talked about recently",
            "what did we discuss recently", "summarize our recent conversation"].contains(normalized) {
            return .conversationHistory
        }
        if ["what do you remember", "what do you remember about me", "what do you remember about my project",
            "what do you remember about my preferences"].contains(normalized) { return .userMemory }
        if ["what did you change in zia recently", "what did we change in zia recently", "what changed in zia recently",
            "what did you change in jarvis recently", "what did we change recently"].contains(normalized) {
            return .developmentHistory
        }
        return nil
    }

    private static func normalize(_ goal: String) -> String {
        var result = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = result.last, ".?!".contains(last) { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespaces)
        for prefix in ["please ", "can you please ", "can you ", "could you please ", "could you "] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return result
    }
}