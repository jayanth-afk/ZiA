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

    /// Text of the utterance currently enqueued/playing. AVSpeechUtterance is
    /// not Sendable, so delegate callbacks compare via speechString identity
    /// instead of capturing the object across isolation boundaries. A stale
    /// didCancel from a previous utterance can therefore never clear the
    /// speaking state of a brand-new utterance issued after a barge-in stop.
    private var currentUtteranceText: String?

    /// Measured latency from speak() dispatch to AVSpeechSynthesizer didStart (actual audio start).
    /// This is the only truthful TTFA source — dispatch time alone is NOT TTFA.
    private(set) var lastAudioStartLatencyMs: Double?
    private var speakDispatchTime: CFAbsoluteTime?

    private let synthesizer = AVSpeechSynthesizer()

    private var isExplicitlyStopped = false

    /// Ground truth: whether the synthesizer is actually producing (or paused
    /// while producing) audio. Derived from AVFoundation rather than a
    /// manually-maintained flag so stale callbacks can never lie about it.
    var isSpeaking: Bool {
        if isExplicitlyStopped { return false }
        return synthesizer.isSpeaking || synthesizer.isPaused
    }

    /// Measured latency for immediate barge-in halt from stop() invocation.
    private(set) var lastBargeInHaltLatencyMs: Double?

    // Callbacks
    var onSpeechFinished: (@MainActor @Sendable () -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self

        // Direct barge-in subscription: user speech onset halts TTS immediately
        EventBus.shared.subscribe(UserInterruptedEvent.self) { [weak self] _ in
            self?.stop()
        }

        // Direct emergency stop subscription: emergency phrase halts TTS immediately
        EventBus.shared.subscribe(EmergencyStopEvent.self) { [weak self] _ in
            self?.stop()
        }
    }

    // MARK: - Public API

    /// Speak text using the appropriate mode.
    func speak(_ text: String, mode: TTSMode = .acknowledgement) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isExplicitlyStopped = false

        // If currently speaking, stop immediately for new utterance
        if synthesizer.isSpeaking || synthesizer.isPaused {
            currentUtteranceText = nil
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
        isExplicitlyStopped = true
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        let start = CFAbsoluteTimeGetCurrent()
        synthesizer.stopSpeaking(at: .immediate)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        lastBargeInHaltLatencyMs = elapsed
        JarvisLogger.voice.info("TTS stopped immediately in \(String(format: "%.2f", elapsed))ms")
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

        currentUtteranceText = text
        speakDispatchTime = CFAbsoluteTimeGetCurrent()
        JarvisLogger.voice.info("Speaking: '\(text, privacy: .public)'")
        synthesizer.speak(utterance)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in
            guard let self, text == self.currentUtteranceText else { return }
            if let dispatch = self.speakDispatchTime {
                self.lastAudioStartLatencyMs = (CFAbsoluteTimeGetCurrent() - dispatch) * 1000.0
                JarvisLogger.voice.info("TTS audio started (audio-start latency: \(String(format: "%.1f", self.lastAudioStartLatencyMs ?? 0), privacy: .public)ms)")
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in
            guard let self, text == self.currentUtteranceText else { return }
            self.currentUtteranceText = nil
            JarvisLogger.voice.debug("TTS finished speaking utterance")
            self.onSpeechFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in
            // Only treat cancellation of the CURRENT utterance as meaningful.
            // A stale didCancel from a replaced utterance must not clear state
            // of a newly enqueued one.
            guard let self, text == self.currentUtteranceText else { return }
            self.currentUtteranceText = nil
            JarvisLogger.voice.debug("TTS utterance was cancelled")
        }
    }
}
