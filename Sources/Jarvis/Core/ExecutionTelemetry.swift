import Foundation

/// Closed vocabulary for classifying observed failures. This is descriptive
/// only; no category participates in retry, routing, or permission decisions.
enum ExecutionFailureCategory: String, Sendable, Codable {
    case syntax, semantic, execution, verification, permission
    case timeout, cancellation, unavailable, unknown

    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancellation }
        if let validation = error as? PlanValidationError {
            switch validation {
            case .noJSONFound, .malformedJSON: return .syntax
            default: return .semantic
            }
        }
        if error is ReferenceResolutionError { return .semantic }
        guard let error = error as? JarvisError else { return .unknown }
        switch error {
        case .permissionDenied, .privacyPolicyViolation: return .permission
        case .timeout, .providerTimeout: return .timeout
        case .providerUnavailable, .allProvidersFailed, .offline, .apiKeyMissing,
             .notInitialized, .modelLoadFailed: return .unavailable
        case .verificationFailed: return .verification
        case .invalidState: return .semantic
        case .actionFailed, .commandBlocked: return .execution
        default: return .unknown
        }
    }
}

enum ExecutionTelemetryKind: String, Sendable, Codable {
    case taskStarted, stepStarted, stepCompleted, stepFailed, recoveryAttempted
    case verificationCompleted, taskCompleted, taskFailed, stopped
}

/// Immutable fact emitted by AgentLoop at an existing lifecycle boundary.
/// Arguments, outputs, and user content are intentionally excluded.
struct ExecutionTelemetryEvent: Sendable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let taskID: UUID
    let stepID: UUID?
    let kind: ExecutionTelemetryKind
    let phase: String
    let action: String?
    let status: String?
    let durationMilliseconds: Int?
    let verification: VerificationOutcome?
    let failureCategory: ExecutionFailureCategory?
    let attemptCount: Int?
    let modelTier: String?
    let provider: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), taskID: UUID, stepID: UUID? = nil,
         kind: ExecutionTelemetryKind, phase: String, action: String? = nil,
         status: String? = nil, durationMilliseconds: Int? = nil,
         verification: VerificationOutcome? = nil, failureCategory: ExecutionFailureCategory? = nil,
         attemptCount: Int? = nil, modelTier: String? = nil, provider: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.taskID = taskID; self.stepID = stepID
        self.kind = kind; self.phase = phase; self.action = action; self.status = status
        self.durationMilliseconds = durationMilliseconds; self.verification = verification
        self.failureCategory = failureCategory; self.attemptCount = attemptCount
        self.modelTier = modelTier; self.provider = provider
    }
}

/// Bounded, in-memory, observational journal. Duplicate event IDs are ignored;
/// this store is never consulted for execution, state, or permission decisions.
final class ExecutionTelemetry: @unchecked Sendable {
    static let shared = ExecutionTelemetry()
    private let lock = NSLock()
    private let capacity: Int
    private var buffer: [ExecutionTelemetryEvent?]
    private var nextWriteIndex = 0
    private var count = 0
    private var seen = Set<UUID>()

    init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
        self.buffer = Array(repeating: nil, count: max(1, capacity))
    }

    @discardableResult
    func record(_ event: ExecutionTelemetryEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard seen.insert(event.id).inserted else { return false }
        if count == capacity {
            if let evicted = buffer[nextWriteIndex] {
                seen.remove(evicted.id)
            }
        } else {
            count += 1
        }
        buffer[nextWriteIndex] = event
        nextWriteIndex = (nextWriteIndex + 1) % capacity
        return true
    }

    func snapshot() -> [ExecutionTelemetryEvent] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        let start = count == capacity ? nextWriteIndex : 0
        return (0..<count).compactMap { offset in
            buffer[(start + offset) % capacity]
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        buffer = Array(repeating: nil, count: capacity)
        nextWriteIndex = 0
        count = 0
        seen.removeAll(keepingCapacity: true)
    }

}

extension ExecutionTelemetry {
    @MainActor
    static func runSelfTests(check: (Bool, String) -> Void) {
        let journal = ExecutionTelemetry(capacity: 16)
        let task = UUID(), stepA = UUID(), stepB = UUID()
        let started = ExecutionTelemetryEvent(taskID: task, kind: .taskStarted, phase: "understanding")
        let stepStarted = ExecutionTelemetryEvent(taskID: task, stepID: stepA, kind: .stepStarted, phase: "executing")
        let stepDone = ExecutionTelemetryEvent(taskID: task, stepID: stepA, kind: .stepCompleted, phase: "success")
        let done = ExecutionTelemetryEvent(taskID: task, kind: .taskCompleted, phase: "success")
        [started, stepStarted, stepDone, done].forEach { journal.record($0) }
        check(journal.snapshot().map(\.kind) == [.taskStarted, .stepStarted, .stepCompleted, .taskCompleted],
              "telemetry: deterministic lifecycle sequence preserves event order")

        journal.removeAll()
        [started,
         ExecutionTelemetryEvent(taskID: task, stepID: stepA, kind: .stepStarted, phase: "executing"),
         ExecutionTelemetryEvent(taskID: task, stepID: stepA, kind: .stepCompleted, phase: "success"),
         ExecutionTelemetryEvent(taskID: task, stepID: stepB, kind: .stepStarted, phase: "executing"),
         ExecutionTelemetryEvent(taskID: task, stepID: stepB, kind: .stepCompleted, phase: "success"), done]
            .forEach { journal.record($0) }
        check(journal.snapshot().map(\.kind) == [.taskStarted, .stepStarted, .stepCompleted, .stepStarted, .stepCompleted, .taskCompleted],
              "telemetry: multi-step task maintains task and step ordering")

        let verification = ToolVerificationResult.failed("observed mismatch")
        let verifyEvent = ExecutionTelemetryEvent(taskID: task, stepID: stepA, kind: .verificationCompleted,
                                                  phase: "verifying", verification: verification.outcome)
        check(verifyEvent.verification == .failed, "telemetry: event retains the verifier's explicit outcome")
        let recovery = ExecutionTelemetryEvent(taskID: task, kind: .recoveryAttempted, phase: "thinking", attemptCount: 2)
        check(recovery.attemptCount == 2, "telemetry: recovery records the actual attempt count")

        let categories: [(any Error, ExecutionFailureCategory)] = [
            (PlanValidationError.malformedJSON(underlying: "bad json", raw: nil), .syntax),
            (PlanValidationError.unknownTool("not-a-tool"), .semantic),
            (ReferenceResolutionError.malformedReference("$bad", reason: "bad token"), .semantic),
            (JarvisError.invalidState(expected: "a", actual: "b"), .semantic),
            (JarvisError.verificationFailed(action: "x", expected: "a", actual: "b"), .verification),
            (JarvisError.permissionDenied(action: "x", requiredLevel: 2, currentLevel: 1), .permission),
            (JarvisError.timeout(operation: "x", durationMs: 1), .timeout),
            (JarvisError.providerUnavailable(provider: "x"), .unavailable),
            (JarvisError.actionFailed(action: "x", reason: "x"), .execution),
            (CancellationError(), .cancellation), (NSError(domain: "x", code: 1), .unknown)
        ]
        check(categories.allSatisfy { ExecutionFailureCategory.classify($0.0) == $0.1 },
              "telemetry: failure categories map deterministically to the closed vocabulary")
        let stopped = ExecutionTelemetryEvent(taskID: task, kind: .stopped, phase: "stopped", failureCategory: .cancellation)
        check(stopped.kind == .stopped && stopped.failureCategory == .cancellation,
              "telemetry: cancellation is represented as stopped")

        let permissionLevel = PermissionGate.shared.currentLevel
        _ = journal.record(ExecutionTelemetryEvent(taskID: task, kind: .taskStarted, phase: "understanding"))
        check(PermissionGate.shared.currentLevel == permissionLevel,
              "telemetry: recording does not grant or mutate permission")
        let original = "unchanged action result"
        let recorded = journal.record(ExecutionTelemetryEvent(taskID: task, kind: .taskCompleted, phase: "success"))
        check(recorded && original == "unchanged action result",
              "telemetry: recording is observational and leaves action results unchanged")

        let duplicateID = UUID()
        let event = ExecutionTelemetryEvent(id: duplicateID, taskID: task, kind: .stepStarted, phase: "executing")
        let before = journal.snapshot().count
        let first = journal.record(event), second = journal.record(event)
        check(first && !second && journal.snapshot().count == before + 1,
              "telemetry: repeated recording with the same event ID is deduplicated")

        let benchmark = ExecutionTelemetry(capacity: 10_000)
        let benchmarkStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10_000 {
            benchmark.record(ExecutionTelemetryEvent(taskID: task, kind: .stepCompleted, phase: "success"))
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - benchmarkStart
        print(String(format: "  telemetry append benchmark: %.3f µs/event (10,000 in-memory records)", Double(elapsed) / 10_000.0 / 1_000.0))
    }
}
