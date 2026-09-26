import Foundation
import AVFoundation

/// VOICE_TRACE diagnostic state (temporary, investigation-only).
///
/// Records two facts without ever storing audio content:
///   1. that the physical microphone actually delivered PCM buffers
///   2. when speech was last detected by the VAD
/// This lets the STT watchdog distinguish "user spoke but the recognizer
/// produced nothing" (dead session) from "user never spoke" (idle session).
final class VoiceTraceState: @unchecked Sendable {
    static let shared = VoiceTraceState()

    private let lock = NSLock()
    private var audioReceived = false
    private var lastSpeechStart: Date?
    private var lastSpeechEnd: Date?

    private init() {}

    /// Called from the real-time audio tap thread — lock-based, no actor hop.
    /// Logs once per process only (no continuous audio logging, for privacy).
    func markAudioReceived(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let first = !audioReceived
        audioReceived = true
        lock.unlock()
        if first {
            JarvisLogger.voice.info("[VOICE_TRACE] mic audio received (\(buffer.frameLength, privacy: .public) frames @ \(buffer.format.sampleRate, privacy: .public)Hz)")
        }
    }

    /// Called by the VAD when speech onset is detected (MainActor).
    func markSpeechStart() {
        lock.lock()
        lastSpeechStart = Date()
        lock.unlock()
    }

    /// Called by the VAD when speech end is declared (MainActor).
    func markSpeechEnd() {
        lock.lock()
        lastSpeechEnd = Date()
        lock.unlock()
    }

    /// True when VAD detected speech at or after the given time.
    func hasSpeech(since date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastSpeechStart.map { $0 >= date } ?? false
    }

    /// True when VAD declared speech END at or after the given time —
    /// i.e. a complete spoken utterance occurred during this session.
    func hasSpeechEnd(since date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastSpeechEnd.map { $0 >= date } ?? false
    }
}
