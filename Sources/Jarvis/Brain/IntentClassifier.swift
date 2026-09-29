import Foundation

/// Fast, zero-model intent routing when the deterministic action router misses.
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

        let result = Self.classification(for: transcript)

        timer.mark(.intentComplete)
        let elapsed = timer.elapsed(from: .intentStart, to: .intentComplete) ?? 0

        JarvisLogger.brain.info("Intent classified: \(result.category.rawValue) in \(String(format: "%.1f", elapsed))ms (provider: \(result.suggestedProvider))")
        return result
    }

    /// Asynchronously classify a query into an intent category.
    func classify(_ transcript: String) async throws -> ClassificationResult {
        return classifySync(transcript)
    }

    /// Token-boundary routing avoids substring false positives (for example,
    /// "research" is not automatically interpreted as a web-search request).
    static func classification(for transcript: String) -> ClassificationResult {
        let normalized = transcript.lowercased().replacingOccurrences(of: "wi-fi", with: "wifi")
        let tokens = Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let coding = Set(["code", "coding", "script", "function", "compile", "debug", "swift", "python", "javascript", "typescript", "repository", "repo", "build", "bug"])
        let web = Set(["web", "online", "latest", "news", "weather", "search", "browse", "internet"])
        let reasoning = Set(["analyze", "analyse", "why", "compare", "plan", "strategy", "summarize", "explain", "evaluate", "reason", "research"])
        let system = Set(["battery", "wifi", "memory", "cpu", "storage", "volume", "brightness", "system", "date", "time"])

        let category: IntentCategory
        if !tokens.isDisjoint(with: coding) {
            category = .coding
        } else if !tokens.isDisjoint(with: web) {
            category = .webSearch
        } else if !tokens.isDisjoint(with: reasoning) {
            category = .deepReasoning
        } else if !tokens.isDisjoint(with: system) {
            category = .systemQuery
        } else {
            category = .conversation
        }

        let provider: String
        switch category {
        case .coding, .deepReasoning: provider = "claude"
        case .webSearch: provider = "groq"
        case .systemQuery, .conversation: provider = "local-normal"
        }
        let confidence: Double = category == .conversation ? 0.75 : 0.9
        return ClassificationResult(category: category, confidence: confidence, suggestedProvider: provider)
    }
}
