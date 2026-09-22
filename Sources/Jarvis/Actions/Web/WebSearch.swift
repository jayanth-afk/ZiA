import Foundation

/// Structured result from a web search query.
public struct SearchResult: Sendable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let url: String
    public let snippet: String

    public init(id: String = UUID().uuidString, title: String, url: String, snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Web search engine supporting multi-provider or zero-API-key web search.
/// Runs off MainActor with cooperative cancellation.
public actor WebSearch {
    public static let shared = WebSearch()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Execute a web search query and return top results.
    public func search(query: String, maxResults: Int = 5) async throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        // Check if Tavily or custom search API key exists in Keychain
        let tavilyKey = await KeychainManager.shared.getAPIKey(for: .tavily)
        let customSearchKey = await KeychainManager.shared.getCustomKey("SEARCH_API_KEY")
        let customKey = tavilyKey ?? customSearchKey
        if let apiKey = customKey, !apiKey.isEmpty {
            do {
                return try await searchViaTavily(query: query, apiKey: apiKey, maxResults: maxResults)
            } catch {
                JarvisLogger.actions.warning("Custom search API failed: \(error.localizedDescription), falling back to DuckDuckGo")
            }
        }

        // Zero-API-key fallback: DuckDuckGo HTML / Instant Answer search
        return try await searchViaDuckDuckGo(query: query, maxResults: maxResults)
    }

    // MARK: - Tavily Search API

    private func searchViaTavily(query: String, apiKey: String, maxResults: Int) async throws -> [SearchResult] {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw JarvisError.actionFailed(action: "WebSearch.search", reason: "Invalid Tavily search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "search_depth": "basic",
            "max_results": maxResults
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw JarvisError.actionFailed(action: "WebSearch.search", reason: "Tavily returned error status")
        }

        struct TavilyResponse: Decodable {
            struct ResultItem: Decodable {
                let title: String
                let url: String
                let content: String
            }
            let results: [ResultItem]?
        }

        let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
        guard let items = decoded.results else { return [] }

        return items.prefix(maxResults).map {
            SearchResult(title: $0.title, url: $0.url, snippet: $0.content)
        }
    }

    // MARK: - DuckDuckGo HTML / Instant Answer Fallback

    private func searchViaDuckDuckGo(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            throw JarvisError.actionFailed(action: "WebSearch.search", reason: "Invalid search query")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw JarvisError.actionFailed(action: "WebSearch.search", reason: "DuckDuckGo returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        let parsedResults = parseDuckDuckGoHTML(html, maxResults: maxResults)

        if !parsedResults.isEmpty {
            return parsedResults
        }

        // If HTML parsing found no structured matches, return a clean direct search result entry
        return [
            SearchResult(
                title: "Search results for: \(query)",
                url: "https://duckduckgo.com/?q=\(encoded)",
                snippet: "Direct query for '\(query)'. Open URL to view full interactive results."
            )
        ]
    }

    private func parseDuckDuckGoHTML(_ html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Match result blocks: class="result__body" or class="result results_links"
        let resultPattern = #"(?s)<div class="result__body"[^>]*>.*?<a class="result__url"[^>]*href="([^"]+)"[^>]*>.*?<a class="result__snippet"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: resultPattern, options: []) else {
            return []
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches.prefix(maxResults) {
            guard match.numberOfRanges >= 3 else { continue }
            var rawURL = nsString.substring(with: match.range(at: 1))
            let rawSnippet = nsString.substring(with: match.range(at: 2))

            // DuckDuckGo redirects through /l/?kh=-1&uddg=...
            if let uddgRange = rawURL.range(of: "uddg=") {
                let encodedURL = String(rawURL[uddgRange.upperBound...])
                if let decodedURL = encodedURL.removingPercentEncoding {
                    rawURL = decodedURL
                }
            }

            let snippet = cleanHTML(rawSnippet)
            let title = rawURL.components(separatedBy: "://").last?.components(separatedBy: "/").first ?? "Result"

            if !rawURL.isEmpty && !snippet.isEmpty {
                results.append(SearchResult(title: title, url: rawURL, snippet: snippet))
            }
        }

        return results
    }

    private func cleanHTML(_ html: String) -> String {
        var cleaned = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "&amp;", with: "&")
        cleaned = cleaned.replacingOccurrences(of: "&quot;", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "&#39;", with: "'")
        cleaned = cleaned.replacingOccurrences(of: "&nbsp;", with: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
