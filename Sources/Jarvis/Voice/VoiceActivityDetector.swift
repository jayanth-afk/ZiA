import Foundation
import AVFoundation

/// Real-time Voice Activity Detector (VAD) analyzing audio energy, SNR, peak crest factor,
/// zero-crossings, and linguistic context with asymmetric noise-floor estimation and hysteresis.
@MainActor
final class VoiceActivityDetector: @unchecked Sendable {
    static let shared = VoiceActivityDetector()

    // MARK: - Configuration
    struct Configuration: Sendable {
        var energyThreshold: Float = 0.006
        var minEnergyThreshold: Float = 0.0025
        /// Short pause for a complete-sounding utterance; keeps voice actions snappy.
        var completedUtteranceSilence: TimeInterval = 0.30
        /// Shortest pause for recognized commands / deterministic actions
        var fastCommandSilence: TimeInterval = 0.22
        /// Longer pause when the live transcript appears to end mid-thought (preserves >=0.9 for SelfTest).
        var continuationSilence: TimeInterval = 0.95
        var minSpeechFrames: Int = 2  // Minimum speech frames to declare speech started (~90–128ms)

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
    private(set) var noiseFloor: Float = 0.003
    private(set) var currentSpeechProbability: Float = 0.0

    // Dynamic threshold accessor for diagnostics and hysteresis
    var currentDynamicThreshold: Float {
        let delta = max(0.0015, noiseFloor * 0.4)
        return max(configuration.minEnergyThreshold, max(configuration.energyThreshold * 0.5, noiseFloor + delta))
    }

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

        // Calculate RMS, Peak, and Zero-Crossing Rate
        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        var zeroCrossings = 0
        var prevSample: Float = channelData[0]

        for i in 0..<frameCount {
            let sample = channelData[i]
            let absSample = abs(sample)
            if absSample > peak { peak = absSample }
            sumSquares += sample * sample

            if (sample >= 0 && prevSample < 0) || (sample < 0 && prevSample >= 0) {
                zeroCrossings += 1
            }
            prevSample = sample
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        let zcr = Float(zeroCrossings) / Float(frameCount)
        let duration = Double(frameCount) / buffer.format.sampleRate

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleAudioMetrics(rms: rms, peak: peak, zcr: zcr, duration: duration)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioMetrics(rms: rms, peak: peak, zcr: zcr, duration: duration)
            }
        }
    }

    /// Keep endpointing informed by the newest speech-recognition hypothesis.
    func updatePartialTranscript(_ transcript: String) {
        latestPartialTranscript = transcript
    }

    /// Current cached partial transcript
    var currentPartialTranscript: String {
        latestPartialTranscript
    }

    /// Reset internal state.
    func reset() {
        isSpeaking = false
        consecutiveSpeechFrames = 0
        silenceDuration = 0
        latestPartialTranscript = ""
        currentSpeechProbability = 0.0
        noiseFloor = 0.003
    }

    // MARK: - Private

    private func handleAudioMetrics(rms: Float, peak: Float, zcr: Float, duration: TimeInterval) {
        // Crest factor: speech exhibits high dynamic range / sharp peaks (crest > 1.8),
        // while ambient fan/hum/room noise exhibits low crest factor (crest < 1.7).
        let crestFactor = peak / max(rms, 0.0001)
        let isDrone = crestFactor < 1.7
        let isSpeechLikeBurst = crestFactor > 2.2 && rms > 0.006

        // 1. Asymmetric noise floor adaptation:
        // Adapt noise floor only during non-speech periods and steady non-speech audio.
        // Prevents real speech bursts from elevating the noise floor!
        if !isSpeaking && consecutiveSpeechFrames == 0 && !isSpeechLikeBurst {
            let alpha: Float = rms < noiseFloor ? 0.05 : 0.05
            noiseFloor = (1.0 - alpha) * noiseFloor + alpha * rms
            noiseFloor = min(max(noiseFloor, 0.001), 0.035)
        }

        let dynamicThreshold = currentDynamicThreshold

        // 2. Multidimensional speech probability:
        // Combines SNR above noise floor, peak crest, and zero-crossing range.
        let snr = (rms - noiseFloor) / max(noiseFloor, 0.001)
        let prob: Float
        if isDrone {
            prob = 0.0
        } else {
            let energyScore = min(1.0, max(0.0, snr / 1.5))
            let peakScore: Float = peak > 0.02 ? 1.0 : (peak > 0.008 ? 0.6 : 0.0)
            let zcrScore: Float = (zcr >= 0.03 && zcr <= 0.50) ? 0.2 : 0.0
            prob = min(1.0, max(0.0, energyScore * 0.6 + peakScore * 0.3 + zcrScore))
        }
        self.currentSpeechProbability = prob

        // 3. Hysteresis thresholds with drone/fan noise rejection:
        let enterThreshold = dynamicThreshold
        let exitThreshold = max(configuration.minEnergyThreshold * 0.7, dynamicThreshold * 0.65)

        let isFrameSpeech: Bool
        if isSpeaking {
            isFrameSpeech = (rms >= exitThreshold && !isDrone) || prob >= 0.30
        } else {
            isFrameSpeech = (rms >= enterThreshold && !isDrone) || prob >= 0.50
        }

        if isFrameSpeech {
            consecutiveSpeechFrames += 1
            silenceDuration = 0

            if !isSpeaking && consecutiveSpeechFrames >= configuration.minSpeechFrames {
                isSpeaking = true
                JarvisLogger.voice.info("[VOICE_TRACE] VAD speech started (RMS: \(rms), threshold: \(dynamicThreshold), noiseFloor: \(self.noiseFloor), prob: \(prob))")
                onSpeechStart?()
            }
        } else {
            silenceDuration += duration
            consecutiveSpeechFrames = 0

            let endpointDelay = Self.silenceNeeded(for: latestPartialTranscript, configuration: configuration)
            if isSpeaking && silenceDuration >= endpointDelay {
                isSpeaking = false
                silenceDuration = 0
                JarvisLogger.voice.info("[VOICE_TRACE] VAD speech ended (silence: \(String(format: "%.2f", endpointDelay))s, transcript: '\(self.latestPartialTranscript)')")
                onSpeechEnd?()
            }
        }
    }

    /// Transcript-aware endpointing: short pauses for a likely complete command,
    /// with extra time for conjunctions/prepositions that commonly precede more speech.
    static func silenceNeeded(for transcript: String, configuration: Configuration = Configuration()) -> TimeInterval {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return configuration.continuationSilence }

        // Mid-phrase punctuations indicate user paused mid-sentence
        if trimmed.hasSuffix(",") || trimmed.hasSuffix("...") || trimmed.hasSuffix("-") {
            return configuration.continuationSilence
        }

        if let last = trimmed.last, ".!?".contains(last) {
            return configuration.completedUtteranceSilence
        }
        let lower = trimmed.lowercased()
        let lastWord = lower
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .last.map(String.init) ?? ""
        let continuationWords: Set<String> = [
            "and", "or", "but", "because", "if", "when", "while", "to", "for", "with",
            "about", "that", "the", "a", "an", "of", "into", "from", "on", "at", "then",
            "as", "by", "so", "than", "run", "in"
        ]

        // Endpointing must respect speech syntax before deterministic routing.
        if continuationWords.contains(lastWord) {
            return configuration.continuationSilence
        }

        if DeterministicRouter.shared.match(lower) != nil {
            return configuration.fastCommandSilence
        }

        return configuration.completedUtteranceSilence
    }
}
