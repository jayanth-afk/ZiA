import Foundation
import Testing
@testable import Jarvis

/// Test-only tool whose verification always fails. It lets a task step reach the
/// failure path deterministically without any real side effect, so the worker's
/// evidence-recording behavior can be observed directly.
private struct EvidenceProbeTool: JarvisTool {
    let name = "zia_evidence_probe"
    let description = "Test-only probe that always fails verification"
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "token", kind: .string, required: true, description: "Probe token")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        ToolResult(success: true, output: "probe executed", sideEffects: [])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["probe": "observed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        .failed("probe always fails verification", expected: "pass", observed: "fail")
    }
}

/// The TaskStateMachine is the source of truth for a task's steps, while a
/// worker can be handed a snapshot taken earlier. On failure, the recorded
/// evidence (step id, tool, arguments fingerprint, step number) MUST describe
/// the authoritative step, never the stale snapshot — otherwise a replan or a
/// restored continuation could attribute one action's failure to a different
/// action's identity.
@Suite struct TaskWorkerAuthoritativeEvidenceTests {

    @Test @MainActor
    func failureEvidenceBindsToAuthoritativeStepNotStaleSnapshot() async throws {
        ToolRegistry.shared.register(EvidenceProbeTool())

        let machine = TaskStateMachine(storageURL: nil)
        let task = machine.createTask(title: "evidence", goal: "authoritative failure evidence")

        let authoritativeStep = TaskStep(
            stepNumber: 1,
            description: "authoritative step",
            toolName: "zia_evidence_probe",
            arguments: ["token": "AUTHORITATIVE"])
        try machine.setSteps(taskId: task.id, steps: [authoritativeStep])

        // A stale snapshot with the SAME task id but a DIFFERENT step identity
        // and arguments — exactly what a concurrent replan would leave behind.
        let staleStep = TaskStep(
            stepNumber: 1,
            description: "stale step",
            toolName: "zia_evidence_probe",
            arguments: ["token": "STALE"])
        let staleSnapshot = JarvisTask(
            id: task.id, title: task.title, goal: task.goal,
            state: .created, steps: [staleStep])

        let worker = TaskWorker(stateMachine: machine)
        do {
            try await worker.execute(task: staleSnapshot)
            Issue.record("Expected the probe tool to fail verification")
        } catch {
            // Expected: the step fails.
        }

        guard let finalTask = machine.getTask(id: task.id) else {
            Issue.record("Authoritative task disappeared")
            return
        }
        #expect(finalTask.state == .failed)

        guard let record = finalTask.resolutionRecords.last else {
            Issue.record("No failure evidence was recorded")
            return
        }
        let authoritative = finalTask.steps[0]

        // Evidence belongs to the step that actually executed (authoritative).
        #expect(record.taskID == task.id, "evidence must be bound to the same task")
        #expect(record.stepID == authoritative.id, "evidence must be bound to the authoritative step")
        #expect(record.stepID != staleStep.id, "evidence must never be bound to the stale snapshot step")
        #expect(record.stepNumber == authoritative.stepNumber)
        #expect(record.argumentsFingerprint ==
                StepResolutionRecord.fingerprint(arguments: authoritative.arguments),
                "evidence fingerprint must describe the executed step's arguments")
        #expect(record.argumentsFingerprint !=
                StepResolutionRecord.fingerprint(arguments: staleStep.arguments),
                "evidence must not describe the stale snapshot's arguments")
    }

    /// A stale snapshot from a DIFFERENT task cannot leak its step identity into
    /// another task's evidence: the recorded task id is always the executed task.
    @Test @MainActor
    func failureEvidenceCannotCrossTaskBoundary() async throws {
        ToolRegistry.shared.register(EvidenceProbeTool())

        let machine = TaskStateMachine(storageURL: nil)
        let task = machine.createTask(title: "owner", goal: "cross-task protection")
        let step = TaskStep(
            stepNumber: 1,
            description: "owner step",
            toolName: "zia_evidence_probe",
            arguments: ["token": "OWNER"])
        try machine.setSteps(taskId: task.id, steps: [step])

        // A step that belongs to a different logical task, carried in a snapshot
        // bearing the owner's id.
        let foreignStep = TaskStep(
            stepNumber: 1,
            description: "foreign step",
            toolName: "zia_evidence_probe",
            arguments: ["token": "FOREIGN"])
        let foreignSnapshot = JarvisTask(
            id: task.id, title: "foreign", goal: "foreign",
            state: .created, steps: [foreignStep])

        let worker = TaskWorker(stateMachine: machine)
        _ = try? await worker.execute(task: foreignSnapshot)

        guard let finalTask = machine.getTask(id: task.id),
              let record = finalTask.resolutionRecords.last else {
            Issue.record("No failure evidence recorded")
            return
        }
        #expect(record.taskID == task.id)
        #expect(record.stepID == finalTask.steps[0].id)
        #expect(record.stepID != foreignStep.id)
    }
}
