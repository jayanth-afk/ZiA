import Foundation
import Accelerate

public final class EmbeddingEngine: @unchecked Sendable {
    public static let shared = EmbeddingEngine()
    let dimension = 64

    public init() {}

    /// Build the existing deterministic token-hash embedding used by the memory index.
    func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return vector }

        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for (position, word) in words.enumerated() {
            var hash = 5381
            for byte in word.utf8 {
                hash = ((hash << 5) &+ hash) &+ Int(byte)
            }
            let primary = abs(hash) % dimension
            let secondary = abs(hash >> 8) % dimension
            let weight = 1 / Float(position + 1)
            vector[primary] += weight
            vector[secondary] += weight * 0.5
        }
        Self.normalizeInPlace(&vector)
        return vector
    }

    @inlinable
    public static func normalizeInPlace(_ vector: inout [Float]) {
        let count = vector.count
        guard count > 0 else { return }

        var sumSq: Float = 0.0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(count))

        let magnitude = sqrt(sumSq)
        if magnitude > 0.000001 {
            var divisor = magnitude
            vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(count))
        }
    }

    public static func normalize(_ vector: [Float]) -> [Float] {
        var copy = vector
        normalizeInPlace(&copy)
        return copy
    }
}