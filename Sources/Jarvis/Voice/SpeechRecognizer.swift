import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

/// Apple Speech framework wrapper for local, low-latency speech-to-text.
/// Strictly enforces on-device recognition for zero cloud dependency.
@MainActor
final class SpeechRecognizer: NSObject, @unchecked Sendable {
    static let shared = SpeechRecognizer()

    // MARK: - State
    private(set) var isRecognizing = false
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Audio capture tap token
    private var tapToken: UUID?

    // Active session timing
    private(set) var currentTimer: PipelineTimer?

    // Thread-safe request holder for audio tap
    private nonisolated(unsafe) var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()

    // Restart durability for continuous listening (SLEEP state)
    private var lastSessionStart: Date?
    private var restartAttempt = 0

    // MARK: - Dead-session watchdog + Apple Speech fallback ladder
    //
    // Diagnostic finding (real-mic test): when `requiresOnDeviceRecognition
    // = true` cannot be honored on this system, the local recognition client
    // (SFLocalSpeechRecognitionClient) is invalidated at session start and
    // dealloc'd — no error is ever reported to the recognition callback, and
    // no partial/final ever arrives. The forced on-device session dies
    // silently while `isRecognizing` stays true.
    //
    // Response: (1) a watchdog proves liveness by requiring evidence of real
    // speech recognition (partials/finals) after speech has been detected;
    // (2) if the forced on-device session is dead, the session is rebuilt
    // once without the forced flag (Apple Speech, default mode — server-
    // assisted, still no Whisper / no new framework); (3) VOICE_TRACE logs
    // make every stage observable.
    /// True once the current/last session produced any partial or final.
    private var sessionSawRecognition = false
    /// One-time fallback: forced on-device -> Apple Speech default mode.
    private var hasFallbackToDefaultRecognition = false
    /// Set when the watchdog proves a session was dead (for audit honesty).
    private var lastFailureReason: String?

    /// VOICE_TRACE: labeled diagnostic logging (transcripts appear in logs for
    /// this diagnostic build — clearly labeled, temporary).
    private func trace(_ line: String) {
        JarvisLogger.voice.info("[VOICE_TRACE] \(line, privacy: .public)")
    }

    private override init() {
        super.init()
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Permissions

    enum AuthorizationStatus: String, Sendable, CaseIterable {
        case authorized = "Authorized"
        case denied = "Denied"
        case restricted = "Restricted"
        case notDetermined = "Not Determined"
        case unavailable = "Unavailable"
    }

    /// Whether Apple Speech reports on-device recognition support for the locale.
    /// Exposed for VOICE_TRACE startup evidence (Phase 5 diagnostics).
    var supportsOnDeviceRecognition: Bool {
        speechRecognizer?.supportsOnDeviceRecognition ?? false
    }

    /// Whether the recognizer is currently available (locale assets loaded, service reachable).
    var recognizerAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    /// Synchronously query current Speech Recognition authorization status without prompting TCC.
    var authorizationStatus: AuthorizationStatus {
        guard Bundle.main.infoDictionary?["NSSpeechRecognitionUsageDescription"] != nil else {
            return .unavailable
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    /// Request speech recognition authorization.
    func requestAuthorization() async -> Bool {
        guard Bundle.main.infoDictionary?["NSSpeechRecognitionUsageDescription"] != nil else {
            JarvisLogger.voice.warning("Skipping requestAuthorization: NSSpeechRecognitionUsageDescription not found in bundle Info.plist")
            return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Inject a simulated transcript directly into the pipeline.
    /// Used for deterministic automated self-tests, offline validation, and behavioral proofs.
    func simulateTranscript(_ text: String, isFinal: Bool, durationMs: Double = 10.0) {
        if isFinal {
            JarvisLogger.voice.info("Simulated final transcript (\(durationMs)ms): '\(text)'")
            EventBus.shared.publish(TranscriptFinalEvent(text: text, durationMs: durationMs))
            EmergencyInterrupt.shared.checkForEmergency(in: text)
        } else {
            JarvisLogger.voice.debug("Simulated partial transcript: '\(text)'")
            EventBus.shared.publish(TranscriptPartialEvent(text: text))
            WakeWordDetector.shared.checkForWakeWord(in: text)
            EmergencyInterrupt.shared.checkForEmergency(in: text)
        }
    }

    // MARK: - Recognition Control

    /// Start a continuous streaming recognition session.
    func startRecognition(timer: PipelineTimer? = nil) throws {
        guard !isRecognizing else { return }

        // TCC safety: never attempt speech recognition if the bundle lacks usage description
        guard Bundle.main.infoDictionary?["NSSpeechRecognitionUsageDescription"] != nil else {
            JarvisLogger.voice.warning("Skipping startRecognition: NSSpeechRecognitionUsageDescription not found in bundle Info.plist")
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            JarvisLogger.voice.error("SFSpeechRecognizer is unavailable")
            throw JarvisError.speechRecognitionDenied
        }

        self.currentTimer = timer ?? PipelineTimer(id: UUID().uuidString)
        self.currentTimer?.mark(.sttStart)
        self.lastSessionStart = Date()
        self.sessionSawRecognition = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Session mode: forced on-device first (zero-cloud). If a dead session
        // is ever proven (see handleDeadSession), the fallback ladder rebuilds
        // the session once in Apple Speech DEFAULT mode (still Apple Speech —
        // no Whisper, no new framework).
        let forceOnDevice = !hasFallbackToDefaultRecognition
        if forceOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            self.trace("STT started (mode: forced on-device)")
        } else {
            if forceOnDevice {
                JarvisLogger.voice.warning("On-device recognition unsupported for current locale; using Apple Speech default mode")
            }
            self.trace("STT started (mode: Apple Speech default)")
        }

        requestLock.lock()
        self.currentRequest = request
        requestLock.unlock()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }

        // Tap into AudioCapture buffers
        tapToken = AudioCapture.shared.addBufferHandler { [weak self] buffer in
            self?.appendCapturedBuffer(buffer)
        }

        isRecognizing = true
        JarvisLogger.voice.info("Speech recognition session started")
    }

    // MARK: - Dead-session recovery (one-time Apple Speech fallback)

    /// Called when a session provably produced nothing despite real speech:
    /// VAD detected speech onset AND end during the session, but not a single
    /// partial or final arrived, and no error was ever reported. This is the
    /// observed signature of a forced on-device session being invalidated at
    /// start (SFLocalSpeechRecognitionClient Invalidated/dealloc). Recovery:
    /// rebuild once in Apple Speech default mode.
    private func handleDeadSession() {
        let mode = hasFallbackToDefaultRecognition ? "default" : "forced on-device"
        lastFailureReason = "STT session dead (mode: \(mode)): real speech detected, zero recognition output, no error reported"
        self.trace("DEAD SESSION detected (mode: \(mode)) — mic audio + VAD speech present, no partials/finals")
        JarvisLogger.voice.error("\(self.lastFailureReason ?? "unknown", privacy: .public)")

        if !hasFallbackToDefaultRecognition {
            hasFallbackToDefaultRecognition = true
            trace("FALLBACK: rebuilding session in Apple Speech default mode (one-time)")
            if AppState.shared.state != .off, authorizationStatus == .authorized {
                do {
                    try startRecognition()
                    return
                } catch {
                    JarvisLogger.voice.error("Fallback restart failed: \(error.localizedDescription)")
                }
            }
        }

        // Fallback already used or unavailable: the VAD onset handler will
        // re-engage recognition on the next spoken utterance.
        trace("DEAD SESSION: fallback unavailable; VAD will re-engage recognition on next speech onset")
    }

    /// Clean up a dead session (engine already ended it) and schedule a
    /// restart with exponential backoff. Backoff resets after any session that
    /// ran healthily for >5s, so silence never permanently disables listening.
    private func restartAfterTransientFailure(code: Int) {
        // Engine already terminated this task; release the tap and request.
        if let token = tapToken {
            AudioCapture.shared.removeBufferHandler(token)
            tapToken = nil
        }
        requestLock.lock()
        self.currentRequest = nil
        requestLock.unlock()
        recognitionTask = nil
        isRecognizing = false

        if let start = lastSessionStart, Date().timeIntervalSince(start) > 5 {
            restartAttempt = 0
        }
        let delay = min(0.8 * pow(2.0, Double(restartAttempt)), 10.0)
        restartAttempt += 1

        JarvisLogger.voice.info("Restarting recognition in \(String(format: "%.1f", delay))s after transient error \(code)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isRecognizing else { return }
            guard AppState.shared.state != .off else { return }
            guard self.authorizationStatus == .authorized else { return }
            do {
                try self.startRecognition()
            } catch {
                JarvisLogger.voice.error("Recognition restart failed: \(error.localizedDescription)")
            }
        }
    }

    /// Append a single audio buffer manually (used by tests or alternate sources).
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        appendCapturedBuffer(buffer)
    }

    /// Complete current speech recognition session and process final result.
    func stopRecognition() {
        guard isRecognizing else { return }

        if let token = tapToken {
            AudioCapture.shared.removeBufferHandler(token)
            tapToken = nil
        }

        requestLock.lock()
        let req = currentRequest
        self.currentRequest = nil
        requestLock.unlock()

        req?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        isRecognizing = false

        JarvisLogger.voice.info("Speech recognition session stopped")

        // Dead-session probe (deterministic, VAD-gated design): a complete
        // spoken utterance happened during this session but the recognizer
        // produced nothing at all — the session was provably dead.
        let sessionStart = lastSessionStart ?? Date.distantPast
        if !sessionSawRecognition,
           VoiceTraceState.shared.hasSpeech(since: sessionStart),
           VoiceTraceState.shared.hasSpeechEnd(since: sessionStart) {
            handleDeadSession()
        }
    }

    /// Cancel current recognition session without emitting final result.
    func cancelRecognition() {
        if let token = tapToken {
            AudioCapture.shared.removeBufferHandler(token)
            tapToken = nil
        }

        requestLock.lock()
        let req = currentRequest
        self.currentRequest = nil
        requestLock.unlock()

        req?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false

        JarvisLogger.voice.info("Speech recognition cancelled")
    }

    // MARK: - Private Helpers

    nonisolated private func appendCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        let req = currentRequest
        requestLock.unlock()
        req?.append(buffer)
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            // Error code 216 is recognition cancelled; ignore it cleanly
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                return
            }
            JarvisLogger.voice.error("Speech recognition error (\(nsError.code)): \(error.localizedDescription)")

            // Transient/no-speech failures (1101 no speech, 203 service retry,
            // 1110 locale/session end) terminate the session in the engine.
            // Clean up and restart with backoff so continuous listening in
            // SLEEP stays durable instead of silently dying on silence.
            if nsError.domain == "kAFAssistantErrorDomain",
               [1101, 203, 1110, 1103].contains(nsError.code) {
                self.restartAfterTransientFailure(code: nsError.code)
            }
            return
        }

        guard let result = result else { return }
        let transcript = result.bestTranscription.formattedString

        if result.isFinal {
            sessionSawRecognition = true
            currentTimer?.mark(.sttFinal)
            let elapsedMs = currentTimer?.elapsed(from: .sttStart, to: .sttFinal) ?? 0

            JarvisLogger.voice.info("Final transcript (\(String(format: "%.1f", elapsedMs), privacy: .public)ms): '\(transcript, privacy: .public)'")
            EventBus.shared.publish(TranscriptFinalEvent(text: transcript, durationMs: elapsedMs))

            // Check emergency phrases immediately
            EmergencyInterrupt.shared.checkForEmergency(in: transcript)

            // VOICE_TRACE
            self.trace("STT final: '\(transcript)'")

            stopRecognition()
        } else {
            sessionSawRecognition = true
            if currentTimer?.elapsed(from: .sttStart, to: .sttFirstPartial) == nil {
                currentTimer?.mark(.sttFirstPartial)
                if let partialMs = currentTimer?.elapsed(from: .sttStart, to: .sttFirstPartial) {
                    self.trace("STT first partial (\(String(format: "%.1f", partialMs))ms): '\(transcript)'")
                }
            } else {
                self.trace("STT partial: '\(transcript)'")
            }
            EventBus.shared.publish(TranscriptPartialEvent(text: transcript))

            // Wake word and emergency check on partial transcript for fastest response
            WakeWordDetector.shared.checkForWakeWord(in: transcript)
            EmergencyInterrupt.shared.checkForEmergency(in: transcript)
        }
    }
}
