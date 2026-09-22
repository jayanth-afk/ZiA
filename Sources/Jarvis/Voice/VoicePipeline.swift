import Foundation

/// Master orchestrator for the JARVIS voice subsystem.
/// Coordinates AudioCapture, VAD, WakeWordDetector, SpeechRecognizer, and TTSEngine.
@MainActor
final class VoicePipeline {
    static let shared = VoicePipeline()

    private(set) var isRunning = false
    private var isSubscribed = false

    private init() {}

    // MARK: - Lifecycle

    /// Start the voice pipeline and subscribe to system events.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        setupEventSubscriptions()
        setupVADHandlers()

        // Sync with current state
        handleStateTransition(to: AppState.shared.state)
        JarvisLogger.voice.info("VoicePipeline initialized and active")
    }

    /// Stop the voice pipeline.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        AudioCapture.shared.stopCapturing()
        WakeWordDetector.shared.stopListening()
        SpeechRecognizer.shared.stopRecognition()
        TTSEngine.shared.stop()
        AudioPlayer.shared.stopPlayback()

        JarvisLogger.voice.info("VoicePipeline stopped")
    }

    // MARK: - Private Setup

    private func setupEventSubscriptions() {
        guard !isSubscribed else { return }
        isSubscribed = true

        // 1. AppState transitions
        EventBus.shared.subscribe(StateChangedEvent.self) { [weak self] event in
            self?.handleStateTransition(to: event.to)
        }

        // 2. Wake word detected
        EventBus.shared.subscribe(WakeWordDetectedEvent.self) { [weak self] _ in
            self?.handleWakeWordDetected()
        }

        // 3. Final transcript received
        EventBus.shared.subscribe(TranscriptFinalEvent.self) { [weak self] event in
            self?.handleFinalTranscript(event.text)
        }

        // 4. Emergency stop
        EventBus.shared.subscribe(EmergencyStopEvent.self) { [weak self] event in
            self?.handleEmergencyStop(phrase: event.phrase)
        }
    }

    private func setupVADHandlers() {
        let vad = VoiceActivityDetector.shared
        // Wire audio capture buffers to VAD
        AudioCapture.shared.addBufferHandler { buffer in
            vad.processBuffer(buffer)
        }

        // VAD speech start -> barge-in check
        VoiceActivityDetector.shared.onSpeechStart = { [weak self] in
            guard self != nil else { return }
            if TTSEngine.shared.isSpeaking || AudioPlayer.shared.isPlaying {
                EventBus.shared.publish(UserInterruptedEvent())
            }
        }

        // VAD speech end -> if in ACTIVE state, finish recognition
        VoiceActivityDetector.shared.onSpeechEnd = { [weak self] in
            guard self != nil else { return }
            if AppState.shared.state == .active && SpeechRecognizer.shared.isRecognizing {
                SpeechRecognizer.shared.stopRecognition()
            }
        }
    }

    // MARK: - Event Handlers

    private func handleStateTransition(to state: AppState.State) {
        JarvisLogger.voice.info("VoicePipeline handling transition to state: \(state.rawValue)")

        switch state {
        case .off:
            AudioCapture.shared.stopCapturing()
            WakeWordDetector.shared.stopListening()
            SpeechRecognizer.shared.stopRecognition()
            TTSEngine.shared.stop()

        case .sleep:
            SpeechRecognizer.shared.stopRecognition()
            WakeWordDetector.shared.startListening()

            // Ensure microphone is capturing in low-power listening mode
            if !AudioCapture.shared.isCapturing {
                do {
                    try AudioCapture.shared.startCapturing()
                } catch {
                    JarvisLogger.voice.error("Failed to start audio capture in SLEEP state: \(error.localizedDescription)")
                }
            }

        case .active:
            WakeWordDetector.shared.stopListening()
            AudioPlayer.shared.playChime(.wakeDetected)

            do {
                if !AudioCapture.shared.isCapturing {
                    try AudioCapture.shared.startCapturing()
                }
                try SpeechRecognizer.shared.startRecognition()
            } catch {
                JarvisLogger.voice.error("Failed to start active speech recognition: \(error.localizedDescription)")
            }
        }
    }

    private func handleWakeWordDetected() {
        if AppState.shared.state == .sleep {
            AppState.shared.transition(to: .active)
        }
    }

    private func handleFinalTranscript(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else {
            AppState.shared.transition(to: .sleep)
            return
        }

        JarvisLogger.voice.info("Processing command: '\(text)'")

        Task { @MainActor in
            let response: String
            do {
                response = try await BrainRouter.shared.route(cleaned)
            } catch {
                response = "Sorry, I encountered an issue: \(error.localizedDescription)"
            }

            TTSEngine.shared.speak(response, mode: .acknowledgement)

            // Reset to SLEEP state once finished speaking
            TTSEngine.shared.onSpeechFinished = {
                Task { @MainActor in
                    if AppState.shared.state == .active {
                        AppState.shared.transition(to: .sleep)
                    }
                }
            }
        }
    }

    private func handleEmergencyStop(phrase: String) {
        JarvisLogger.security.warning("Emergency stop handled in pipeline: '\(phrase)'")
        if AppState.shared.state == .active {
            AppState.shared.transition(to: .sleep)
        }
    }

    // MARK: - Fallback Query Handlers

    private func generateFallbackResponse(for query: String) -> String {
        if query.contains("who are you") || query.contains("what are you") {
            return "I am JARVIS, your personal macOS assistant."
        } else if query.contains("how are you") {
            return "All systems operational."
        } else {
            return "Heard: \(query)."
        }
    }
}
