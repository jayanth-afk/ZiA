import Foundation
import Testing
@testable import Jarvis

@Suite struct TaskEvidenceIdentityTests {
    @Test func boundEvidenceRejectsChangedArguments() throws {
        let taskID = UUID()
        let stepID = UUID()
        let original = TaskStep(
            id: stepID,
            stepNumber: 1,
            description: "read fixture",
            toolName: "read_file",
            arguments: ["path": "/tmp/original.txt"],
            state: .completed,
            output: "same-output",
            verification: .passed
        )
        let record = StepResolutionRecord(
            stepNumber: 1,
            toolName: "read_file",
            rawOutput: "same-output",
            verification: .passed,
            taskID: taskID,
            stepID: stepID,
            argumentsFingerprint: StepResolutionRecord.fingerprint(arguments: original.arguments)
        )
        let task = JarvisTask(
            id: taskID,
            title: "evidence identity",
            goal: "changed arguments must not inherit evidence",
            state: .running,
            steps: [original],
            resolutionRecords: [record]
        )
        #expect(TaskContinuity.independentlyVerified(original, task: task))

        let changed = TaskStep(
            id: original.id,
            stepNumber: original.stepNumber,
            description: original.description,
            toolName: original.toolName,
            arguments: ["path": "/tmp/changed.txt"],
            state: original.state,
            output: original.output,
            verification: original.verification
        )
        let mutatedTask = JarvisTask(
            id: task.id,
            title: task.title,
            goal: task.goal,
            state: task.state,
            steps: [changed],
            resolutionRecords: task.resolutionRecords
        )
        #expect(!TaskContinuity.independentlyVerified(changed, task: mutatedTask))
    }

    @Test func boundEvidenceRejectsEvidenceFromAnotherTask() {
        let taskA = UUID()
        let taskB = UUID()
        let stepID = UUID()
        let args = ["command": "printf proof"]
        let step = TaskStep(
            id: stepID,
            stepNumber: 1,
            description: "run proof",
            toolName: "run_shell",
            arguments: args,
            state: .completed,
            output: "proof",
            verification: .passed
        )
        let transplanted = StepResolutionRecord(
            stepNumber: 1,
            toolName: "run_shell",
            rawOutput: "proof",
            verification: .passed,
            taskID: taskA,
            stepID: stepID,
            argumentsFingerprint: StepResolutionRecord.fingerprint(arguments: args)
        )
        let task = JarvisTask(
            id: taskB,
            title: "different task",
            goal: "cross-task evidence must fail",
            state: .running,
            steps: [step],
            resolutionRecords: [transplanted]
        )
        #expect(!TaskContinuity.independentlyVerified(step, task: task))
    }

    @Test func legacySchemaEvidenceIsInvalidatedOnRestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zia-evidence-identity-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = TaskStateMachine(storageURL: url)
        let task = machine.createTask(title: "legacy evidence", goal: "restart invalidation")
        let step = TaskStep(
            stepNumber: 1,
            description: "fixture",
            toolName: "read_file",
            arguments: ["path": "/tmp/fixture.txt"]
        )
        try machine.setSteps(taskId: task.id, steps: [step])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        #expect(try machine.enablePersistence(for: task.id))
        try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
        try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "proof")
        try machine.transition(taskId: task.id, to: .verifying)
        try machine.transition(taskId: task.id, to: .completed)

        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["schemaVersion"] = 2
        var tasks = object["tasks"] as! [[String: Any]]
        var persistedTask = tasks[0]
        var records = persistedTask["resolutionRecords"] as! [[String: Any]]
        for index in records.indices {
            records[index].removeValue(forKey: "taskID")
            records[index].removeValue(forKey: "stepID")
            records[index].removeValue(forKey: "argumentsFingerprint")
        }
        persistedTask["resolutionRecords"] = records
        tasks[0] = persistedTask
        object["tasks"] = tasks
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacyData.write(to: url, options: .atomic)

        let restored = TaskStateMachine(storageURL: url)
        #expect(restored.isPersistenceAvailable)
        guard let recovered = restored.getTask(id: task.id) else { Issue.record("Restored task missing"); return }
        #expect(recovered.state == .cancelled)
        #expect(recovered.steps[0].verification != .passed)
        #expect(!TaskContinuity.isResolved(recovered.steps[0], task: recovered))
    }
}
