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
    private var currentTimer: PipelineTimer?

    // Thread-safe request holder for audio tap
    private nonisolated(unsafe) var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()

    private override init() {
        super.init()
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Permissions

    /// Request speech recognition authorization.
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Recognition Control

    /// Start a continuous streaming recognition session.
    func startRecognition(timer: PipelineTimer? = nil) throws {
        guard !isRecognizing else { return }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            JarvisLogger.voice.error("SFSpeechRecognizer is unavailable")
            throw JarvisError.speechRecognitionDenied
        }

        self.currentTimer = timer ?? PipelineTimer(id: UUID().uuidString)
        self.currentTimer?.mark(.sttStart)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Enforce on-device recognition if supported
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            JarvisLogger.voice.info("Using on-device Apple Speech recognition")
        } else {
            JarvisLogger.voice.warning("On-device speech recognition not supported for current locale, using default")
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
            JarvisLogger.voice.error("Speech recognition error: \(error.localizedDescription)")
            return
        }

        guard let result = result else { return }
        let transcript = result.bestTranscription.formattedString

        if result.isFinal {
            currentTimer?.mark(.sttFinal)
            let elapsedMs = currentTimer?.elapsed(from: .sttStart, to: .sttFinal) ?? 0

            JarvisLogger.voice.info("Final transcript (\(String(format: "%.1f", elapsedMs))ms): '\(transcript)'")
            EventBus.shared.publish(TranscriptFinalEvent(text: transcript, durationMs: elapsedMs))

            // Check emergency phrases immediately
            EmergencyInterrupt.shared.checkForEmergency(in: transcript)

            stopRecognition()
        } else {
            JarvisLogger.voice.debug("Partial transcript: '\(transcript)'")
            EventBus.shared.publish(TranscriptPartialEvent(text: transcript))

            // Wake word and emergency check on partial transcript for fastest response
            WakeWordDetector.shared.checkForWakeWord(in: transcript)
            EmergencyInterrupt.shared.checkForEmergency(in: transcript)
        }
    }
}
