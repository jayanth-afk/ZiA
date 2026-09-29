import Foundation

/// Direct-answer composition for planner steps with `tool: null` (STEP 7).
///
/// When the planner deliberately defers to composition, the user-facing
/// response must be a real answer to the goal — never the placeholder purpose
/// text ("composed answer"). This composer runs ONE small bounded generation
/// through the same local MLX worker, conditioned on the goal, the REAL
/// observations from any tools executed earlier in the plan, and — when
/// available — the actual conversation history from prior production turns.
/// Nothing is faked: with no observations the model answers from its own
/// knowledge, and on failure the caller falls back to the honest planner
/// purpose text.
///
/// Bounded: exactly 1 generation, small token cap. Cancellation-safe.
actor DirectComposer {

    func composeAnswer(goal: String, observations: [String]) async throws -> String {
        try Task.checkCancellation()

        // Cross-turn memory: reuse the existing ConversationManager history so
        // follow-up questions can reference the previous production turn
        // (e.g. "why?" after a completed task). Clipped to the last few turns
        // — the prompt stays tiny for the 0.5B model.
        let history = await MainActor.run { ConversationManager.shared.getContext() }
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(4)

        // Keep the prompt tiny: brief history + goal + clipped observations.
        var prompt = "Answer the user's request directly in one short sentence.\n"
        if !history.isEmpty {
            prompt += "Conversation so far:\n"
            for m in history {
                let who = m.role == .user ? "User" : "You"
                prompt += "\(who): \(String(m.content.prefix(160)))\n"
                if prompt.count > 1600 { break }
            }
        }
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
