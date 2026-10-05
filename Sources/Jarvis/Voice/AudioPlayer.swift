import Foundation
import AppKit

/// Handles system earcons/audio feedback and enforces barge-in interruption.
@MainActor
final class AudioPlayer: NSObject, NSSoundDelegate, @unchecked Sendable {
    static let shared = AudioPlayer()

    // MARK: - Chime Types
    enum Chime {
        case wakeDetected
        case completed
        case error
    }

    private(set) var isPlaying = false
    private var currentSound: NSSound?

    private override init() {
        super.init()
        // Wire up barge-in to stop playback on user speech interruption
        EventBus.shared.subscribe(UserInterruptedEvent.self) { [weak self] _ in
            self?.handleBargeIn()
        }
    }

    // MARK: - Public API

    /// Play an earcon / chime.
    func playChime(_ chime: Chime) {
        let soundName: NSSound.Name
        switch chime {
        case .wakeDetected:
            soundName = NSSound.Name("Tink")
        case .completed:
            soundName = NSSound.Name("Pop")
        case .error:
            soundName = NSSound.Name("Basso")
        }

        stopPlayback()

        if let sound = NSSound(named: soundName) {
            sound.delegate = self
            currentSound = sound
            isPlaying = true
            sound.play()
            JarvisLogger.voice.debug("Playing chime: \(soundName)")
        } else {
            // Fallback system beep
            NSSound.beep()
        }
    }

    // MARK: - NSSoundDelegate

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.currentSound === sound {
                self.currentSound = nil
                self.isPlaying = false
            }
        }
    }

    /// Immediately stop all playback (barge-in).
    func stopPlayback() {
        if let sound = currentSound {
            sound.delegate = nil
            if sound.isPlaying {
                sound.stop()
            }
        }
        currentSound = nil
        isPlaying = false
    }

    /// Handles user barge-in by halting both audio sound effects and TTS speech.
    func handleBargeIn() {
        stopPlayback()
        if TTSEngine.shared.isSpeaking {
            TTSEngine.shared.stop()
        }
        JarvisLogger.voice.info("Barge-in executed: halted playback and speech")
    }
}
