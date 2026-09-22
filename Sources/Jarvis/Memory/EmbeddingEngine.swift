import Foundation
import Accelerate

/// Local embedding generator utilizing Accelerate framework and vDSP SIMD on Apple Silicon M4.
/// Produces normalized unit-length embedding vectors for semantic similarity matching.
final class EmbeddingEngine: @unchecked Sendable {
    static let shared = EmbeddingEngine()

    /// Dimension of the embedding vectors.
    let dimension: Int = 64

    private init() {}

    // MARK: - Public API

    /// Generate a normalized embedding vector for a given text prompt.
    func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0.0, count: dimension)
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !lower.isEmpty else {
            return vector
        }

        // Generate dense token feature projections
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }

        for (wordIndex, word) in words.enumerated() {
            var hash = 5381
            for byte in word.utf8 {
                hash = ((hash << 5) &+ hash) &+ Int(byte)
            }

            let primaryIndex = abs(hash) % dimension
            let secondaryIndex = abs(hash >> 8) % dimension
            let weight: Float = 1.0 / Float(wordIndex + 1)

            vector[primaryIndex] += weight
            vector[secondaryIndex] += weight * 0.5
        }

        // Normalize vector to unit length via Accelerate vDSP
        var norm: Float = 0.0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(dimension))
        let magnitude = sqrt(norm)

        if magnitude > 0 {
            var scale = 1.0 / magnitude
            vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(dimension))
        }

        return vector
    }
}
