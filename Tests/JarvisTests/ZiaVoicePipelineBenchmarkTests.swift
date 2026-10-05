import Foundation
import Testing
import AVFoundation
@testable import Jarvis

@Suite struct ZiaVoicePipelineBenchmarkTests {

    @Test @MainActor
    func vadOnsetAndFrameLatency() {
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

        for _ in 0..<100 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            vad.processBuffer(buffer)
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let ms = Double(end - start) / 1_000_000.0
            durations.append(ms)
        }

        durations.sort()
        let p50 = durations[durations.count / 2]
        let p90 = durations[Int(Double(durations.count) * 0.90)]
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        let p99 = durations[Int(Double(durations.count) * 0.99)]

        #expect(p50 < 1.0, "VAD processBuffer p50 under 1ms")
        #expect(p95 < 5.0, "VAD processBuffer p95 under 5ms")
        #expect(p99 < 15.0, "VAD processBuffer p99 under 15ms")
    }

    @Test @MainActor
    func vadEndpointSilenceThresholds() {
        let vad = VoiceActivityDetector.shared
        vad.reset()

        // Test deterministic command recognized: fastCommandSilence = 0.22s
        let cmdSilence = VoiceActivityDetector.silenceNeeded(for: "mute", configuration: vad.configuration)
        #expect(cmdSilence == vad.configuration.fastCommandSilence)
        #expect(cmdSilence <= 0.25)

        // Test completed sentence: completedUtteranceSilence = 0.30s
        let sentSilence = VoiceActivityDetector.silenceNeeded(for: "what is the capital of France?", configuration: vad.configuration)
        #expect(sentSilence == vad.configuration.completedUtteranceSilence)
        #expect(sentSilence <= 0.30)

        // Test natural hesitation/continuation: continuationSilence = 0.75s
        let contSilence = VoiceActivityDetector.silenceNeeded(for: "I was wondering about and", configuration: vad.configuration)
        #expect(contSilence == vad.configuration.continuationSilence)
        #expect(contSilence >= 0.70)

        // Regression: a deterministic command prefix ending in a conjunction
        // must not be cut at the fast-command threshold.
        let unfinishedDeterministic = VoiceActivityDetector.silenceNeeded(
            for: "open Safari and",
            configuration: vad.configuration
        )
        #expect(unfinishedDeterministic == vad.configuration.continuationSilence)
    }

    @Test @MainActor
    func streamingTTSChunkingLatency() async {
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

        for _ in 0..<50 {
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
        let p90 = durations[Int(Double(durations.count) * 0.90)]
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        let p99 = durations[Int(Double(durations.count) * 0.99)]

        #expect(p50 < 10.0, "Streaming TTS chunking overhead p50 under 10ms")
        #expect(p95 < 25.0, "Streaming TTS chunking overhead p95 under 25ms")
    }

    @Test @MainActor
    func providerAvailabilityLatency() async {
        let provider = ProviderManager.shared.chatgptDesktop
        var durations: [Double] = []

        // Warm first check
        _ = await ProviderManager.shared.isProviderAvailable(provider)

        for _ in 0..<50 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            _ = await ProviderManager.shared.isProviderAvailable(provider)
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            durations.append(Double(end - start) / 1_000_000.0)
        }

        durations.sort()
        let p50 = durations[durations.count / 2]
        let p90 = durations[Int(Double(durations.count) * 0.90)]
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        let p99 = durations[Int(Double(durations.count) * 0.99)]

        #expect(p50 < 1.0, "Cached provider availability check p50 under 1ms")
        #expect(p95 < 3.0, "Cached provider availability check p95 under 3ms")
    }

    @Test @MainActor
    func speculativePreparationOverlap() async {
        // Measure speculative preparation trigger vs non-speculative
        let provider = ProviderManager.shared.chatgptDesktop

        // Speculative step (triggered as soon as partial words >= 2)
        let specStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        _ = await ProviderManager.shared.isProviderAvailable(provider)
        let specEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let specMs = Double(specEnd - specStart) / 1_000_000.0

        // At final transcript time, cached availability is instantly hit
        let finalStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let available = await ProviderManager.shared.isProviderAvailable(provider)
        let finalEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let finalMs = Double(finalEnd - finalStart) / 1_000_000.0

        #expect(finalMs < 0.5, "Speculatively pre-warmed provider check at final transcript time under 0.5ms")
    }
}
