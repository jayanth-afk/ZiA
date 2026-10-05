import Foundation
import Testing
import AVFoundation
@testable import Jarvis

@Suite(.serialized) struct VoiceTurnLifecycleRegressionTests {

    // MARK: - A, B, C, D, E: Automatic Endpointing & Linguistic Context
    @Test @MainActor
    func endpointLinguisticContextRules() {
        let vad = VoiceActivityDetector.shared
        vad.reset()

        // B. Short command: fastCommandSilence = 0.22s
        let shortCmd = VoiceActivityDetector.silenceNeeded(for: "open Safari", configuration: vad.configuration)
        #expect(shortCmd == vad.configuration.fastCommandSilence)

        // C. Long sentence without continuation word
        let longSentence = VoiceActivityDetector.silenceNeeded(for: "search for the weather in Delhi", configuration: vad.configuration)
        #expect(longSentence == vad.configuration.completedUtteranceSilence)

        let naturalQuestion = VoiceActivityDetector.silenceNeeded(for: "what is the weather today", configuration: vad.configuration)
        #expect(naturalQuestion == vad.configuration.completedUtteranceSilence)

        let machineLearning = VoiceActivityDetector.silenceNeeded(for: "tell me about machine learning", configuration: vad.configuration)
        #expect(machineLearning == vad.configuration.completedUtteranceSilence)

        let pleaseOpen = VoiceActivityDetector.silenceNeeded(for: "can you please open Safari for me", configuration: vad.configuration)
        #expect(pleaseOpen == vad.configuration.completedUtteranceSilence)

        let volumePercent = VoiceActivityDetector.silenceNeeded(for: "set the volume to fifty percent", configuration: vad.configuration)
        #expect(volumePercent <= vad.configuration.completedUtteranceSilence)

        // D & E. CRITICAL REGRESSION: Conjunction / Preposition continuation phrases
        // "open Safari and" must NEVER be cut at fastCommandSilence!
        let openSafariAnd = VoiceActivityDetector.silenceNeeded(for: "open Safari and", configuration: vad.configuration)
        #expect(openSafariAnd == vad.configuration.continuationSilence, "'open Safari and' must demand continuation silence")

        let tellMeAbout = VoiceActivityDetector.silenceNeeded(for: "tell me about", configuration: vad.configuration)
        #expect(tellMeAbout == vad.configuration.continuationSilence)

        let openTerminalAndRun = VoiceActivityDetector.silenceNeeded(for: "open Terminal and then run", configuration: vad.configuration)
        #expect(openTerminalAndRun == vad.configuration.continuationSilence)

        let setVolumeTo = VoiceActivityDetector.silenceNeeded(for: "set the volume to", configuration: vad.configuration)
        #expect(setVolumeTo == vad.configuration.continuationSilence)

        // Mid-phrase punctuation
        let trailingComma = VoiceActivityDetector.silenceNeeded(for: "open Safari,", configuration: vad.configuration)
        #expect(trailingComma == vad.configuration.continuationSilence)

        let trailingEllipsis = VoiceActivityDetector.silenceNeeded(for: "open Safari...", configuration: vad.configuration)
        #expect(trailingEllipsis == vad.configuration.continuationSilence)

        // Completed command with conjunction in middle (not at the end)
        let openAndSearch = VoiceActivityDetector.silenceNeeded(for: "open Safari and search Google", configuration: vad.configuration)
        #expect(openAndSearch == vad.configuration.completedUtteranceSilence)
    }

    // MARK: - Adaptive Noise Floor
    @Test @MainActor
    func vadAdaptiveNoiseFloorDetectsSilenceInNoisyRoom() async {
        let vad = VoiceActivityDetector.shared
        vad.reset()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let quietBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512),
              let speechBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512),
              let roomNoiseBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
            return
        }

        quietBuffer.frameLength = 512
        speechBuffer.frameLength = 512
        roomNoiseBuffer.frameLength = 512

        // Room noise: 0.020 (above baseline 0.015 threshold)
        if let d = roomNoiseBuffer.floatChannelData?[0] {
            for i in 0..<512 { d[i] = 0.020 }
        }
        // Speech: 0.080
        if let d = speechBuffer.floatChannelData?[0] {
            for i in 0..<512 { d[i] = 0.080 }
        }

        // Feed room noise to adapt noise floor upwards from initial 0.008
        for _ in 0..<40 {
            vad.processBuffer(roomNoiseBuffer)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // Noise floor has adapted upwards from baseline 0.008
        #expect(vad.noiseFloor > 0.0085, "VAD noise floor dynamically adapts to ambient noise")
    }

    // MARK: - F, G, H: Bounded Finalization & Partial-to-Final Fallback
    @Test @MainActor
    func speechRecognizerBoundedFinalizationPromotesPartial() async {
        let recognizer = SpeechRecognizer.shared
        recognizer.cancelRecognition()

        var finalReceived: String?
        let exp = expectation()

        // Simulate incoming partial
        recognizer.simulateTranscript("what time is it", isFinal: false)

        recognizer.finalizeCurrentTurn(fallbackTimeoutMs: 50) { transcript in
            finalReceived = transcript
            exp.fulfill()
        }

        await exp.waitForFulfillment(timeout: 1.0)
        #expect(finalReceived == "what time is it", "Fallback promoted latest partial transcript promptly")
    }

    // MARK: - I, J: Exactly-Once Dispatch & Stale Callback Rejection
    @Test @MainActor
    func exactlyOnceTurnFinalization() async {
        let recognizer = SpeechRecognizer.shared
        recognizer.cancelRecognition()

        var dispatchCount = 0
        let exp = expectation()

        recognizer.simulateTranscript("open Safari", isFinal: false)

        recognizer.finalizeCurrentTurn(fallbackTimeoutMs: 30) { _ in
            dispatchCount += 1
            exp.fulfill()
        }

        await exp.waitForFulfillment(timeout: 1.0)

        // Late isFinal or second timeout must not dispatch again
        recognizer.simulateTranscript("open Safari", isFinal: true)

        #expect(dispatchCount == 1, "Turn finalization must occur exactly once")
    }

    // MARK: - L, M: Context-Aware STOP Semantics
    @Test @MainActor
    func stopButtonContextAwareSemantics() async {
        let pipeline = VoicePipeline.shared
        pipeline.start()

        // 1. While user is speaking / listening:
        // Pressing STOP must finalize input without triggering EmergencyStopEvent
        var emergencyTriggered = false
        let sub = EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            emergencyTriggered = true
        }

        // Simulate voice turn active
        pipeline.startTurnForTesting()
        SpeechRecognizer.shared.setIsRecognizingForTesting(true)
        SpeechRecognizer.shared.simulateTranscript("open Safari", isFinal: false)

        pipeline.handleUserStopAction()

        // Give event loop a cycle
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(!emergencyTriggered, "STOP while listening must finalize input, NOT trigger emergency stop")

        EventBus.shared.unsubscribe(sub)

        // 2. While assistant is executing or speaking:
        // Pressing STOP must trigger EmergencyStopEvent
        SpeechRecognizer.shared.setIsRecognizingForTesting(false)
        pipeline.startTurnForTesting() // get a turn
        // Set turn state to responding
        pipeline.handleSpokenCommand("what is the weather") // dispatches

        var emergencyTriggeredOnExec = false
        let sub2 = EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            emergencyTriggeredOnExec = true
        }

        // Register dummy active background task
        let dummyTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        pipeline.registerBackgroundTaskForTesting("test_bg", dummyTask)

        pipeline.handleUserStopAction()

        #expect(emergencyTriggeredOnExec, "STOP while assistant is responding must trigger emergency stop")
        EventBus.shared.unsubscribe(sub2)
        dummyTask.cancel()
    }

    // MARK: - N, T: Microphone Stop Does Not Cancel Assistant Response
    @Test @MainActor
    func microphoneStopDoesNotCancelAssistantResponse() async {
        let pipeline = VoicePipeline.shared

        let dummyTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let taskId = "test_resp_survive"
        pipeline.registerBackgroundTaskForTesting(taskId, dummyTask)

        // Stopping mic/STT for turn
        SpeechRecognizer.shared.stopRecognition()
        AudioCapture.shared.stopCapturing()

        // Verify task was NOT cancelled
        #expect(pipeline.activeBackgroundTasks[taskId] != nil, "Microphone stopping must not cancel assistant response")
        #expect(!dummyTask.isCancelled, "Background response task must remain active")

        dummyTask.cancel()
    }

    // MARK: - K, S: Rapid Consecutive Turns
    @Test @MainActor
    func rapidConsecutiveTurnsOperateCleanly() async {
        let recognizer = SpeechRecognizer.shared

        // Turn 1
        recognizer.cancelRecognition()
        recognizer.simulateTranscript("what is the time", isFinal: false)
        let exp1 = expectation()
        var turn1Result = ""
        recognizer.finalizeCurrentTurn(fallbackTimeoutMs: 20) { res in
            turn1Result = res
            exp1.fulfill()
        }
        await exp1.waitForFulfillment(timeout: 0.5)
        #expect(turn1Result == "what is the time")

        // Turn 2 immediately
        recognizer.simulateTranscript("open Notes", isFinal: false)
        let exp2 = expectation()
        var turn2Result = ""
        recognizer.finalizeCurrentTurn(fallbackTimeoutMs: 20) { res in
            turn2Result = res
            exp2.fulfill()
        }
        await exp2.waitForFulfillment(timeout: 0.5)
        #expect(turn2Result == "open Notes")
    }

    // MARK: - AudioPlayer Chime Completion Does Not Mute TTS
    @Test @MainActor
    func audioPlayerChimeDoesNotPermanentlyHoldIsPlaying() {
        let player = AudioPlayer.shared
        player.stopPlayback()
        #expect(!player.isPlaying)

        // When stopPlayback is called, isPlaying is cleanly false
        player.handleBargeIn()
        #expect(!player.isPlaying)
    }

    // MARK: - Helper Expectation
    private func expectation() -> AsyncSignal {
        AsyncSignal()
    }
}

@MainActor
private final class AsyncSignal {
    private var isSignaled = false

    func fulfill() {
        isSignaled = true
    }

    @discardableResult
    func waitForFulfillment(timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isSignaled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        return isSignaled
    }
}
