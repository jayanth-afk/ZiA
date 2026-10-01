import Foundation

public struct DeterministicRouteResult: Sendable {
    public let actionName: String
    public let parameters: [String: String]
    public let confidence: Double

    public init(actionName: String, parameters: [String: String] = [:], confidence: Double = 1.0) {
        self.actionName = actionName
        self.parameters = parameters
        self.confidence = confidence
    }
}

public final class DeterministicRouter: @unchecked Sendable {
    public static let shared = DeterministicRouter()

    private struct RouteRule {
        let pattern: String
        let actionName: String
        let paramExtractor: (NSTextCheckingResult, String) -> [String: String]
    }

    private let rules: [RouteRule]
    private let exactMatches: [String: (String, [String: String])]

    public init() {
        let appLaunchRegex = "^(?:open|launch|start|run)\\s+(.+)$"
        let webSearchRegex = "^(?:search|google|find online)\\s+(?:for\\s+)?(.+)$"
        let volUpRegex = "^volume\\s+(?:up|increase)$"
        let volDownRegex = "^volume\\s+(?:down|decrease)$"
        let muteRegex = "^(?:mute|silence)$"

        self.rules = [
            RouteRule(
                pattern: appLaunchRegex,
                actionName: "system.openApp",
                paramExtractor: { match, input in
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) {
                        return ["appName": String(input[range])]
                    }
                    return [:]
                }
            ),
            RouteRule(
                pattern: volUpRegex,
                actionName: "system.volumeUp",
                paramExtractor: { _, _ in [:] }
            ),
            RouteRule(
                pattern: volDownRegex,
                actionName: "system.volumeDown",
                paramExtractor: { _, _ in [:] }
            ),
            RouteRule(
                pattern: muteRegex,
                actionName: "system.mute",
                paramExtractor: { _, _ in [:] }
            ),
            RouteRule(
                pattern: webSearchRegex,
                actionName: "web.search",
                paramExtractor: { match, input in
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) {
                        return ["query": String(input[range])]
                    }
                    return [:]
                }
            )
        ]

        self.exactMatches = [
            "mute": ("system.mute", [:]),
            "unmute": ("system.unmute", [:]),
            "lock": ("system.lockScreen", [:]),
            "sleep": ("system.sleep", [:]),
            "time": ("system.getTime", [:]),
            "date": ("system.getDate", [:])
        ]
    }

    public func route(_ query: String) -> DeterministicRouteResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()

        if let exact = exactMatches[lower] {
            return DeterministicRouteResult(actionName: exact.0, parameters: exact.1, confidence: 1.0)
        }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for rule in rules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: trimmed, options: [], range: nsRange) {
                let params = rule.paramExtractor(match, trimmed)
                return DeterministicRouteResult(actionName: rule.actionName, parameters: params, confidence: 0.98)
            }
        }

        return nil
    }
}