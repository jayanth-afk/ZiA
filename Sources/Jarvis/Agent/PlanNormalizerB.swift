import Foundation

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
}