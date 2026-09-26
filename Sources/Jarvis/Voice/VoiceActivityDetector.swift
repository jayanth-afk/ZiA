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
        var hangoverFrames: Int = 15 // ~300-500ms of silence before declaring speech ended
        var minSpeechFrames: Int = 3  // Minimum speech frames to declare speech started
    }

    // MARK: - State
    private(set) var isSpeaking = false
    var configuration = Configuration()

    // Internal tracking
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

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

        Task { @MainActor [weak self] in
            self?.handleEnergy(rms)
        }
    }

    /// Reset internal state.
    func reset() {
        isSpeaking = false
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
    }

    // MARK: - Private

    private func handleEnergy(_ rms: Float) {
        let isFrameSpeech = rms >= configuration.energyThreshold

        if isFrameSpeech {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0

            if !isSpeaking && consecutiveSpeechFrames >= configuration.minSpeechFrames {
                isSpeaking = true
                JarvisLogger.voice.info("[VOICE_TRACE] VAD speech started (RMS: \(rms))")
                onSpeechStart?()
            }
        } else {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0

            if isSpeaking && consecutiveSilenceFrames >= configuration.hangoverFrames {
                isSpeaking = false
                JarvisLogger.voice.info("[VOICE_TRACE] VAD speech ended")
                onSpeechEnd?()
            }
        }
    }
}
