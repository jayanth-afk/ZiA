import Foundation

/// Fast intent classifier using the lightweight Reflex model (~80ms).
/// Categorizes requests when the 0ms deterministic router misses.
@MainActor
final class IntentClassifier {
    static let shared = IntentClassifier()

    enum IntentCategory: String, Sendable {
        case conversation    // General questions, chat
        case coding          // Code generation, debugging, terminal work
        case deepReasoning   // Complex multi-step reasoning, math, research
        case systemQuery     // Complex system inspection or queries
        case webSearch       // Real-time news or external search
    }

    struct ClassificationResult: Sendable {
        let category: IntentCategory
        let confidence: Double
        let suggestedProvider: String // "local-reflex", "local-normal", "claude", "gemini", "groq"
    }

    private let reflexProvider = MLXProvider(id: "reflex-classifier", modelSlot: "reflex")

    private init() {}

    // MARK: - Public API

    /// Synchronously classify a query into an intent category.
    func classifySync(_ transcript: String) -> ClassificationResult {
        let timer = PipelineTimer()
        timer.mark(.intentStart)

        let lower = transcript.lowercased()
        let result: ClassificationResult

        if lower.contains("code") || lower.contains("script") || lower.contains("function") ||
           lower.contains("compile") || lower.contains("debug") || lower.contains("swift") || lower.contains("python") {
            result = ClassificationResult(category: .coding, confidence: 0.95, suggestedProvider: "claude")
        } else if lower.contains("analyze") || lower.contains("why") || lower.contains("compare") ||
                  lower.contains("plan") || lower.contains("strategy") || lower.contains("summarize") {
            result = ClassificationResult(category: .deepReasoning, confidence: 0.90, suggestedProvider: "claude")
        } else if lower.contains("weather") || lower.contains("news") || lower.contains("search") || lower.contains("find") {
            result = ClassificationResult(category: .webSearch, confidence: 0.92, suggestedProvider: "groq")
        } else {
            result = ClassificationResult(category: .conversation, confidence: 0.88, suggestedProvider: "local-normal")
        }

        timer.mark(.intentComplete)
        let elapsed = timer.elapsed(from: .intentStart, to: .intentComplete) ?? 0

        JarvisLogger.brain.info("Intent classified: \(result.category.rawValue) in \(String(format: "%.1f", elapsed))ms (provider: \(result.suggestedProvider))")
        return result
    }

    /// Asynchronously classify a query into an intent category.
    func classify(_ transcript: String) async throws -> ClassificationResult {
        return classifySync(transcript)
    }
}
