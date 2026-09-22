import Foundation

/// Represents a cited information source with provenance metadata.
public struct Source: Sendable, Identifiable, Codable {
    public let id: String
    public let url: URL
    public let title: String
    public let domain: String
    public let snippet: String
    public let retrievedAt: Date
    public let query: String?

    public init(
        id: String = UUID().uuidString,
        url: URL,
        title: String,
        domain: String,
        snippet: String,
        retrievedAt: Date = Date(),
        query: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.domain = domain
        self.snippet = snippet
        self.retrievedAt = retrievedAt
        self.query = query
    }
}

/// Tracks, deduplicates, and formats research citations across agent loops.
/// Thread-safe via NSLock, callable synchronously or asynchronously from any actor.
public final class SourceManager: @unchecked Sendable {
    public static let shared = SourceManager()

    private let lock = NSLock()
    private var sources: [Source] = []

    public init() {}

    // MARK: - Source Tracking

    /// Register a newly discovered source. Deduplicates based on normalized URL.
    @discardableResult
    public func recordSource(url: URL, title: String, snippet: String, query: String? = nil) -> Source {
        lock.lock()
        defer { lock.unlock() }

        let domain = url.host ?? url.absoluteString
        let normalizedURL = normalize(url: url)

        // If existing source with same normalized URL exists, return existing
        if let existing = sources.first(where: { normalize(url: $0.url) == normalizedURL }) {
            return existing
        }

        let newSource = Source(
            url: url,
            title: title.isEmpty ? domain : title,
            domain: domain,
            snippet: snippet,
            retrievedAt: Date(),
            query: query
        )
        sources.append(newSource)
        return newSource
    }

    /// Retrieve all recorded sources.
    public func allSources() -> [Source] {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }

    /// Formats citations in standard numbered academic / markdown format.
    /// Example: "[1] Swift 6 Concurrency (swift.org) - https://swift.org/..."
    public func formatCitations() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard !sources.isEmpty else { return "" }

        return sources.enumerated().map { index, source in
            "[\(index + 1)] \(source.title) (\(source.domain))\n    \(source.url.absoluteString)"
        }.joined(separator: "\n")
    }

    /// Clears all recorded sources for a new research task.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        sources.removeAll()
    }

    // MARK: - Normalization

    private func normalize(url: URL) -> String {
        var str = url.absoluteString.lowercased()
        if str.hasSuffix("/") {
            str.removeLast()
        }
        return str
    }
}
