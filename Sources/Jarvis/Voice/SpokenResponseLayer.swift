import Foundation

/// Clean seam between unified assistant responses and Text-to-Speech audio output.
///
/// Converts detailed visual markdown / reasoning into clean, natural spoken English:
/// - Strips markdown headers, bullet symbols, bold/italics
/// - Replaces code blocks with a natural spoken indicator
/// - Replaces URLs with domain summaries
/// - Removes XML/internal system tags
/// - Preserves conversational naturalness
public enum SpokenResponseLayer {

    /// Clean full visual text for speech synthesis.
    public static func cleanForSpeech(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        // 1. Remove code blocks (```...```) and replace with brief natural note
        if let codeBlockRegex = try? NSRegularExpression(pattern: "```[\\s\\S]*?```", options: []) {
            cleaned = codeBlockRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: " (code snippet omitted) "
            )
        }

        // 2. Remove inline code (`...`)
        if let inlineCodeRegex = try? NSRegularExpression(pattern: "`([^`]+)`", options: []) {
            cleaned = inlineCodeRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: "$1"
            )
        }

        // 3. Remove XML-like tags (e.g. <observation>, <context>, etc.)
        if let xmlRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            cleaned = xmlRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: ""
            )
        }

        // 4. Convert markdown links [Label](url) to just Label
        if let linkRegex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)", options: []) {
            cleaned = linkRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: "$1"
            )
        }

        // 5. Remove raw URLs
        if let urlRegex = try? NSRegularExpression(pattern: "https?://\\S+", options: []) {
            cleaned = urlRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: " link "
            )
        }

        // 6. Strip headers (# Header), blockquotes (> text), bullets (*, -, +)
        var lines: [String] = []
        for rawLine in cleaned.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Strip header hashes
            while line.hasPrefix("#") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            // Strip blockquotes
            while line.hasPrefix(">") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            // Strip bullet markers
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            // Strip numbered list markers like "1. "
            if let numMatch = line.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                line = String(line[numMatch.upperBound...])
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        cleaned = lines.joined(separator: " ")

        // 7. Remove bold and italics markers (**text**, *text*, __text__, _text_)
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        cleaned = cleaned.replacingOccurrences(of: "__", with: "")
        cleaned = cleaned.replacingOccurrences(of: "*", with: "")
        cleaned = cleaned.replacingOccurrences(of: "_", with: "")

        // 8. Collapse whitespace
        if let wsRegex = try? NSRegularExpression(pattern: "\\s+", options: []) {
            cleaned = wsRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                withTemplate: " "
            )
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
