import Foundation

public final class DirectAnswerRouter: @unchecked Sendable {
    public static let shared = DirectAnswerRouter()

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
}