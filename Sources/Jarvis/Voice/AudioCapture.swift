import Foundation
import AVFoundation

/// Captures microphone audio using AVAudioEngine and distributes PCM buffers.
/// Standardized for speech recognition and VAD with adaptive software AGC and pre-roll buffering.
final class AudioCapture: @unchecked Sendable {
    static let shared = AudioCapture()

    // MARK: - State
    @MainActor private(set) var isCapturing = false

    // MARK: - Audio Engine
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var bufferHandlers: [UUID: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private let handlerLock = NSLock()

    // Pre-roll ring buffer storing the last ~350ms of audio (up to 16 buffers at 1024 frames)
    private nonisolated(unsafe) var preRollBuffers: [AVAudioPCMBuffer] = []
    private let preRollLock = NSLock()
    private let maxPreRollBuffers = 16

    // Adaptive Automatic Gain Control state (thread-safe on audio tap thread)
    private nonisolated(unsafe) var currentGain: Float = 1.0

    // Target format: 16kHz, 1 channel (mono)
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

    var engineInputNode: AVAudioInputNode? {
        engine.inputNode
    }

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

    /// Retrieve the recent pre-roll audio buffers to prevent clipping off the start of speech.
    nonisolated func getPreRollBuffers() -> [AVAudioPCMBuffer] {
        preRollLock.lock()
        defer { preRollLock.unlock() }
        return preRollBuffers
    }

    // MARK: - Authorization State
    enum AuthorizationStatus: String, Sendable, CaseIterable {
        case authorized = "Authorized"
        case denied = "Denied"
        case restricted = "Restricted"
        case notDetermined = "Not Determined"
        case unavailable = "Unavailable"
    }

    /// Synchronously query current microphone authorization status without prompting TCC.
    var authorizationStatus: AuthorizationStatus {
        guard Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] != nil else {
            return .unavailable
        }
        if #available(macOS 14.0, *) {
            let appPermission = AVAudioApplication.shared.recordPermission
            if appPermission == .granted {
                return .authorized
            } else if appPermission == .denied {
                return .denied
            }

            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        } else {
            return .authorized
        }
    }

    /// Request microphone permission.
    func requestPermission() async -> Bool {
        guard Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] != nil else {
            JarvisLogger.voice.warning("Skipping requestPermission: NSMicrophoneUsageDescription not found in bundle Info.plist")
            return false
        }
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

    /// Inject a synthetic PCM buffer to all registered handlers (used for automated testing and offline verification).
    nonisolated func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        processAndDistribute(buffer)
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
            VoiceTraceState.shared.markAudioReceived(buffer)
            self?.processAndDistribute(buffer)
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

    // MARK: - Audio Processing & Distribution

    private nonisolated func processAndDistribute(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        // 1. Calculate raw RMS and Peak
        var sumSquares: Float = 0.0
        var peak: Float = 0.0

        for ch in 0..<channelCount {
            if let samples = buffer.floatChannelData?[ch] {
                for i in 0..<frameCount {
                    let s = abs(samples[i])
                    if s > peak { peak = s }
                    sumSquares += s * s
                }
            }
        }

        let totalSamples = Float(frameCount * channelCount)
        let rms = sqrt(sumSquares / totalSamples)

        // 2. Adaptive Automatic Gain Control (AGC) calculation
        // Target speech RMS is ~0.040. If input volume is low (e.g. 39% macOS setting or quiet speech),
        // gently boost quiet-to-normal speech while avoiding noise-pumping during silence.
        if rms > 0.0012 {
            let desiredGain = min(3.5, max(1.0, 0.042 / max(rms, 0.005)))
            currentGain = 0.95 * currentGain + 0.05 * desiredGain
        } else {
            // Decay gain slowly towards 1.0 during silence to prevent background noise boost
            currentGain = 0.995 * currentGain + 0.005 * 1.0
        }

        let appliedGain = currentGain

        // 3. Apply smooth software gain with soft limiter to prevent clipping
        for ch in 0..<channelCount {
            if let samples = buffer.floatChannelData?[ch] {
                for i in 0..<frameCount {
                    var val = samples[i] * appliedGain
                    if val > 0.85 {
                        val = 0.85 + 0.14 * tanh((val - 0.85) / 0.14)
                    } else if val < -0.85 {
                        val = -0.85 + 0.14 * tanh((val + 0.85) / 0.14)
                    }
                    samples[i] = val
                }
            }
        }

        // Update diagnostic metrics with post-gain stats
        AudioDiagnostic.shared.updateMetrics(rms: rms * appliedGain, peak: min(1.0, peak * appliedGain))

        // 4. Record to pre-roll ring buffer
        appendPreRoll(buffer)

        // 5. Distribute to registered tap handlers
        handlerLock.lock()
        let handlers = Array(bufferHandlers.values)
        handlerLock.unlock()

        for handler in handlers {
            handler(buffer)
        }
    }

    private nonisolated func appendPreRoll(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copyBuffer(buffer) else { return }
        preRollLock.lock()
        preRollBuffers.append(copy)
        if preRollBuffers.count > maxPreRollBuffers {
            preRollBuffers.removeFirst(preRollBuffers.count - maxPreRollBuffers)
        }
        preRollLock.unlock()
    }

    private nonisolated func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        for ch in 0..<channels {
            if let src = buffer.floatChannelData?[ch], let dst = copy.floatChannelData?[ch] {
                dst.initialize(from: src, count: frames)
            }
        }
        return copy
    }
}
