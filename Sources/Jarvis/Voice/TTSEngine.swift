import Foundation
import AVFoundation

/// Text-to-Speech router and engine.
/// Routes acknowledgements to instant on-device Apple TTS, and supports streaming/interruptions.
@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSEngine()

    // MARK: - TTS Routing Mode
    enum TTSMode: Sendable {
        case acknowledgement  // Short acks ("On it.") -> Apple TTS (0ms network)
        case conversational   // Detailed responses -> Local or Cloud TTS
        case offline          // No network -> Apple TTS always
    }

    // MARK: - State
    private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    // Callbacks
    var onSpeechFinished: (@MainActor @Sendable () -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak text using the appropriate mode.
    func speak(_ text: String, mode: TTSMode = .acknowledgement) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // If currently speaking, stop immediately for new utterance
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        switch mode {
        case .acknowledgement, .offline:
            appleSpeak(text)
        case .conversational:
            // For Phase 2, Apple TTS is the verified, zero-dependency engine.
            // Future phases add Cloud TTS adapters when configured.
            appleSpeak(text)
        }
    }

    /// Stop speech immediately (barge-in / interrupt).
    func stop() {
        guard isSpeaking || synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        JarvisLogger.voice.info("TTS stopped immediately")
    }

    // MARK: - Private Apple TTS

    private func appleSpeak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05 // Slightly brisk, natural pace
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Select default English voice or system voice
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }

        isSpeaking = true
        JarvisLogger.voice.info("Speaking: '\(text)'")
        synthesizer.speak(utterance)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            JarvisLogger.voice.debug("TTS finished speaking utterance")
            self?.onSpeechFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            JarvisLogger.voice.debug("TTS utterance was cancelled")
        }
    }
}
