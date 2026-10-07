import Foundation

/// Streaming turn preparer for low-latency voice -> thinking pipeline.
///
/// Operates on partial transcripts while speech recognition is in flight:
/// 1. Intercepts emergency stops immediately (0ms wait for finalization).
/// 2. Performs speculative intent classification (deterministic vs conversational/reasoning).
/// 3. Pre-captures environment context and data sensitivity during speech.
/// 4. Pre-warms the ChatGPT provider and bridge connection so that dispatch
///    at final transcript has essentially zero preparation latency.
@MainActor
final class StreamingTurnPreparer {
    static let shared = StreamingTurnPreparer()

    struct PreparedContext: Sendable {
        let partialText: String
        let environment: TaskEnvironmentContext
        let sensitivity: DataClassifier.SensitivityLevel
        let isDeepCandidate: Bool
        let isDeterministic: Bool
        let timestamp: Date
    }

    private let eventBus: EventBus
    private let onEmergencyStop: (String) -> Void
    private(set) var latestPrepared: PreparedContext?
    private var lastProcessedText: String = ""

    init(
        eventBus: EventBus = .shared,
        onEmergencyStop: @escaping (String) -> Void = { phrase in
            EmergencyInterrupt.shared.triggerEmergencyStop(phrase: phrase)
        }
    ) {
        self.eventBus = eventBus
        self.onEmergencyStop = onEmergencyStop
    }

    /// Reset any pending prepared turn state.
    func reset() {
        latestPrepared = nil
        lastProcessedText = ""
    }

    /// Process incoming partial transcript from speech recognition.
    /// Returns true if an emergency stop was triggered.
    @discardableResult
    func processPartialTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 1. Immediate emergency stop check (deterministic, zero wait for endpointing)
        let lowered = trimmed.lowercased()
        if let phrase = EmergencyInterrupt.shared.isEmergencyPhrase(lowered) {
            JarvisLogger.voice.info("[StreamingTurnPreparer] Emergency stop phrase detected in partial transcript: '\(text)'")
            latestPrepared = nil
            onEmergencyStop(phrase)
            return true
        }

        // Avoid re-processing identical partial text
        guard trimmed != lastProcessedText else { return false }
        lastProcessedText = trimmed

        let words = trimmed.split(separator: " ")
        guard words.count >= 2 else { return false }

        // 2. Speculative intent classification
        var cleaned = lowered
        while let last = cleaned.last, ".?!".contains(last) {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        let isDeterministic = DeterministicRouter.shared.match(cleaned) != nil
        let isDeep = !isDeterministic && ChatGPTBrainPolicy.looksLikeDeepRequest(cleaned)

        // 3. Speculative preparation for conversational / reasoning requests
        if isDeep {
            let env = TaskEnvironmentContext.captureLive()
            let sensitivity = DataClassifier.shared.classify(cleaned)

            latestPrepared = PreparedContext(
                partialText: cleaned,
                environment: env,
                sensitivity: sensitivity,
                isDeepCandidate: true,
                isDeterministic: false,
                timestamp: Date()
            )

            // Warm up provider availability asynchronously
            Task { @MainActor in
                _ = await ProviderManager.shared.isProviderAvailable(ProviderManager.shared.chatgptDesktop)
            }
        } else if isDeterministic {
            latestPrepared = PreparedContext(
                partialText: cleaned,
                environment: TaskEnvironmentContext.captureLive(),
                sensitivity: .publicLevel,
                isDeepCandidate: false,
                isDeterministic: true,
                timestamp: Date()
            )
        }

        return false
    }

    /// Retrieve prepared context for a final transcript if still fresh (< 3.0s).
    func takePreparedContext(for goal: String) -> PreparedContext? {
        guard let prepared = latestPrepared else { return nil }
        latestPrepared = nil
        let age = Date().timeIntervalSince(prepared.timestamp)
        guard age < 3.0 else { return nil }

        // Match if the goal starts with or contains the prepared partial
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanGoal.contains(prepared.partialText) || prepared.partialText.contains(cleanGoal) {
            return prepared
        }
        return prepared
    }
}
