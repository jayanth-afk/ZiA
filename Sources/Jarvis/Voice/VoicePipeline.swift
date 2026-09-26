import Foundation

/// Master orchestrator for the JARVIS voice subsystem.
/// Coordinates AudioCapture, VAD, WakeWordDetector, SpeechRecognizer, and TTSEngine.
@MainActor
final class VoicePipeline {
    static let shared = VoicePipeline()

    private(set) var isRunning = false
    private var isSubscribed = false

    // MARK: - Pipeline Status
    struct PipelineStatus: Sendable {
        let isRunning: Bool
        let appState: AppState.State
        let micAuthorization: AudioCapture.AuthorizationStatus
        let speechAuthorization: SpeechRecognizer.AuthorizationStatus
        let isCapturingAudio: Bool
        let isRecognizingSpeech: Bool
        let isSpeakingTTS: Bool
        let activeBackgroundTasksCount: Int

        var isFullyOperational: Bool {
            micAuthorization == .authorized && speechAuthorization == .authorized
        }
    }

    var status: PipelineStatus {
        PipelineStatus(
            isRunning: isRunning,
            appState: AppState.shared.state,
            micAuthorization: AudioCapture.shared.authorizationStatus,
            speechAuthorization: SpeechRecognizer.shared.authorizationStatus,
            isCapturingAudio: AudioCapture.shared.isCapturing,
            isRecognizingSpeech: SpeechRecognizer.shared.isRecognizing,
            isSpeakingTTS: TTSEngine.shared.isSpeaking,
            activeBackgroundTasksCount: activeBackgroundTasks.count
        )
    }

    /// Internal setter so same-module test harnesses (--physical-test) can
    /// register simulated background tasks; production code never mutates it.
    private(set) var activeBackgroundTasks: [String: Task<Void, Never>] = [:]
    internal func registerBackgroundTaskForTesting(_ id: String, _ task: Task<Void, Never>) {
        activeBackgroundTasks[id] = task
    }

    private init() {}

    // MARK: - Lifecycle

    /// Start the voice pipeline and subscribe to system events.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        EmergencyInterrupt.shared.registerProductionSubscribers()
        setupEventSubscriptions()
        setupVADHandlers()

        // Request TCC permissions on first launch so macOS presents the normal
        // permission dialogs (bundle .app GUI mode only — not during CLI/self-test).
        // Statuses are always re-read from the system afterwards — never assumed.
        let isBundled = Bundle.main.infoDictionary?["CFBundleIdentifier"] != nil
        let isCLI = CommandLine.arguments.contains(where: { $0.hasPrefix("--") })
        if isBundled && !isCLI {
            if AudioCapture.shared.authorizationStatus == .notDetermined {
                Task { @MainActor in
                    let granted = await AudioCapture.shared.requestPermission()
                    JarvisLogger.voice.info("Microphone permission \(granted ? "granted" : "denied") by user")
                    if granted, self.isRunning, AppState.shared.state != .off {
                        self.handleStateTransition(to: AppState.shared.state)
                    }
                }
            }
            if SpeechRecognizer.shared.authorizationStatus == .notDetermined {
                Task { @MainActor in
                    let granted = await SpeechRecognizer.shared.requestAuthorization()
                    JarvisLogger.voice.info("Speech recognition permission \(granted ? "granted" : "denied") by user")
                    if granted, self.isRunning, AppState.shared.state != .off {
                        self.handleStateTransition(to: AppState.shared.state)
                    }
                }
            }
        }

        // Sync with current state
        handleStateTransition(to: AppState.shared.state)
        JarvisLogger.voice.info("VoicePipeline initialized and active")

        // VOICE_TRACE: one-time startup evidence — environment + TCC reality.
        // (Permission request Tasks above may still be pending; statuses here
        // are re-logged again after those resolve via handleStateTransition.)
        let bundled = Bundle.main.infoDictionary?["CFBundleIdentifier"] != nil
        JarvisLogger.voice.info("[VOICE_TRACE] startup: bundled=\(bundled) micAuth=\(AudioCapture.shared.authorizationStatus.rawValue) sttAuth=\(SpeechRecognizer.shared.authorizationStatus.rawValue) onDeviceSupport=\(SpeechRecognizer.shared.supportsOnDeviceRecognition) recognizerAvailable=\(SpeechRecognizer.shared.recognizerAvailable)")
    }

    /// Stop the voice pipeline.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        for (_, task) in activeBackgroundTasks {
            task.cancel()
        }
        activeBackgroundTasks.removeAll()

        AudioCapture.shared.stopCapturing()
        WakeWordDetector.shared.stopListening()
        SpeechRecognizer.shared.stopRecognition()
        TTSEngine.shared.stop()
        AudioPlayer.shared.stopPlayback()

        JarvisLogger.voice.info("VoicePipeline stopped")
    }

    // MARK: - Event Setup

    func setupEventSubscriptions() {
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

        // VAD speech start -> barge-in check (halts audio output, never cancels background task)
        VoiceActivityDetector.shared.onSpeechStart = { [weak self] in
            guard self != nil else { return }
            VoiceTraceState.shared.markSpeechStart()
            JarvisLogger.voice.info("[VOICE_TRACE] VAD speech onset → engage recognition")
            if TTSEngine.shared.isSpeaking || AudioPlayer.shared.isPlaying {
                EventBus.shared.publish(UserInterruptedEvent())
            }

            // In SLEEP state, start speech recognition on speech onset to spot wake word and commands
            if AppState.shared.state == .sleep && !SpeechRecognizer.shared.isRecognizing {
                if SpeechRecognizer.shared.authorizationStatus == .authorized {
                    do {
                        try SpeechRecognizer.shared.startRecognition()
                        JarvisLogger.voice.debug("VAD speech onset in SLEEP -> engaged SpeechRecognizer")
                    } catch {
                        JarvisLogger.voice.error("Failed to start speech recognition on VAD onset: \(error.localizedDescription)")
                    }
                }
            }
        }

        // VAD speech end -> if recognizing, finish recognition to emit final transcript
        VoiceActivityDetector.shared.onSpeechEnd = { [weak self] in
            guard self != nil else { return }
            VoiceTraceState.shared.markSpeechEnd()
            JarvisLogger.voice.info("[VOICE_TRACE] VAD speech end")
            if SpeechRecognizer.shared.isRecognizing {
                SpeechRecognizer.shared.stopRecognition()
            }
        }
    }

    /// Request microphone and speech recognition permissions if needed (only when running in an app bundle).
    func requestPermissionsIfNeeded() async {
        let isBundled = Bundle.main.infoDictionary?["CFBundleIdentifier"] != nil
        let isCLI = CommandLine.arguments.contains(where: { $0.hasPrefix("--") })
        guard isBundled, !isCLI else {
            JarvisLogger.voice.info("Running in CLI or test mode; skipping interactive TCC prompt")
            return
        }

        if AudioCapture.shared.authorizationStatus == .notDetermined {
            JarvisLogger.voice.info("Requesting microphone permission via TCC...")
            _ = await AudioCapture.shared.requestPermission()
        }

        if SpeechRecognizer.shared.authorizationStatus == .notDetermined {
            JarvisLogger.voice.info("Requesting speech recognition permission via TCC...")
            _ = await SpeechRecognizer.shared.requestAuthorization()
        }

        // Re-evaluate state after permissions are determined
        handleStateTransition(to: AppState.shared.state)
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
            WakeWordDetector.shared.startListening()

            // SLEEP listening is VAD-gated (see setupVADHandlers): recognition
            // starts on speech onset and ends on speech end. No continuous
            // session here — the VAD onset handler owns session creation.

            // Ensure microphone is capturing in low-power listening mode if authorized
            if AudioCapture.shared.authorizationStatus == .authorized {
                if !AudioCapture.shared.isCapturing {
                    do {
                        try AudioCapture.shared.startCapturing()
                    } catch {
                        JarvisLogger.voice.error("Failed to start audio capture in SLEEP state: \(error.localizedDescription)")
                    }
                }
            } else {
                JarvisLogger.voice.warning("Microphone not authorized (\(AudioCapture.shared.authorizationStatus.rawValue)); AudioCapture idle in SLEEP state")
            }

        case .active:
            WakeWordDetector.shared.stopListening()
            AudioPlayer.shared.playChime(.wakeDetected)

            if AudioCapture.shared.authorizationStatus == .authorized {
                if !AudioCapture.shared.isCapturing {
                    do {
                        try AudioCapture.shared.startCapturing()
                    } catch {
                        JarvisLogger.voice.error("Failed to start audio capture in ACTIVE state: \(error.localizedDescription)")
                    }
                }
            } else {
                JarvisLogger.voice.warning("Microphone not authorized (\(AudioCapture.shared.authorizationStatus.rawValue)); AudioCapture unavailable in ACTIVE state")
            }

            if SpeechRecognizer.shared.authorizationStatus == .authorized {
                do {
                    try SpeechRecognizer.shared.startRecognition()
                } catch {
                    JarvisLogger.voice.error("Failed to start active speech recognition: \(error.localizedDescription)")
                }
            } else {
                JarvisLogger.voice.warning("Speech recognition not authorized (\(SpeechRecognizer.shared.authorizationStatus.rawValue)); recognition unavailable in ACTIVE state")
            }
        }
    }

    private func handleWakeWordDetected() {
        if AppState.shared.state == .sleep {
            AppState.shared.transition(to: .active)
        }
    }

    /// Test entry point (used by `--physical-test`): dispatch a spoken-command
    /// transcript through the pipeline exactly as if Apple Speech had finalized
    /// it. Injection point for deterministic verification of the command path.
    func handleSpokenCommand(_ text: String) {
        handleFinalTranscript(text)
    }

    private func handleFinalTranscript(_ text: String) {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Apple Speech finals carry natural punctuation ("jarvis, what time is it?").
        // The deterministic router is an exact-command matcher — strip trailing
        // sentence punctuation here in the voice layer before routing.
        while let last = cleaned.last, ".?!".contains(last) {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty else {
            if AppState.shared.state == .active {
                AppState.shared.transition(to: .sleep)
            }
            return
        }

        JarvisLogger.voice.info("Processing command: '\(text, privacy: .public)'")

        // 1. Emergency stop check (deterministic, 0ms LLM)
        if EmergencyInterrupt.shared.checkForEmergency(in: cleaned) {
            return
        }

        // 2. Wake-word gating in SLEEP state:
        // When in SLEEP, require the wake word ("jarvis") to transition to ACTIVE and process the command.
        // If wake word is absent, ignore the ambient room utterance.
        let wakeWord = Config.shared.wakeWord.lowercased()
        if AppState.shared.state == .sleep {
            if cleaned.contains(wakeWord) || cleaned.hasPrefix(wakeWord) {
                JarvisLogger.voice.info("Wake word '\(wakeWord, privacy: .public)' recognized in SLEEP state: '\(text, privacy: .public)'")
                AppState.shared.transition(to: .active)
                AudioPlayer.shared.playChime(.wakeDetected)
            } else {
                JarvisLogger.voice.debug("Utterance in SLEEP state ignored (wake word '\(wakeWord, privacy: .public)' not detected): '\(text, privacy: .public)'")
                return
            }
        }

        // 2. Deterministic router check (instant system action, 0ms LLM)
        if let match = DeterministicRouter.shared.match(cleaned) {
            let timer = SpeechRecognizer.shared.currentTimer
            timer?.mark(.deterministicRouterHit)
            timer?.mark(.actionStart)
            JarvisLogger.voice.info("Voice command matched deterministic intent: \(match.intent, privacy: .public)")
            Task { @MainActor in
                do {
                    let actionStart = CFAbsoluteTimeGetCurrent()
                    let result = try await ActionEngine.shared.execute(
                        intent: match.intent,
                        isDeterministic: true,
                        impact: match.impact,
                        action: match.action
                    )
                    let actionMs = (CFAbsoluteTimeGetCurrent() - actionStart) * 1000.0
                    timer?.mark(.actionExecuted)
                    timer?.mark(.ttsStart)
                    JarvisLogger.voice.info("ActionEngine completed '\(match.intent, privacy: .public)' in \(String(format: "%.2f", actionMs), privacy: .public)ms: '\(result, privacy: .public)'")
                    TTSEngine.shared.speak(result, mode: .acknowledgement)
                } catch {
                    TTSEngine.shared.speak("Action failed: \(error.localizedDescription)", mode: .acknowledgement)
                }
            }
            // Return voice loop to SLEEP (listening) immediately
            if AppState.shared.state == .active {
                AppState.shared.transition(to: .sleep)
            }
            return
        }

        // 3. Deep / LLM task: Deterministic acknowledgement first (Requirement G)
        JarvisLogger.voice.info("[VOICE_TRACE] no deterministic match — dispatching to BrainRouter (LLM path)")
        TTSEngine.shared.speak("On it.", mode: .acknowledgement)

        // 4. Asynchronous task execution decoupled from voice loop (Requirement F & H)
        let taskID = UUID().uuidString
        let bgTask = Task { @MainActor [weak self] in
            defer {
                self?.activeBackgroundTasks.removeValue(forKey: taskID)
            }
            do {
                let response = try await BrainRouter.shared.route(cleaned)
                guard !Task.isCancelled else { return }
                TTSEngine.shared.speak(response, mode: .conversational)
            } catch is CancellationError {
                JarvisLogger.voice.info("Voice background task \(taskID) cancelled")
            } catch {
                guard !Task.isCancelled else { return }
                TTSEngine.shared.speak("Sorry, I encountered an issue: \(error.localizedDescription)", mode: .acknowledgement)
            }
        }
        activeBackgroundTasks[taskID] = bgTask

        // 5. Release voice interaction clock immediately (INTERACTION CLOCK != TASK CLOCK)
        // Transition back to SLEEP so user can speak again while background task runs.
        if AppState.shared.state == .active {
            AppState.shared.transition(to: .sleep)
        }
    }

    private func handleEmergencyStop(phrase: String) {
        JarvisLogger.security.warning("Emergency stop handled in pipeline: '\(phrase)'")
        // Cancel all active voice-initiated background tasks immediately
        for (id, task) in activeBackgroundTasks {
            JarvisLogger.voice.info("Cancelling background task \(id) due to emergency stop")
            task.cancel()
        }
        activeBackgroundTasks.removeAll()

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
