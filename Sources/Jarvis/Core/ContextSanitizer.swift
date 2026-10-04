import Foundation

/// Deterministic data minimization before context leaves the device.
///
/// Two safety jobs:
///  1. **Secret redaction** — API keys, bearer tokens, private keys, JWTs, and
///     `password=`/`token=` assignments are replaced before text is sent to an
///     external provider or written to a log.
///  2. **Minimization** — bound the size of outbound context so Zia never dumps
///     the whole transcript or an entire file into a model request.
///
/// Redaction is conservative and deterministic: it never rewrites ordinary
/// prose, only patterns that are recognizably credentials.
enum ContextSanitizer {
    static let redactionMarker = "[REDACTED]"

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ template: String) -> Rule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return Rule(regex: regex, template: template)
        }
        return [
            // PEM private keys (multi-line).
            rule("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----", redactionMarker),
            // Bearer tokens.
            rule("(?i)bearer\\s+[A-Za-z0-9._\\-]{16,}", "Bearer \(redactionMarker)"),
            // OpenAI-style keys.
            rule("\\bsk-[A-Za-z0-9_\\-]{16,}", redactionMarker),
            // AWS access key IDs.
            rule("\\bAKIA[0-9A-Z]{16}\\b", redactionMarker),
            // JWT-ish tokens (three base64url segments).
            rule("\\beyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]+", redactionMarker),
            // key=value credential assignments.
            rule("(?i)\\b(api[_-]?key|apikey|secret|token|password|passwd|pwd)\\s*[:=]\\s*[\"']?[^\\s\"']{6,}[\"']?",
                 "\(redactionMarker)")
        ].compactMap { $0 }
    }()

    /// Whether any credential pattern is present.
    static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return rules.contains { $0.regex.firstMatch(in: text, options: [], range: range) != nil }
    }

    /// Replace credential patterns with a fixed marker.
    static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    /// Bound outbound text to a maximum character budget (data minimization).
    static func minimized(_ text: String, maxCharacters: Int = 8_000) -> String {
        guard maxCharacters > 0, text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…[truncated by Zia context minimization]"
    }

    /// Sanitize messages for dispatch. `isLocal == true` leaves provider-local
    /// requests intact (nothing leaves the device), while external dispatch
    /// redacts credentials and bounds size.
    static func sanitizedForDispatch(_ messages: [Message], isLocal: Bool, maxCharactersPerMessage: Int = 8_000) -> [Message] {
        guard !isLocal else { return messages }
        return messages.map { message in
            let sanitized = minimized(redact(message.content), maxCharacters: maxCharactersPerMessage)
            guard sanitized != message.content else { return message }
            return Message(id: message.id, role: message.role, content: sanitized,
                           timestamp: message.timestamp, toolCallID: message.toolCallID)
        }
    }
}
