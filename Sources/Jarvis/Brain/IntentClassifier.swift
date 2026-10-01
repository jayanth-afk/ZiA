import Foundation

public enum IntentType: String, Codable, Sendable {
    case appLaunch
    case systemControl
    case fileOperation
    case webSearch
    case browserAction
    case terminalCommand
    case directAnswer
    case generalQuery
}

public struct ClassifiedIntent: Sendable {
    public let type: IntentType
    public let confidence: Double
    public let extractedEntities: [String: String]

    public init(type: IntentType, confidence: Double, extractedEntities: [String: String] = [:]) {
        self.type = type
        self.confidence = confidence
        self.extractedEntities = extractedEntities
    }
}

public final class IntentClassifier: @unchecked Sendable {
    public enum IntentCategory: String, Sendable {
        case coding
        case deepReasoning
        case webSearch
        case conversation
        case systemQuery
    }

    public struct Classification: Sendable, Equatable {
        public let category: IntentCategory
        public let suggestedProvider: String
    }

    public static let shared = IntentClassifier()

    private static let appLaunchKeywords: Set<String> = ["open", "launch", "start", "run", "open app", "launch app"]
    private static let systemControlKeywords: Set<String> = ["volume", "mute", "unmute", "brightness", "sleep", "restart", "shutdown", "lock", "screen"]
    private static let fileOpKeywords: Set<String> = ["find", "search file", "delete", "create file", "folder", "directory", "copy", "move", "rename"]
    private static let webSearchKeywords: Set<String> = ["search", "google", "bing", "look up", "find online", "duckduckgo", "where is"]
    private static let browserKeywords: Set<String> = ["tab", "url", "navigate", "bookmark", "reload", "refresh", "close tab", "new tab"]
    private static let directAnswerKeywords: Set<String> = ["time", "date", "day", "who are you", "what is your name", "version", "calculator"]

    private static let appLaunchRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "^(?:open|launch|start|run)\\s+(.+)", options: [.caseInsensitive])
    private static let searchRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "^(?:search|google|find online)\\s+(?:for\\s+)?(.+)", options: [.caseInsensitive])

    public init() {}

    public func classify(_ text: String) -> ClassifiedIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ClassifiedIntent(type: .generalQuery, confidence: 1.0)
        }

        let lower = trimmed.lowercased()
        
        if Self.directAnswerKeywords.contains(lower) {
            return ClassifiedIntent(type: .directAnswer, confidence: 0.98)
        }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        
        if let regex = Self.appLaunchRegex,
           let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
           let appRange = Range(match.range(at: 1), in: trimmed) {
            let appName = String(trimmed[appRange])
            return ClassifiedIntent(type: .appLaunch, confidence: 0.95, extractedEntities: ["appName": appName])
        }

        if let regex = Self.searchRegex,
           let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
           let queryRange = Range(match.range(at: 1), in: trimmed) {
            let query = String(trimmed[queryRange])
            return ClassifiedIntent(type: .webSearch, confidence: 0.95, extractedEntities: ["query": query])
        }

        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })

        if !words.isDisjoint(with: Self.appLaunchKeywords) {
            return ClassifiedIntent(type: .appLaunch, confidence: 0.85)
        }
        if !words.isDisjoint(with: Self.systemControlKeywords) {
            return ClassifiedIntent(type: .systemControl, confidence: 0.88)
        }
        if !words.isDisjoint(with: Self.fileOpKeywords) {
            return ClassifiedIntent(type: .fileOperation, confidence: 0.85)
        }
        if !words.isDisjoint(with: Self.webSearchKeywords) {
            return ClassifiedIntent(type: .webSearch, confidence: 0.85)
        }
        if !words.isDisjoint(with: Self.browserKeywords) {
            return ClassifiedIntent(type: .browserAction, confidence: 0.85)
        }

        return ClassifiedIntent(type: .generalQuery, confidence: 0.5)
    }

    public func classifySync(_ text: String) -> Classification {
        Self.classification(for: text)
    }

    public static func classification(for text: String) -> Classification {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let category: IntentCategory
        if lower.contains("battery") || lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("system status") {
            category = .systemQuery
        } else if lower.hasPrefix("search") || lower.hasPrefix("google") || lower.hasPrefix("find online") {
            category = .webSearch
        } else if ["write", "build", "implement", "code", "script"].contains(where: words.contains)
                    || ["swift", "json", "python", "javascript"].contains(where: words.contains) {
            category = .coding
        } else if ["analyze", "analyse", "architecture", "reason", "compare"].contains(where: words.contains) {
            category = .deepReasoning
        } else {
            category = .conversation
        }
        let provider: String
        switch category {
        case .coding, .deepReasoning: provider = "claude"
        case .webSearch: provider = "groq"
        case .conversation, .systemQuery: provider = "mlx-normal"
        }
        return Classification(category: category, suggestedProvider: provider)
    }
}