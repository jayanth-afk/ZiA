import Foundation

/// What the user is actually asking for. This is deliberately richer than the
/// legacy action-oriented `IntentType`: it distinguishes an answer from a task,
/// a one-off from a recurring or monitored one, and a question from a follow-up.
enum IntentKind: String, Codable, Sendable, CaseIterable {
    case question
    case conversation
    case command
    case task
    case multiStepProject
    case recurringTask
    case monitoringRequest
    case automationRequest
    case researchRequest
    case codingTask
    case computerControlTask
    case clarificationRequest
    case followUp

    /// Whether this intent should become durable, multi-step work.
    var requiresPlanning: Bool {
        switch self {
        case .question, .conversation, .clarificationRequest:
            return false
        case .command, .followUp:
            return false
        case .task, .multiStepProject, .recurringTask, .monitoringRequest,
             .automationRequest, .researchRequest, .codingTask, .computerControlTask:
            return true
        }
    }

    /// Whether this intent describes work that continues after the current turn.
    var isLongRunning: Bool {
        switch self {
        case .recurringTask, .monitoringRequest, .automationRequest, .multiStepProject:
            return true
        default:
            return false
        }
    }
}

/// The cheapest intelligence tier that can plausibly satisfy an intent. Zia
/// prefers deterministic code, then a small local model, then a strong model —
/// only escalating when the work actually needs it.
enum IntelligenceTier: String, Sendable, Codable, CaseIterable {
    case none            // No model needed (deterministic capability handles it).
    case localReflex     // Small local model (fast classification/short answers).
    case localNormal     // Normal local model (general conversation/answers).
    case cloudDeep       // Strong model (deep reasoning, complex coding, research).
}

/// Deterministic intent classification. No model call: this decision runs on
/// every turn, so it must be instant and reproducible.
struct ZiaIntent: Sendable, Equatable {
    let kind: IntentKind
    let requiresPlanning: Bool
    let suggestedTier: IntelligenceTier
    let confidence: Double
    let signals: [String]
}

enum IntentEngine {
    static func classify(_ text: String) -> ZiaIntent {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return ZiaIntent(kind: .conversation, requiresPlanning: false,
                             suggestedTier: .localNormal, confidence: 1.0, signals: [])
        }

        var signals: [String] = []

        func containsAny(_ words: [String]) -> Bool {
            for word in words where normalized.contains(word) {
                signals.append(word)
                return true
            }
            return false
        }
        func startsWithAny(_ prefixes: [String]) -> Bool {
            for prefix in prefixes where normalized.hasPrefix(prefix) {
                signals.append(prefix)
                return true
            }
            return false
        }

        let kind: IntentKind
        let confidence: Double

        if containsAny(["every day", "every morning", "every week", "each day", "each morning",
                        "daily at", "every hour", "every monday", "schedule", "remind me to",
                        "recurring", "every night", "weekly"]) {
            kind = .recurringTask; confidence = 0.9
        } else if containsAny(["monitor", "watch for", "notify me when", "let me know when",
                               "tell me when", "alert me when", "keep an eye on", "when it changes",
                               "until the build", "wait until"]) {
            kind = .monitoringRequest; confidence = 0.85
        } else if containsAny(["whenever i", "automatically when", "when i connect", "when i open",
                               "when the file changes", "set up an automation", "automate when",
                               "trigger when"]) {
            kind = .automationRequest; confidence = 0.82
        } else if containsAny(["research", "look up", "find out about", "compare the", "investigate",
                               "summarize the article", "gather information", "survey", "deep dive"]) {
            kind = .researchRequest; confidence = 0.8
        } else if containsAny(["refactor", "implement", "compile", "build the project", "fix the bug",
                               "fix this bug", "write a function", "write a script", "debug",
                               "run the tests", "add a test", "codebase", "commit", "pull request",
                               "rename the variable", "swift package"]) {
            kind = .codingTask; confidence = 0.85
        } else if containsAny(["click", "type into", "keystroke", "screenshot", "screen capture",
                               "move the mouse", "scroll", "fill in the form", "drag", "press the button"]) {
            kind = .computerControlTask; confidence = 0.8
        } else if containsAny([" and then ", " after that ", "; then", "first ", "step by step",
                               " then ", "followed by", "finally "]) {
            kind = .multiStepProject; confidence = 0.72
        } else if containsAny(["continue", "carry on", "keep going", "finish that", "finish it",
                               "do the same", "and also", "resume"]) {
            kind = .followUp; confidence = 0.7
        } else if containsAny(["what do you mean", "which one", "clarify", "can you explain what you",
                               "i don't understand", "come again", "say that again"]) {
            kind = .clarificationRequest; confidence = 0.8
        } else if containsAny(["open ", "launch ", "start ", "set volume", "mute", "unmute",
                               "lock screen", "take a screenshot", "empty trash", "sleep mac",
                               "switch to "]) {
            kind = .command; confidence = 0.8
        } else if containsAny(["walk me through", "help me plan", "organize", "set up a plan",
                               "make a plan", "i want to build", "i need to get", "figure out how to"]) {
            kind = .task; confidence = 0.7
        } else if normalized.hasSuffix("?") || startsWithAny(["what ", "why ", "how ", "when ",
                                                              "where ", "who ", "which ", "is ", "are ",
                                                              "do ", "does ", "can ", "could ", "should ",
                                                              "will ", "would "]) {
            kind = .question; confidence = 0.75
        } else if startsWithAny(["hello", "hi ", "hey ", "thanks", "thank you", "good morning",
                                 "good evening", "how are you"]) {
            kind = .conversation; confidence = 0.8
        } else {
            kind = .task; confidence = 0.5
        }

        return ZiaIntent(
            kind: kind,
            requiresPlanning: kind.requiresPlanning,
            suggestedTier: tier(for: kind),
            confidence: confidence,
            signals: signals)
    }

    private static func tier(for kind: IntentKind) -> IntelligenceTier {
        switch kind {
        case .conversation, .clarificationRequest, .followUp:
            return .localNormal
        case .question:
            return .localNormal
        case .command:
            return .localReflex
        case .task, .computerControlTask:
            return .localNormal
        case .multiStepProject, .codingTask, .researchRequest:
            return .cloudDeep
        case .recurringTask, .monitoringRequest, .automationRequest:
            return .localNormal
        }
    }
}
