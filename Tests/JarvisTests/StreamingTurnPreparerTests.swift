import Foundation
import Testing
@testable import Jarvis

@Suite(.serialized) struct StreamingTurnPreparerTests {

    @Test @MainActor func emergencyStopDetectedInstantlyOnPartialTranscript() {
        var stoppedPhrase: String?
        let preparer = StreamingTurnPreparer(
            eventBus: EventBus(),
            onEmergencyStop: { phrase in
                stoppedPhrase = phrase
            }
        )

        let stopTriggered = preparer.processPartialTranscript("stop right there")
        #expect(stopTriggered)
        #expect(stoppedPhrase == "stop")

        let cancelTriggered = preparer.processPartialTranscript("jarvis cancel")
        #expect(cancelTriggered)
        #expect(stoppedPhrase == "cancel")
    }

    @Test @MainActor func ordinarySpeechDoesNotTriggerEmergencyStop() {
        var triggeredPhrase: String?
        let preparer = StreamingTurnPreparer(
            eventBus: EventBus(),
            onEmergencyStop: { phrase in
                triggeredPhrase = phrase
            }
        )

        let triggered = preparer.processPartialTranscript("explain how swift actors work")
        #expect(!triggered)
        #expect(triggeredPhrase == nil)
    }

    @Test @MainActor func speculativeIntentClassifiesConversationalAndDeterministic() {
        let preparer = StreamingTurnPreparer(
            eventBus: EventBus(),
            onEmergencyStop: { _ in }
        )

        _ = preparer.processPartialTranscript("why is my mac battery draining so quickly")
        let conversationalContext = preparer.latestPrepared
        #expect(conversationalContext != nil)
        #expect(conversationalContext?.isDeepCandidate == true)
        #expect(conversationalContext?.isDeterministic == false)

        preparer.reset()
        _ = preparer.processPartialTranscript("open safari")
        let deterministicContext = preparer.latestPrepared
        #expect(deterministicContext != nil)
        #expect(deterministicContext?.isDeterministic == true)
        #expect(deterministicContext?.isDeepCandidate == false)
    }

    @Test @MainActor func takePreparedContextRetrievesFreshContext() {
        let preparer = StreamingTurnPreparer(
            eventBus: EventBus(),
            onEmergencyStop: { _ in }
        )

        _ = preparer.processPartialTranscript("compare rust and swift concurrency")
        let context = preparer.takePreparedContext(for: "compare rust and swift concurrency models")

        #expect(context != nil)
        #expect(context?.isDeepCandidate == true)
        #expect(context?.sensitivity == .publicLevel)
        // Taking it once consumes it
        #expect(preparer.latestPrepared == nil)
    }

    @Test @MainActor func resetClearsStateCleanly() {
        let preparer = StreamingTurnPreparer(
            eventBus: EventBus(),
            onEmergencyStop: { _ in }
        )

        _ = preparer.processPartialTranscript("explain quantum computing today")
        #expect(preparer.latestPrepared != nil)

        preparer.reset()
        #expect(preparer.latestPrepared == nil)
    }
}
