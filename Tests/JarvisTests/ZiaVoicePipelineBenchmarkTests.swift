import Foundation
import Testing
import AVFoundation
@testable import Jarvis

@Suite struct ZiaVoicePipelineBenchmarkTests {

    @Test @MainActor
    func vadLatency() {
        let vad = VoiceActivityDetector.shared
        var durations: [Double] = []

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
            return
        }
        buffer.frameLength = 512
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<512 {
                channelData[i] = 0.05
            }
        }

        for _ in 0..<50 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            vad.processBuffer(buffer)
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let ms = Double(end - start) / 1_000_000.0
            durations.append(ms)
        }

        durations.sort()
        let p50 = durations[durations.count / 2]
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        #expect(p50 < 5.0)
        #expect(p95 < 15.0)
    }

    @Test @MainActor
    func streamingTTSLatency() async {
        let tts = TTSEngine.shared
        tts.warmup()

        let sampleTokens = [
            "Certainly! ",
            "I can help ",
            "you with that. ",
            "Here is the ",
            "second sentence ",
            "streamed immediately.\n"
        ]

        var durations: [Double] = []

        for _ in 0..<20 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            tts.beginStreaming()
            for token in sampleTokens {
                tts.appendStreamingChunk(token)
            }
            tts.finishStreaming()
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            durations.append(Double(end - start) / 1_000_000.0)
            tts.stop()
        }

        durations.sort()
        let p50 = durations[durations.count / 2]
        #expect(p50 < 20.0)
    }

    @Test @MainActor
    func providerAvailabilityLatency() async {
        let provider = ProviderManager.shared.chatgptDesktop
        var durations: [Double] = []

        _ = await ProviderManager.shared.isProviderAvailable(provider)

        for _ in 0..<30 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            _ = await ProviderManager.shared.isProviderAvailable(provider)
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            durations.append(Double(end - start) / 1_000_000.0)
        }

        durations.sort()
        let p50 = durations[durations.count / 2]
        #expect(p50 < 5.0)
    }
}
