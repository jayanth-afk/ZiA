import Foundation
import Accelerate

public enum VectorSearch {
    
    /// Computes cosine similarity between two Float vectors using Accelerate hardware acceleration (vDSP).
    @inlinable
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let count = a.count
        guard count > 0 && count == b.count else { return 0.0 }
        
        var dotProduct: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(count))
        
        var sumSqA: Float = 0.0
        vDSP_svesq(a, 1, &sumSqA, vDSP_Length(count))
        
        var sumSqB: Float = 0.0
        vDSP_svesq(b, 1, &sumSqB, vDSP_Length(count))
        
        let denom = sqrt(sumSqA * sumSqB)
        return denom > 0.000001 ? (dotProduct / denom) : 0.0
    }
    
    /// Fast dot product for unit-normalized vectors.
    @inlinable
    public static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        let count = a.count
        guard count > 0 && count == b.count else { return 0.0 }
        
        var result: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
        return result
    }
    
    /// Finds top-K items using a bounded binary insertion array in O(N log K) time without sorting entire dataset.
    public static func searchTopK<T>(
        queryVector: [Float],
        items: [T],
        vectorExtractor: (T) -> [Float],
        topK: Int,
        threshold: Float = -1.0
    ) -> [(item: T, score: Float)] {
        guard !items.isEmpty && topK > 0 else { return [] }
        
        var topResults: [(item: T, score: Float)] = []
        topResults.reserveCapacity(topK + 1)
        
        for item in items {
            let vec = vectorExtractor(item)
            let score = cosineSimilarity(queryVector, vec)
            
            if score < threshold { continue }
            
            if topResults.count < topK {
                let idx = binarySearchInsertionIndex(in: topResults, score: score)
                topResults.insert((item, score), at: idx)
            } else if score > topResults.last!.score {
                topResults.removeLast()
                let idx = binarySearchInsertionIndex(in: topResults, score: score)
                topResults.insert((item, score), at: idx)
            }
        }
        
        return topResults
    }
    
    @inlinable
    private static func binarySearchInsertionIndex<T>(in results: [(item: T, score: Float)], score: Float) -> Int {
        var low = 0
        var high = results.count
        while low < high {
            let mid = (low + high) / 2
            if results[mid].score < score {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}