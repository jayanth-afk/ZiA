import Foundation
import AVFoundation

/// Low-power wake word detector that spots "Jarvis" (or configured wake word).
/// Active primarily in SLEEP state, gating full pipeline activation.
@MainActor
final class WakeWordDetector {
    static let shared = WakeWordDetector()

    // MARK: - State
    private(set) var isListening = false

    private init() {}

    // MARK: - Public API

    func startListening() {
        guard !isListening else { return }
        isListening = true
        JarvisLogger.voice.info("Wake word detector listening for: '\(Config.shared.wakeWord)'")
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        JarvisLogger.voice.info("Wake word detector stopped")
    }

    /// Check if recognized text contains the wake word.
    /// Returns true and publishes WakeWordDetectedEvent if detected.
    @discardableResult
    func checkForWakeWord(in transcript: String) -> Bool {
        guard isListening else { return false }

        let target = Config.shared.wakeWord.lowercased()
        let cleaned = transcript.lowercased()

        // Match exact word or prefix (e.g. "Jarvis,", "Hey Jarvis", "Jarvis tell me")
        let matches = cleaned.contains(target) ||
                      cleaned.hasPrefix(target) ||
                      cleaned.split(separator: " ").contains(where: { $0.trimmingCharacters(in: .punctuationCharacters) == target })

        if matches {
            JarvisLogger.voice.info("Wake word '\(target)' detected in transcript: '\(transcript)'")
            EventBus.shared.publish(WakeWordDetectedEvent())
            return true
        }

        return false
    }
}
