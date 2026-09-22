import Foundation
import AppKit

/// Handles system earcons/audio feedback and enforces barge-in interruption.
@MainActor
final class AudioPlayer {
    static let shared = AudioPlayer()

    // MARK: - Chime Types
    enum Chime {
        case wakeDetected
        case completed
        case error
    }

    private(set) var isPlaying = false
    private var currentSound: NSSound?

    private init() {
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
            currentSound = sound
            isPlaying = true
            sound.play()
            JarvisLogger.voice.debug("Playing chime: \(soundName)")
        } else {
            // Fallback system beep
            NSSound.beep()
        }
    }

    /// Immediately stop all playback (barge-in).
    func stopPlayback() {
        if let sound = currentSound, sound.isPlaying {
            sound.stop()
        }
        currentSound = nil
        isPlaying = false
    }

    /// Handles user barge-in by halting both audio sound effects and TTS speech.
    func handleBargeIn() {
        stopPlayback()
        TTSEngine.shared.stop()
        JarvisLogger.voice.info("Barge-in executed: halted playback and speech")
    }
}
