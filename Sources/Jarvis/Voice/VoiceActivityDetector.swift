import Foundation
import AVFoundation

/// Real-time Voice Activity Detector (VAD) analyzing audio energy and zero-crossings.
/// Used to gate wake-word spotting and detect speech completion.
@MainActor
final class VoiceActivityDetector: @unchecked Sendable {
    static let shared = VoiceActivityDetector()

    // MARK: - Configuration
    struct Configuration: Sendable {
        var energyThreshold: Float = 0.015
        /// Short pause for a complete-sounding utterance; keeps voice actions snappy.
        var completedUtteranceSilence: TimeInterval = 0.30
        /// Shortest pause for recognized commands / deterministic actions
        var fastCommandSilence: TimeInterval = 0.22
        /// Longer pause when the live transcript appears to end mid-thought.
        var continuationSilence: TimeInterval = 0.75
        var minSpeechFrames: Int = 2  // Minimum speech frames to declare speech started (~128ms)

        // Compatibility/readability for existing diagnostics and tests.
        var hangoverFrames: Int { Int((completedUtteranceSilence / (1024.0 / 16_000.0)).rounded(.up)) }
    }

    // MARK: - State
    private(set) var isSpeaking = false
    var configuration = Configuration()

    // Internal tracking
    private var consecutiveSpeechFrames = 0
    private var silenceDuration: TimeInterval = 0
    private var latestPartialTranscript = ""

    // Handlers
    var onSpeechStart: (@MainActor @Sendable () -> Void)?
    var onSpeechEnd: (@MainActor @Sendable () -> Void)?

    private init() {}

    // MARK: - Audio Processing

    /// Process a PCM buffer and update speech state.
    /// Can be called on background audio tap thread.
    nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Calculate RMS Energy
        var sumSquares: Float = 0.0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        let duration = Double(frameCount) / buffer.format.sampleRate

        Task { @MainActor [weak self] in
            self?.handleEnergy(rms, duration: duration)
        }
    }

    /// Keep endpointing informed by the newest speech-recognition hypothesis.
    /// Audio remains ephemeral; only the current transcript string is retained.
    func updatePartialTranscript(_ transcript: String) {
        latestPartialTranscript = transcript
    }

    /// Reset internal state.
    func reset() {
        isSpeaking = false
        consecutiveSpeechFrames = 0
        silenceDuration = 0
        latestPartialTranscript = ""
    }

    // MARK: - Private

    private func handleEnergy(_ rms: Float, duration: TimeInterval) {
        let isFrameSpeech = rms >= configuration.energyThreshold

        if isFrameSpeech {
            consecutiveSpeechFrames += 1
            silenceDuration = 0

            if !isSpeaking && consecutiveSpeechFrames >= configuration.minSpeechFrames {
                isSpeaking = true
                JarvisLogger.voice.info("[VOICE_TRACE] VAD speech started (RMS: \(rms))")
                onSpeechStart?()
            }
        } else {
            silenceDuration += duration
            consecutiveSpeechFrames = 0

            let endpointDelay = Self.silenceNeeded(for: latestPartialTranscript, configuration: configuration)
            if isSpeaking && silenceDuration >= endpointDelay {
                isSpeaking = false
                silenceDuration = 0
                latestPartialTranscript = ""
                JarvisLogger.voice.info("[VOICE_TRACE] VAD speech ended")
                onSpeechEnd?()
            }
        }
    }

    /// Transcript-aware endpointing: short pauses for a likely complete command,
    /// with extra time for conjunctions/prepositions that commonly precede more speech.
    static func silenceNeeded(for transcript: String, configuration: Configuration = Configuration()) -> TimeInterval {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return configuration.continuationSilence }
        if let last = trimmed.last, ".!?".contains(last) {
            return configuration.completedUtteranceSilence
        }
        let lower = trimmed.lowercased()
        if DeterministicRouter.shared.match(lower) != nil {
            return configuration.fastCommandSilence
        }
        let lastWord = lower
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .last.map(String.init) ?? ""
        let continuationWords: Set<String> = ["and", "or", "but", "because", "if", "when", "while", "to", "for", "with", "about", "that", "the", "a", "an", "of", "into", "from", "on", "at"]
        return continuationWords.contains(lastWord)
            ? configuration.continuationSilence
            : configuration.completedUtteranceSilence
    }
}
