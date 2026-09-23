import Foundation

/// Direct-answer composition for planner steps with `tool: null` (STEP 7).
///
/// When the planner deliberately defers to composition, the user-facing
/// response must be a real answer to the goal — never the placeholder purpose
/// text ("composed answer"). This composer runs ONE small bounded generation
/// through the same local MLX worker, conditioned on the goal and the REAL
/// observations from any tools executed earlier in the plan. Nothing is
/// faked: with no observations the model answers from its own knowledge, and
/// on failure the caller falls back to the honest planner purpose text.
///
/// Bounded: exactly 1 generation, small token cap. Cancellation-safe.
actor DirectComposer {

    func composeAnswer(goal: String, observations: [String]) async throws -> String {
        try Task.checkCancellation()

        // Keep the prompt tiny: goal + clipped observations only.
        var prompt = "Answer the user's request directly in one short sentence.\n"
        prompt += "Request: \(goal)\n"
        if !observations.isEmpty {
            let clipped = observations.suffix(3).map { String($0.prefix(160)) }
            prompt += "Observed results: \(clipped.joined(separator: " | "))\n"
        }
        prompt += "Answer: "

        let stream = await provider.complete(
            messages: [Message(role: .user, content: prompt)],
            tools: nil,
            stream: false,
            options: ["max_tokens": 96])

        var text = ""
        for try await chunk in stream {
            try Task.checkCancellation()
            switch chunk {
            case .text(let t): text += t
            case .error(let e): throw JarvisError.providerError(provider: "direct-composer", message: e)
            case .done, .toolCall: continue
            }
        }

        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    /// Shares the "normal" local model slot with the planner (same worker).
    private let provider = MLXProvider(id: "mlx-composer", modelSlot: "normal")
}
