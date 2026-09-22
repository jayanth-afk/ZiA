@testable import Jarvis
import XCTest

final class PipelineTimerTests: XCTestCase {

    func testMarksStagesAndReportsDurations() {
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

        XCTAssertEqual(report.id, "test-1")
        XCTAssertEqual(report.stages.count, 3)
        XCTAssertGreaterThan(report.totalMs, 0)

        // Each stage should have non-negative duration
        for stage in report.stages {
            XCTAssertGreaterThanOrEqual(stage.durationMs, 0)
        }
    }

    func testElapsedBetweenStages() {
        let timer = PipelineTimer()

        timer.mark(.providerStart)
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 0.001 {} // ~1ms
        timer.mark(.firstToken)

        let elapsed = timer.elapsed(from: .providerStart, to: .firstToken)
        XCTAssertNotNil(elapsed)
        XCTAssertGreaterThan(elapsed!, 0)
    }

    func testElapsedSinceStage() {
        let timer = PipelineTimer()
        timer.mark(.wakeDetected)

        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 0.001 {}

        let elapsed = timer.elapsed(since: .wakeDetected)
        XCTAssertNotNil(elapsed)
        XCTAssertGreaterThan(elapsed!, 0)
    }

    func testMissingStageReturnsNil() {
        let timer = PipelineTimer()
        timer.mark(.wakeDetected)

        let elapsed = timer.elapsed(from: .wakeDetected, to: .responseDelivered)
        XCTAssertNil(elapsed, "responseDelivered was never marked")
    }

    func testEmptyReportHasZeroStages() {
        let timer = PipelineTimer()
        let report = timer.report()

        XCTAssertTrue(report.stages.isEmpty)
        XCTAssertEqual(report.totalMs, 0)
    }

    func testReportSummaryIsFormatted() {
        let timer = PipelineTimer(id: "format-test")
        timer.mark(.wakeDetected)
        timer.mark(.responseDelivered)

        let report = timer.report()
        let summary = report.summary

        XCTAssertTrue(summary.contains("format-test"))
        XCTAssertTrue(summary.contains("wakeDetected"))
        XCTAssertTrue(summary.contains("responseDelivered"))
    }

    func testTotalMsIncreasesOverTime() {
        let timer = PipelineTimer()

        let t1 = timer.totalMs()
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < 0.001 {}
        let t2 = timer.totalMs()

        XCTAssertGreaterThan(t2, t1)
    }
}
