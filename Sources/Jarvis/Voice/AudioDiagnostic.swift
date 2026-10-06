import Foundation
import AVFoundation

/// Developer diagnostic utility for inspecting live microphone capture,
/// signal levels, noise floor, VAD probability, and SpeechRecognizer state.
public final class AudioDiagnostic: @unchecked Sendable {
    public static let shared = AudioDiagnostic()

    public struct Snapshot: Sendable {
        public let inputDeviceName: String
        public let sampleRate: Double
        public let channelCount: Int
        public let inputVolume: Int?
        public let currentRMS: Float
        public let currentPeak: Float
        public let noiseFloor: Float
        public let dynamicThreshold: Float
        public let speechProbability: Float
        public let isSpeaking: Bool
        public let isCapturing: Bool
        public let isRecognizing: Bool
        public let latestPartialTranscript: String
        public let currentTurnId: String?
        public let currentTurnState: String?
    }

    private var latestRMS: Float = 0.0
    private var latestPeak: Float = 0.0
    private var lock = NSLock()

    private init() {}

    public func updateMetrics(rms: Float, peak: Float) {
        lock.lock()
        latestRMS = rms
        latestPeak = peak
        lock.unlock()
    }

    /// Cheap, lock-only level read for real-time UI metering. Deliberately does
    /// NOT touch the VAD/recognizer/pipeline (unlike `snapshot()`), so it is safe
    /// to call on a ~30 Hz rendering cadence without adding audio-path work.
    public nonisolated func latestLevels() -> (rms: Float, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (latestRMS, latestPeak)
    }

    @MainActor
    public func snapshot() -> Snapshot {
        lock.lock()
        let rms = latestRMS
        let peak = latestPeak
        lock.unlock()

        let vad = VoiceActivityDetector.shared
        let capture = AudioCapture.shared
        let recognizer = SpeechRecognizer.shared
        let pipeline = VoicePipeline.shared

        let inputNode = capture.engineInputNode
        let format = inputNode?.outputFormat(forBus: 0)

        return Snapshot(
            inputDeviceName: currentInputDeviceName() ?? "Unknown",
            sampleRate: format?.sampleRate ?? 0,
            channelCount: Int(format?.channelCount ?? 0),
            inputVolume: currentInputVolume(),
            currentRMS: rms,
            currentPeak: peak,
            noiseFloor: vad.noiseFloor,
            dynamicThreshold: vad.currentDynamicThreshold,
            speechProbability: vad.currentSpeechProbability,
            isSpeaking: vad.isSpeaking,
            isCapturing: capture.isCapturing,
            isRecognizing: recognizer.isRecognizing,
            latestPartialTranscript: vad.currentPartialTranscript,
            currentTurnId: pipeline.currentTurn?.id.uuidString.prefix(8).description,
            currentTurnState: pipeline.currentTurn?.state.rawValue
        )
    }

    /// Read macOS input volume setting (0–100) via AppleScript
    public func currentInputVolume() -> Int? {
        let script = "input volume of (get volume settings)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let vol = Int(str) {
            return vol
        }
        return nil
    }

    public func currentInputDeviceName() -> String? {
        // Query AudioObjectGetPropertyData for default input device name
        var defaultDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )

        guard status == noErr, defaultDeviceID != 0 else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let nameStatus = AudioObjectGetPropertyData(
            defaultDeviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &name
        )

        guard nameStatus == noErr, let unmanagedName = name else { return nil }
        return unmanagedName.takeRetainedValue() as String
    }

    /// Runs a real-time terminal diagnostic monitor for the given duration in seconds.
    @MainActor
    public static func runLiveDiagnostic(durationSeconds: Int = 5) async {
        print("══════════════════════════════════════════════════════════")
        print("         ZiA AUDIO & MICROPHONE LIVE DIAGNOSTIC           ")
        print("══════════════════════════════════════════════════════════")

        let diag = AudioDiagnostic.shared
        let inputDevice = diag.currentInputDeviceName() ?? "Unknown"
        let inputVol = diag.currentInputVolume() ?? -1
        print("Input Device:   \(inputDevice)")
        print("macOS Vol:      \(inputVol)%")

        let capture = AudioCapture.shared
        if !capture.isCapturing {
            do {
                try capture.startCapturing()
                print("AudioCapture:   Started successfully")
            } catch {
                print("AudioCapture:   FAILED to start: \(error.localizedDescription)")
                return
            }
        }

        let snap = diag.snapshot()
        print("Sample Rate:    \(Int(snap.sampleRate)) Hz")
        print("Channels:       \(snap.channelCount)")
        print("----------------------------------------------------------")
        print("Monitoring microphone for \(durationSeconds) seconds (speak or stay silent)...")
        print("Time     | RMS      | Peak     | NoiseFl  | DynamicTh | Prob  | VAD State")
        print("---------+----------+----------+----------+-----------+-------+----------")

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < Double(durationSeconds) {
            let s = diag.snapshot()
            let timeStr = String(format: "%5.1fs", Date().timeIntervalSince(startTime))
            let rmsStr = String(format: "%8.5f", s.currentRMS)
            let peakStr = String(format: "%8.5f", s.currentPeak)
            let nfStr = String(format: "%8.5f", s.noiseFloor)
            let thStr = String(format: "%9.5f", s.dynamicThreshold)
            let probStr = String(format: "%5.2f", s.speechProbability)
            let stateStr = s.isSpeaking ? "SPEAKING ★" : "silent"

            print("\(timeStr) | \(rmsStr) | \(peakStr) | \(nfStr) | \(thStr) | \(probStr) | \(stateStr)")
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms interval
        }

        print("----------------------------------------------------------")
        let finalSnap = diag.snapshot()
        print("Summary:")
        print("Final Noise Floor:       \(String(format: "%.5f", finalSnap.noiseFloor))")
        print("Final Dynamic Threshold: \(String(format: "%.5f", finalSnap.dynamicThreshold))")
        print("Recognition Active:      \(finalSnap.isRecognizing)")
        print("Latest Partial:          '\(finalSnap.latestPartialTranscript)'")
        print("══════════════════════════════════════════════════════════\n")
    }
}
