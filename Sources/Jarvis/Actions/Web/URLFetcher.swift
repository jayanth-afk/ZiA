import Foundation

/// Structured content extracted from a web URL.
public struct FetchedContent: Sendable {
    public let url: URL
    public let title: String
    public let text: String
    public let contentLength: Int
    public let contentType: String
    public let statusCode: Int

    public init(url: URL, title: String, text: String, contentLength: Int, contentType: String, statusCode: Int) {
        self.url = url
        self.title = title
        self.text = text
        self.contentLength = contentLength
        self.contentType = contentType
        self.statusCode = statusCode
    }
}

/// Fetches web resources and extracts readable text and metadata.
/// Runs off MainActor with cooperative cancellation support.
public actor URLFetcher {
    public static let shared = URLFetcher()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Fetches the given URL and extracts readable text, truncated to `maxCharacters`.
    public func fetch(url: URL, maxCharacters: Int = 12_000) async throws -> FetchedContent {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 JARVIS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JarvisError.actionFailed(action: "URLFetcher.fetch", reason: "Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw JarvisError.actionFailed(action: "URLFetcher.fetch", reason: "HTTP \(httpResponse.statusCode)")
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "text/html"
        let rawContent = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        let title: String
        let extractedText: String

        if contentType.contains("application/json") || contentType.contains("text/plain") {
            title = url.lastPathComponent.isEmpty ? url.host ?? "Document" : url.lastPathComponent
            extractedText = rawContent
        } else {
            // HTML content
            title = extractTitle(from: rawContent) ?? url.host ?? "Web Page"
            extractedText = extractText(from: rawContent)
        }

        let truncated = String(extractedText.prefix(maxCharacters))

        return FetchedContent(
            url: url,
            title: title,
            text: truncated,
            contentLength: data.count,
            contentType: contentType,
            statusCode: httpResponse.statusCode
        )
    }

    // MARK: - HTML Parsing & Cleaning

    private func extractTitle(from html: String) -> String? {
        guard let startRange = html.range(of: "<title>", options: .caseInsensitive),
              let endRange = html.range(of: "</title>", options: .caseInsensitive, range: startRange.upperBound..<html.endIndex) else {
            return nil
        }
        let rawTitle = html[startRange.upperBound..<endRange.lowerBound]
        return decodeHTMLEntities(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func extractText(from html: String) -> String {
        var text = html

        // Remove script tags and contents
        text = text.replacingOccurrences(of: "(?is)<script.*?</script>", with: " ", options: .regularExpression)
        // Remove style tags and contents
        text = text.replacingOccurrences(of: "(?is)<style.*?</style>", with: " ", options: .regularExpression)
        // Remove HTML comments
        text = text.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)

        // Convert common block tags to newlines
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "</li>", "<br>", "<br/>", "<br />", "</tr>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Strip remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode HTML entities
        text = decodeHTMLEntities(text)

        // Normalize whitespace and blank lines
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…"
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}
