@testable import Jarvis
import Testing
import Foundation

@Suite struct PipelineTimerTests {

    @Test
    func marksStagesAndReportsDurations() {
        let timer = PipelineTimer(id: "test-1")

        timer.mark(.wakeDetected)
        // Small busy-wait for measurable duration
        let s1 = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - s1 < 0.001 {}
        timer.mark(.sttStart)
        let s2 = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - s2 < 0.001 {}
        timer.mark(.sttFinal)

        let report = timer.report()

        #expect(report.id == "test-1")
        #expect(report.stages.count == 3)
        #expect(report.totalMs > 0)

        // Each stage should have non-negative duration
        for stage in report.stages {
            #expect(stage.durationMs >= 0)
        }
    }

    @Test
    func elapsedBetweenStages() {
        let timer = PipelineTimer()

        timer.mark(.providerStart)
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 0.001 {} // ~1ms
        timer.mark(.firstToken)

        let elapsed = timer.elapsed(from: .providerStart, to: .firstToken)
        #expect(elapsed != nil)
        if let elapsed {
            #expect(elapsed > 0)
        }
    }

    @Test
    func elapsedSinceStage() {
        let timer = PipelineTimer()
        timer.mark(.wakeDetected)

        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 0.001 {}

        let elapsed = timer.elapsed(since: .wakeDetected)
        #expect(elapsed != nil)
        if let elapsed {
            #expect(elapsed > 0)
        }
    }

    @Test
    func missingStageReturnsNil() {
        let timer = PipelineTimer()
        timer.mark(.wakeDetected)

        let elapsed = timer.elapsed(from: .wakeDetected, to: .responseDelivered)
        #expect(elapsed == nil, "responseDelivered was never marked")
    }

    @Test
    func emptyReportHasZeroStages() {
        let timer = PipelineTimer()
        let report = timer.report()

        #expect(report.stages.isEmpty)
        #expect(report.totalMs == 0)
    }

    @Test
    func reportSummaryIsFormatted() {
        let timer = PipelineTimer(id: "format-test")
        timer.mark(.wakeDetected)
        timer.mark(.responseDelivered)

        let report = timer.report()
        let summary = report.summary

        #expect(summary.contains("format-test"))
        #expect(summary.contains("wakeDetected"))
        #expect(summary.contains("responseDelivered"))
    }

    @Test
    func totalMsIncreasesOverTime() {
        let timer = PipelineTimer()

        let t1 = timer.totalMs()
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 0.001 {}
        let t2 = timer.totalMs()

        #expect(t2 > t1)
    }
}
