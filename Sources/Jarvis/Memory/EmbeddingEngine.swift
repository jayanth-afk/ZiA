import Foundation
import Accelerate

public final class EmbeddingEngine: @unchecked Sendable {
    public static let shared = EmbeddingEngine()

    public init() {}

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