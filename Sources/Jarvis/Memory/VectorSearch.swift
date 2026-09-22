import Foundation
import Accelerate

/// Search result scored by cosine similarity.
struct VectorSearchResult: Identifiable, Sendable {
    let id: UUID
    let text: String
    let score: Float
    let metadata: [String: String]
}

/// In-memory vector store performing hardware-accelerated SIMD cosine similarity search.
final class VectorSearch: @unchecked Sendable {
    static let shared = VectorSearch()

    struct StoredVector: Identifiable, Sendable {
        let id: UUID
        let text: String
        let vector: [Float]
        let metadata: [String: String]
    }

    private let lock = NSLock()
    private var vectors: [StoredVector] = []

    private init() {}

    // MARK: - Public API

    /// Index a text entry with its embedding.
    @discardableResult
    func add(text: String, metadata: [String: String] = [:]) -> UUID {
        let id = UUID()
        let embedding = EmbeddingEngine.shared.embed(text)

        lock.lock()
        defer { lock.unlock() }

        vectors.append(StoredVector(id: id, text: text, vector: embedding, metadata: metadata))
        return id
    }

    /// Perform cosine similarity search for a query string.
    func search(query: String, topK: Int = 3, threshold: Float = 0.1) -> [VectorSearchResult] {
        let queryVector = EmbeddingEngine.shared.embed(query)
        let dimension = EmbeddingEngine.shared.dimension

        lock.lock()
        let items = vectors
        lock.unlock()

        var results: [VectorSearchResult] = []

        for item in items {
            var score: Float = 0.0
            vDSP_dotpr(queryVector, 1, item.vector, 1, &score, vDSP_Length(dimension))

            if score >= threshold {
                results.append(VectorSearchResult(
                    id: item.id,
                    text: item.text,
                    score: score,
                    metadata: item.metadata
                ))
            }
        }

        // Sort descending by similarity score
        results.sort { $0.score > $1.score }
        return Array(results.prefix(topK))
    }

    /// Remove a stored vector by ID.
    @discardableResult
    func remove(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let initialCount = vectors.count
        vectors.removeAll { $0.id == id }
        return vectors.count < initialCount
    }

    /// Clear all stored vectors.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        vectors.removeAll()
    }

    /// Number of indexed vectors.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return vectors.count
    }
}
