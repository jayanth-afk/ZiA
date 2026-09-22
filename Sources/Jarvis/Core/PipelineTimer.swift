import Foundation

/// Microsecond-precision pipeline stage timer for latency measurement.
///
/// Measures the complete JARVIS pipeline:
///   wake → STT → intent → router → provider → TTS → response
///
/// Usage:
///   let timer = PipelineTimer()
///   timer.mark(.wakeDetected)
///   timer.mark(.sttFirstPartial)
///   // ... more stages ...
///   timer.mark(.responseDelivered)
///   timer.logReport()
///
/// The report shows each stage's duration and the total end-to-end time.
/// This is the authority for finding real bottlenecks.
final class PipelineTimer: @unchecked Sendable {
    let id: String

    // Thread-safe storage using lock
    private let lock = NSLock()
    private var _marks: [(stage: Stage, timestamp: UInt64)] = []
    private let startTime: UInt64

    enum Stage: String, Sendable, CaseIterable {
        // Voice input
        case wakeDetected
        case sttStart
        case sttFirstPartial
        case sttFinal

        // Deterministic routing
        case deterministicRouterStart
        case deterministicRouterHit
        case deterministicRouterMiss

        // LLM intent classification
        case intentStart
        case intentComplete

        // Provider selection
        case routerDecision

        // Provider interaction
        case providerStart
        case providerConnected
        case firstToken
        case lastToken

        // TTS
        case ttsStart
        case ttsFirstAudio
        case ttsComplete

        // Action execution
        case actionStart
        case actionExecuted
        case actionObserved
        case actionVerified

        // Acknowledgement
        case acknowledgementSent

        // Complete
        case responseDelivered
    }

    struct StageResult: Sendable {
        let stage: String
        let durationMs: Double
    }

    struct Report: Sendable {
        let id: String
        let totalMs: Double
        let stages: [StageResult]

        var summary: String {
            var lines = ["Pipeline \(id) — total: \(String(format: "%.1f", totalMs))ms"]
            for s in stages {
                lines.append("  \(s.stage): \(String(format: "%.1f", s.durationMs))ms")
            }
            return lines.joined(separator: "\n")
        }
    }

    init(id: String = UUID().uuidString) {
        self.id = id
        self.startTime = Self.now()
    }

    /// Record a pipeline stage timestamp.
    func mark(_ stage: Stage) {
        let ts = Self.now()
        lock.lock()
        _marks.append((stage, ts))
        lock.unlock()
    }

    /// Elapsed milliseconds since a specific stage was marked.
    func elapsed(since stage: Stage) -> Double? {
        lock.lock()
        let mark = _marks.first { $0.stage == stage }
        lock.unlock()
        guard let mark else { return nil }
        return Self.milliseconds(from: mark.timestamp, to: Self.now())
    }

    /// Elapsed milliseconds between two marked stages.
    func elapsed(from: Stage, to: Stage) -> Double? {
        lock.lock()
        let startMark = _marks.first { $0.stage == from }
        let endMark = _marks.first { $0.stage == to }
        lock.unlock()
        guard let s = startMark, let e = endMark else { return nil }
        return Self.milliseconds(from: s.timestamp, to: e.timestamp)
    }

    /// Total milliseconds since timer creation.
    func totalMs() -> Double {
        Self.milliseconds(from: startTime, to: Self.now())
    }

    /// Generate a full report of all marked stages.
    func report() -> Report {
        lock.lock()
        let marks = _marks
        lock.unlock()

        var stages: [StageResult] = []

        for i in 0..<marks.count {
            let previous = i == 0 ? startTime : marks[i - 1].timestamp
            let duration = Self.milliseconds(from: previous, to: marks[i].timestamp)
            stages.append(StageResult(stage: marks[i].stage.rawValue, durationMs: duration))
        }

        let total = marks.isEmpty
            ? 0
            : Self.milliseconds(from: startTime, to: marks.last!.timestamp)

        return Report(id: id, totalMs: total, stages: stages)
    }

    /// Log the report to the pipeline logger.
    @MainActor
    func logReport() {
        let r = report()
        JarvisLogger.pipeline.info("\(r.summary)")
    }

    // MARK: - High-precision timing (nanosecond clock)

    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000.0
    }
}
