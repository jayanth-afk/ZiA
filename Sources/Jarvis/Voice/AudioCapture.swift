import Foundation
import AVFoundation

/// Captures microphone audio using AVAudioEngine and distributes PCM buffers.
/// Standardized for speech recognition and VAD at 16kHz mono PCM.
final class AudioCapture: @unchecked Sendable {
    static let shared = AudioCapture()

    // MARK: - State
    @MainActor private(set) var isCapturing = false

    // MARK: - Audio Engine
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var bufferHandlers: [UUID: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private let handlerLock = NSLock()

    // Target format: 16kHz, 1 channel (mono)
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

    private init() {}

    // MARK: - Public API

    /// Register a handler to receive captured audio buffers.
    /// Returns a registration token for unregistering.
    @discardableResult
    func addBufferHandler(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> UUID {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        let id = UUID()
        bufferHandlers[id] = handler
        return id
    }

    /// Unregister a previously registered buffer handler.
    func removeBufferHandler(_ id: UUID) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        bufferHandlers.removeValue(forKey: id)
    }

    /// Request microphone permission.
    func requestPermission() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Start capturing audio from the default input device.
    @MainActor
    func startCapturing() throws {
        guard !isCapturing else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            JarvisLogger.voice.error("Invalid input audio format sample rate: \(inputFormat.sampleRate)")
            throw JarvisError.microphoneAccessDenied
        }

        // Install tap on input node
        inputNode.removeTap(onBus: 0)
        let bufferSize: AVAudioFrameCount = 1024

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: makeTapBlock())

        do {
            try engine.start()
            isCapturing = true
            JarvisLogger.voice.info("Audio capture started at \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) ch")
        } catch {
            inputNode.removeTap(onBus: 0)
            JarvisLogger.voice.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
            throw JarvisError.actionFailed(action: "startCapturing", reason: error.localizedDescription)
        }
    }

    private nonisolated func makeTapBlock() -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { [weak self] buffer, _ in
            self?.distributeBuffer(buffer)
        }
    }

    /// Stop capturing audio.
    @MainActor
    func stopCapturing() {
        guard isCapturing else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        JarvisLogger.voice.info("Audio capture stopped")
    }

    // MARK: - Private

    private nonisolated func distributeBuffer(_ buffer: AVAudioPCMBuffer) {
        handlerLock.lock()
        let handlers = Array(bufferHandlers.values)
        handlerLock.unlock()

        for handler in handlers {
            handler(buffer)
        }
    }
}
