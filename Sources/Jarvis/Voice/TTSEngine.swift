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

    // Streaming state
    private var streamingBuffer = ""
    private var isStreamingActive = false

    // Callbacks
    var onSpeechFinished: (@MainActor @Sendable () -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self

        // Direct barge-in subscription: user speech onset halts TTS immediately if speaking
        EventBus.shared.subscribe(UserInterruptedEvent.self) { [weak self] _ in
            guard let self else { return }
            if self.synthesizer.isSpeaking || self.synthesizer.isPaused || self.isStreamingActive {
                self.stop()
            }
        }

        // Direct emergency stop subscription: emergency phrase halts TTS immediately
        EventBus.shared.subscribe(EmergencyStopEvent.self) { [weak self] _ in
            self?.stop()
        }
    }

    // MARK: - Public API

    /// Pre-warm the speech synthesizer on startup so first audio starts in <50ms
    func warmup() {
        let dummy = AVSpeechUtterance(string: " ")
        dummy.volume = 0.0
        synthesizer.speak(dummy)
        synthesizer.stopSpeaking(at: .immediate)
        JarvisLogger.voice.info("TTSEngine warmed up")
    }

    /// Speak text using the appropriate mode.
    func speak(_ text: String, mode: TTSMode = .acknowledgement) {
        let cleaned = SpokenResponseLayer.cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }
        isExplicitlyStopped = false
        isStreamingActive = false
        streamingBuffer = ""

        // If currently speaking, stop immediately for new utterance
        if synthesizer.isSpeaking || synthesizer.isPaused {
            currentUtteranceText = nil
            synthesizer.stopSpeaking(at: .immediate)
        }

        switch mode {
        case .acknowledgement, .offline, .conversational:
            appleSpeak(cleaned)
        }
    }

    /// Begin a streaming TTS session.
    func beginStreaming(mode: TTSMode = .conversational) {
        isExplicitlyStopped = false
        isStreamingActive = true
        streamingBuffer = ""
        speakDispatchTime = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            currentUtteranceText = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Append incoming text delta, extracting and speaking complete sentences immediately.
    func appendStreamingChunk(_ delta: String) {
        guard isStreamingActive, !isExplicitlyStopped else { return }
        streamingBuffer.append(delta)

        // Split on sentence terminators: ". ", "? ", "! ", ".\n", "?\n", "!\n", "\n\n"
        while let match = findFirstSentenceBoundary(in: streamingBuffer) {
            let sentence = String(streamingBuffer[..<match.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            streamingBuffer = String(streamingBuffer[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty {
                enqueueUtterance(sentence)
            }
        }
    }

    /// Finish the streaming session, flushing any remaining sentence in the buffer.
    func finishStreaming() {
        guard isStreamingActive else { return }
        isStreamingActive = false
        let remaining = streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingBuffer = ""
        if !remaining.isEmpty && !isExplicitlyStopped {
            enqueueUtterance(remaining)
        }
    }

    private func enqueueUtterance(_ text: String) {
        let cleaned = SpokenResponseLayer.cleanForSpeech(text)
        guard !cleaned.isEmpty, !isExplicitlyStopped else { return }
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        currentUtteranceText = text
        if speakDispatchTime == nil {
            speakDispatchTime = CFAbsoluteTimeGetCurrent()
        }
        JarvisLogger.voice.info("Streaming TTS speaking chunk: '\(text, privacy: .public)'")
        synthesizer.speak(utterance)
    }

    private func findFirstSentenceBoundary(in str: String) -> Range<String.Index>? {
        let terminators: [String] = [". ", "? ", "! ", ".\n", "?\n", "!\n", "\n\n", ":\n", ";\n"]
        var earliestRange: Range<String.Index>? = nil
        for term in terminators {
            if let r = str.range(of: term) {
                if let current = earliestRange {
                    if r.lowerBound < current.lowerBound {
                        earliestRange = r
                    }
                } else {
                    earliestRange = r
                }
            }
        }
        return earliestRange
    }

    /// Stop speech immediately (barge-in / interrupt).
    func stop() {
        isExplicitlyStopped = true
        isStreamingActive = false
        streamingBuffer = ""
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        let start = CFAbsoluteTimeGetCurrent()
        synthesizer.stopSpeaking(at: .immediate)
        // AVSpeechSynthesizer's didCancel callback may be stale by the time it
        // arrives (currentUtteranceText is cleared before stop), so release the
        // semantic speaking overlay synchronously here.
        InteractionPhaseCenter.speechFinished()
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
            InteractionPhaseCenter.speechStarted()
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
            if !self.isStreamingActive && !self.synthesizer.isSpeaking {
                let completion = self.onSpeechFinished
                self.onSpeechFinished = nil
                completion?()
                InteractionPhaseCenter.speechFinished()
            }
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
            self.onSpeechFinished = nil
            InteractionPhaseCenter.speechFinished()
            JarvisLogger.voice.debug("TTS utterance was cancelled")
        }
    }
}
