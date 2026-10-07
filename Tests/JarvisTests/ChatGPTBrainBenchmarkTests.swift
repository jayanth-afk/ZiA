import Foundation
import Testing
@testable import Jarvis

/// C5: measured, not guessed. The latency estimator is a rolling median; the
/// benchmark is capped and its prompts are synthetic.
@Suite struct ChatGPTBrainBenchmarkTests {

    @Test func latencyEstimatorFallsBackUntilSampled() {
        let estimator = ChatGPTBrainLatency(fallbackMs: 1200, capacity: 20)
        #expect(estimator.median == 1200, "no samples yet -> documented fallback")
        estimator.record(100)
        estimator.record(300)
        estimator.record(200)
        #expect(estimator.median == 200)
        #expect(estimator.sampleCount == 3)
    }

    @Test func latencyEstimatorKeepsOnlyTheRecentWindow() {
        let estimator = ChatGPTBrainLatency(fallbackMs: 0, capacity: 3)
        for value in [10, 20, 30, 40, 50] { estimator.record(value) }
        #expect(estimator.sampleCount == 3, "capacity bounds the window")
        #expect(estimator.median == 40, "median of the last three samples (30, 40, 50)")
    }

    @Test func latencyEstimatorIgnoresNegativeSamples() {
        let estimator = ChatGPTBrainLatency(fallbackMs: 999, capacity: 5)
        estimator.record(-5)
        #expect(estimator.sampleCount == 0)
        #expect(estimator.median == 999)
    }

    @Test func providerLatencyReadsTheRollingMedian() {
        // The provider's currentLatencyMs is no longer a hard-coded 1200.
        let provider = ChatGPTDesktopProvider()
        #expect(provider.currentLatencyMs == ChatGPTBrainLatency.shared.median)
    }

    @Test func benchmarkIsCappedAndSynthetic() {
        #expect(ChatGPTBrainBenchmark.maxPromptsPerTransport == 6)
        #expect(ChatGPTBrainBenchmark.maxRunSeconds == 300)
        #expect(ChatGPTBrainBenchmark.syntheticPrompts.count <= 6)
        // Synthetic prompts must not mention local files, the user, or secrets.
        for prompt in ChatGPTBrainBenchmark.syntheticPrompts {
            let lowered = prompt.lowercased()
            #expect(!lowered.contains("/users/"))
            #expect(!lowered.contains("password"))
            #expect(!lowered.contains("api key") && !lowered.contains("api_key"))
        }
    }
}
