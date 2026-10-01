import Foundation

/// Direct-answer composition for planner steps with `tool: null` (STEP 7).
actor DirectComposer {

    func composeAnswer(goal: String, observations: [String]) async throws -> String {
        try Task.checkCancellation()

        // Single MainActor hop to batch conversation history + user memory retrieval
        let (history, userMemory) = await MainActor.run { () -> ([Message], String) in
            var hist = ConversationManager.shared.getContext()
                .filter { $0.role == .user || $0.role == .assistant }
            if hist.isEmpty {
                hist = ConversationStore.shared.loadMessages(limit: 12)
                    .filter { $0.role == .user || $0.role == .assistant }
            }
            let slicedHistory = Array(hist.suffix(4))
            let mem = MemoryManager.shared.retrieveContext(for: goal)
            return (slicedHistory, mem)
        }

        // Fast string buffer with pre-allocated capacity
        var prompt = ""
        prompt.reserveCapacity(2048)
        prompt.append("Answer the user's request directly in one short sentence.\n")

        if !history.isEmpty {
            prompt.append("Conversation so far:\n")
            for m in history {
                let who = m.role == .user ? "User" : "You"
                prompt.append(who)
                prompt.append(": ")
                prompt.append(contentsOf: m.content.prefix(160))
                prompt.append("\n")
                if prompt.count > 1600 { break }
            }
        }

        if !userMemory.isEmpty {
            prompt.append("Saved user memory (context only; follow current request):\n")
            prompt.append(contentsOf: userMemory.prefix(800))
            prompt.append("\n")
        }

        prompt.append("Request: ")
        prompt.append(goal)
        prompt.append("\n")

        if !observations.isEmpty {
            let clipped = observations.suffix(3).map { obs -> String in
                let sanitized = obs.replacingOccurrences(of: "</observation>", with: "")
                return "<observation>\(String(sanitized.prefix(160)))</observation>"
            }
            prompt.append("Observed results: ")
            prompt.append(clipped.joined(separator: " | "))
            prompt.append("\n")
        }

        prompt.append("Answer: ")

        let stream = await provider.complete(
            messages: [Message(role: .user, content: prompt)],
            tools: nil,
            stream: false,
            options: ["max_tokens": 96])

        var text = ""
        text.reserveCapacity(256)
        for try await chunk in stream {
            try Task.checkCancellation()
            switch chunk {
            case .text(let t): text.append(t)
            case .error(let e): throw JarvisError.providerError(provider: "direct-composer", message: e)
            case .done, .toolCall: continue
            }
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\"") { cleaned.removeFirst() }
        if cleaned.hasSuffix("\"") { cleaned.removeLast() }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let provider = MLXProvider(id: "mlx-composer", modelSlot: "normal")
}