import Foundation

private struct RestartProbeTool: JarvisTool {
    let name = "task_state_restart_probe"
    let description = "Deterministic cross-process TaskState probe"
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec = [
        ToolParameterSpec(name: "operation", required: false, description: "Probe operation"),
        ToolParameterSpec(name: "value", required: false, description: "Probe value"),
        ToolParameterSpec(name: "counterPath", required: false, description: "Step execution counter"),
        ToolParameterSpec(name: "evidencePath", required: false, description: "Resolved argument evidence")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let operation = arguments["operation"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing probe operation")
        }
        guard let value = arguments["value"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing probe value")
        }

        switch operation {
        case "produce":
            guard let path = arguments["counterPath"] as? String else {
                throw JarvisError.actionFailed(action: name, reason: "Missing counter path")
            }
            let url = URL(fileURLWithPath: path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("step-one\n".utf8))
        case "consume":
            guard let path = arguments["evidencePath"] as? String else {
                throw JarvisError.actionFailed(action: name, reason: "Missing evidence path")
            }
            try Data(value.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        case "cancel":
            AgentLoop.shared.emergencyCancel()
        default:
            throw JarvisError.actionFailed(action: name, reason: "Unknown probe operation")
        }

        return ToolResult(success: true, output: value)
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["probe": "observed"])
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        expected.success && observed.isAvailable && observed.observations["probe"] == "observed"
            ? .passed(reason: "deterministic probe observation passed")
            : .failed("deterministic probe observation failed")
    }
}

@MainActor
enum TaskStateProcessProbe {
    static func run(arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: "--task-state-probe"),
              arguments.count >= index + 8 else {
            print("[task-state-probe] FAIL invalid arguments")
            return 2
        }

        let phase = arguments[index + 1]
        let snapshotURL = URL(fileURLWithPath: arguments[index + 2])
        let counterURL = URL(fileURLWithPath: arguments[index + 3])
        let evidenceURL = URL(fileURLWithPath: arguments[index + 4])
        guard let taskID = UUID(uuidString: arguments[index + 5]) else {
            print("[task-state-probe] FAIL invalid task id")
            return 2
        }
        let originalGoal = arguments[index + 6]
        let outputValue = arguments[index + 7]

        ToolRegistry.shared.register(RestartProbeTool())
        Config.shared.autonomyLevel = 2

        do {
            switch phase {
            case "A":
                let machine = TaskStateMachine(storageURL: snapshotURL)
                guard machine.isPersistenceAvailable else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.A", reason: "TaskState persistence unavailable")
                }
                let task = machine.createTask(
                    id: taskID,
                    title: "Cross-process restart probe",
                    goal: originalGoal)
                try machine.setSteps(taskId: taskID, steps: [
                    TaskStep(stepNumber: 1, description: "produce deterministic output",
                             toolName: "task_state_restart_probe",
                             arguments: ["operation": "produce", "value": outputValue,
                                         "counterPath": counterURL.path]),
                    TaskStep(stepNumber: 2, description: "consume verified prior output",
                             toolName: "task_state_restart_probe",
                             arguments: ["operation": "consume", "value": "$step.1.output",
                                         "evidencePath": evidenceURL.path])
                ])
                try machine.transition(taskId: taskID, to: .planning)
                try machine.transition(taskId: taskID, to: .running)
                guard try machine.enablePersistence(for: taskID) else {
                    throw JarvisError.actionFailed(
                        action: "TaskStateProbe.A",
                        reason: "Task was not enrolled for persistence")
                }
                try machine.beginStepAttempt(taskId: taskID, stepIndex: 0)
                let result = try await ToolExecutor.shared.execute(
                    toolName: "task_state_restart_probe",
                    arguments: ["operation": "produce", "value": outputValue,
                                "counterPath": counterURL.path])
                guard result.success, result.verification?.outcome == .passed else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.A", reason: "Step 1 did not pass verification")
                }
                try machine.completeVerifiedStep(taskId: taskID, stepIndex: 0, output: result.output)
                try machine.setCurrentStepIndex(taskId: taskID, index: 1)
                    try machine.beginStepAttempt(taskId: taskID, stepIndex: 1)

                guard let persisted = machine.getTask(id: taskID),
                      persisted.goal == originalGoal,
                      TaskContinuity.independentlyVerified(persisted.steps[0], task: persisted),
                        persisted.steps[1].state == .running else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.A", reason: "Process A state assertions failed")
                }
                print("[task-state-probe:A] PASS task identity and original goal created")
                print("[task-state-probe:A] PASS step 1 executed through ToolExecutor and independently verified")
                print("[task-state-probe:A] PASS step 2 persisted unresolved; snapshot checkpointed")
                return 0

            case "B":
                let previousStore = ConversationStore.beginIsolatedTesting()
                defer { ConversationStore.endIsolatedTesting(restoring: previousStore) }
                let machine = TaskStateMachine(storageURL: snapshotURL)
                guard machine.isPersistenceAvailable,
                      let restored = machine.getTask(id: taskID),
                      restored.goal == originalGoal,
                      restored.state == .cancelled,
                      restored.error?.contains("Process interrupted") == true,
                      TaskContinuity.independentlyVerified(restored.steps[0], task: restored),
                      restored.steps[1].state == .cancelled,
                      restored.steps[1].verification == nil else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.B", reason: "Restore did not reconstruct interrupted task evidence")
                }
                print("[task-state-probe:B] PASS fresh process restored original task identity and original goal")
                print("[task-state-probe:B] PASS step 1 remains independently verified after restart")
                print("[task-state-probe:B] PASS interrupted running step 2 restored unresolved, not complete")

                var missingReferenceRejected = false
                do {
                    _ = try ReferenceResolver.resolveStepArguments(
                        rawArguments: restored.steps[1].arguments,
                        currentStepNumber: 2,
                        toolParameterSpecs: RestartProbeTool().parameterSpec,
                        resolutionRecords: [:],
                        environmentContext: restored.environmentContext)
                } catch ReferenceResolutionError.missingStepOutput(stepNumber: 1) {
                    missingReferenceRejected = true
                }
                guard missingReferenceRejected else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.B", reason: "Missing/unverified cross-restart reference was not rejected")
                }
                print("[task-state-probe:B] PASS reference to missing/unverified step output fails closed")

                let response = try await AgentLoop.shared.runUsingTaskStateMachineForTesting(
                    goal: "continue", stateMachine: machine)
                guard let completed = machine.getTask(id: taskID) else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.B", reason: "Continued task disappeared")
                }
                let counterLines = (try String(contentsOf: counterURL, encoding: .utf8))
                    .split(whereSeparator: \.isNewline)
                let resolvedValue = try String(contentsOf: evidenceURL, encoding: .utf8)
                let events = ExecutionTelemetry.shared.snapshot().filter { $0.taskID == taskID }
                let stepOneStarted = events.contains {
                    $0.kind == .stepStarted && $0.stepID == restored.steps[0].id
                }
                guard completed.goal == originalGoal,
                      completed.state == .completed,
                      completed.steps.allSatisfy({ TaskContinuity.isResolved($0, task: completed) }),
                      completed.steps[1].verification == .passed,
                      completed.resolutionRecords.contains(where: {
                          $0.stepNumber == 2 && $0.verification == .passed && $0.rawOutput == outputValue
                      }),
                      counterLines.count == 1,
                      !stepOneStarted,
                      resolvedValue == outputValue,
                      response.contains(outputValue) else {
                    throw JarvisError.actionFailed(action: "TaskStateProbe.B", reason: "Continuation or idempotency assertions failed")
                }
                print("[task-state-probe:B] PASS literal continue resumed the original goal")
                print("[task-state-probe:B] PASS previously verified step 1 executed zero additional times")
                print("[task-state-probe:B] PASS $step.1.output resolved from persisted evidence and reached ToolExecutor concretely")
                print("[task-state-probe:B] PASS step 2 independently verified; task completed only after all steps resolved")
                return 0

            default:
                print("[task-state-probe] FAIL unknown phase \(phase)")
                return 2
            }
        } catch {
            print("[task-state-probe:\(phase)] FAIL \(error.localizedDescription)")
            return 1
        }
    }
}

@MainActor
enum TaskStatePersistenceSelfTests {
    static func run(check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-task-state-tests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let validURL = root.appendingPathComponent("valid-v2.json")
            let validTask = try makeSnapshot(at: validURL, withCompletedStep: false,
                                             environmentContext: TaskEnvironmentContext(currentApp: "Terminal"))
            let validRestored = TaskStateMachine(storageURL: validURL)
            let restoredTask = validRestored.getTask(id: validTask.id)
            check(validRestored.isPersistenceAvailable && restoredTask?.state == .cancelled
                && restoredTask?.environmentContext?.currentApp == "Terminal"
                  && restoredTask.map { TaskContinuity.independentlyVerified($0.steps[0], task: $0) } == true,
                  "TaskState persistence: valid v2 snapshot restores verified evidence")

            let v2Root = try jsonObject(at: validURL)
            var v1Root = v2Root
            v1Root["schemaVersion"] = 1
            var v1Tasks = v1Root["tasks"] as! [[String: Any]]
            v1Tasks[0].removeValue(forKey: "environmentContext")
            v1Root["tasks"] = v1Tasks
            let v1URL = root.appendingPathComponent("valid-v1.json")
            try write(v1Root, to: v1URL)
            let migrated = TaskStateMachine(storageURL: v1URL)
            let migratedTask = migrated.getTask(id: validTask.id)
            check(migrated.isPersistenceAvailable
                  && migratedTask?.environmentContext == nil
                  && migratedTask?.steps.first?.verification != .passed
                  && migratedTask?.steps.first.map { !TaskContinuity.isResolved($0, task: migratedTask!) } == true,
                  "TaskState persistence: v1 migrates to v3 without inventing environment context or trusting legacy verification")

            var unsupportedRoot = v2Root
            unsupportedRoot["schemaVersion"] = 4
            check(rejected(try jsonData(unsupportedRoot), at: root.appendingPathComponent("unsupported.json")),
                  "TaskState persistence: unsupported schema version fails closed")
            check(rejected(Data("{malformed".utf8), at: root.appendingPathComponent("malformed.json")),
                  "TaskState persistence: malformed JSON fails closed")
            check(rejected(Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1),
                           at: root.appendingPathComponent("oversized.json")),
                  "TaskState persistence: oversized snapshot fails closed")

            var excessiveRoot = v2Root
            excessiveRoot["tasks"] = Array(repeating: (v2Root["tasks"] as! [[String: Any]])[0], count: 65)
            check(rejected(try jsonData(excessiveRoot), at: root.appendingPathComponent("too-many-tasks.json")),
                  "TaskState persistence: task count above limit fails closed")

            let completedURL = root.appendingPathComponent("completed.json")
            let completedTask = try makeSnapshot(at: completedURL, withCompletedStep: true)
            let completedRoot = try jsonObject(at: completedURL)
            checkSnapshotMutation(completedRoot, taskID: completedTask.id, at: root,
                                  name: "missing-record", mutate: { $0["resolutionRecords"] = [] }, check: check,
                                  description: "completed step with missing ResolutionRecord fails closed")
            checkSnapshotMutation(completedRoot, taskID: completedTask.id, at: root,
                                  name: "wrong-tool", mutate: { task in
                                      var records = task["resolutionRecords"] as! [[String: Any]]
                                      records[0]["toolName"] = "different_tool"
                                      task["resolutionRecords"] = records
                                  }, check: check,
                                  description: "completed step with wrong tool name fails closed")
            checkSnapshotMutation(completedRoot, taskID: completedTask.id, at: root,
                                  name: "non-passed", mutate: { task in
                                      var records = task["resolutionRecords"] as! [[String: Any]]
                                      records[0]["verification"] = VerificationOutcome.inconclusive.rawValue
                                      task["resolutionRecords"] = records
                                  }, check: check,
                                  description: "completed step with non-passed verification fails closed")
            checkSnapshotMutation(completedRoot, taskID: completedTask.id, at: root,
                                  name: "output-mismatch", mutate: { task in
                                      var steps = task["steps"] as! [[String: Any]]
                                      steps[0]["output"] = "contradictory output"
                                      task["steps"] = steps
                                  }, check: check,
                                  description: "completed step whose rawOutput differs from step.output fails closed")
            checkSnapshotMutation(v2Root, taskID: validTask.id, at: root,
                                  name: "completed-with-unverified-step", mutate: { task in
                                      task["state"] = TaskState.completed.rawValue
                                  }, check: check,
                                  description: "task marked COMPLETED while a required step is unverified fails closed")
            checkSnapshotMutation(completedRoot, taskID: completedTask.id, at: root,
                                  name: "passed-but-created", mutate: { task in
                                      var steps = task["steps"] as! [[String: Any]]
                                      steps[0]["state"] = TaskState.created.rawValue
                                      task["steps"] = steps
                                  }, check: check,
                                  description: "step claiming passed verification in an impossible CREATED state fails closed")
            checkSnapshotMutation(completedRoot, taskID: completedTask.id, at: root,
                                  name: "record-wrong-step", mutate: { task in
                                      var records = task["resolutionRecords"] as! [[String: Any]]
                                      records[0]["stepNumber"] = 2
                                      task["resolutionRecords"] = records
                                  }, check: check,
                                  description: "resolution record pointing at a missing step fails closed")
            checkSnapshotMutation(v2Root, taskID: validTask.id, at: root,
                                  name: "retry-over-budget", mutate: { task in
                                      task["retryCount"] = 5
                                  }, check: check,
                                  description: "task with retryCount above its retry budget fails closed")
            checkSnapshotMutation(v2Root, taskID: validTask.id, at: root,
                                  name: "missing-goal", mutate: { task in
                                      task.removeValue(forKey: "goal")
                                  }, check: check,
                                  description: "snapshot task missing its required goal field fails closed")

            let sensitiveURL = root.appendingPathComponent("sensitive.json")
            let sensitiveMachine = TaskStateMachine(storageURL: sensitiveURL)
            let sensitiveTask = sensitiveMachine.createTask(
                title: "Safe title", goal: "inspect a local item",
                environmentContext: TaskEnvironmentContext(currentSelection: "private_key=not-for-disk"))
            try sensitiveMachine.setSteps(taskId: sensitiveTask.id, steps: [
                TaskStep(stepNumber: 1, description: "inspect", toolName: "read_file", arguments: ["path": "item.txt"])
            ])
            try sensitiveMachine.transition(taskId: sensitiveTask.id, to: .planning)
            try sensitiveMachine.transition(taskId: sensitiveTask.id, to: .running)
            let sensitivePersisted = try sensitiveMachine.enablePersistence(for: sensitiveTask.id)
            let sensitiveSnapshot = try? String(contentsOf: sensitiveURL, encoding: .utf8)
            check(!sensitivePersisted && sensitiveSnapshot?.contains("private_key") != true
                && sensitiveSnapshot?.contains("not-for-disk") != true,
                "TaskState persistence: sensitive environment context is never written (enrolled=\(sensitivePersisted), leaked=\(sensitiveSnapshot?.contains("private_key") == true))")

            let stale = TaskEnvironmentContext(
                currentApp: "Terminal", snapshotTimestamp: Date().addingTimeInterval(-600))
            var staleRejected = false
            do {
                _ = try ReferenceResolver.resolveStepArguments(
                    rawArguments: ["value": "$ambient.current_app"], currentStepNumber: 2,
                    toolParameterSpecs: [], resolutionRecords: [:], environmentContext: stale)
            } catch ReferenceResolutionError.staleAmbientSlot(.currentApp, _) {
                staleRejected = true
            }
            check(staleRejected, "TaskState persistence: stale restored ambient context cannot become authoritative")

            let failureURL = root.appendingPathComponent("checkpoint-failure.json")
            let failureMachine = try makeRunningVerifiedTask(at: failureURL)
            try FileManager.default.removeItem(at: failureURL)
            try FileManager.default.createDirectory(at: failureURL, withIntermediateDirectories: true)
            var completionRejected = false
            do {
                try failureMachine.transition(taskId: failureMachine.allTasks[0].id, to: .verifying)
                try failureMachine.transition(taskId: failureMachine.allTasks[0].id, to: .completed)
            } catch {
                completionRejected = failureMachine.allTasks.first?.state == .verifying
            }
            check(completionRejected,
                  "TaskState persistence: failed durable checkpoint cannot create in-memory COMPLETED state")

            let replacementURL = root.appendingPathComponent("replace-corrupt.json")
            _ = try makeSnapshot(at: replacementURL, withCompletedStep: true)
            let replacementMachine = TaskStateMachine(storageURL: replacementURL)
            try Data("not-json".utf8).write(to: replacementURL, options: .atomic)
            var corruptReplacementRejected = false
            do {
                try replacementMachine.restoreFromDiskForTesting()
            } catch {
                corruptReplacementRejected = !replacementMachine.isPersistenceAvailable
                    && replacementMachine.allTasks.isEmpty
            }
            check(corruptReplacementRejected,
                  "TaskState persistence: valid state followed by corrupt replacement leaves no partial tasks")

            var emergencyStopDuringResume = false
            let emergencySemaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let previousLevel = Config.shared.autonomyLevel
                Config.shared.autonomyLevel = 2
                AgentLoop.shared.resetEmergencyCancellation()
                ToolRegistry.shared.register(RestartProbeTool())
                do {
                    let machine = TaskStateMachine(storageURL: nil)
                    let goal = "execute the saved emergency-stop recovery steps"
                    let task = machine.createTask(title: "Emergency stop continuation", goal: goal)
                    try machine.setSteps(taskId: task.id, steps: [
                        TaskStep(stepNumber: 1, description: "already verified", toolName: "task_state_restart_probe",
                                 arguments: ["operation": "produce", "value": "seed", "counterPath": root.appendingPathComponent("unused-count").path]),
                        TaskStep(stepNumber: 2, description: "trigger emergency stop", toolName: "task_state_restart_probe",
                                 arguments: ["operation": "cancel", "value": "stop"]),
                        TaskStep(stepNumber: 3, description: "must not execute", toolName: "task_state_restart_probe",
                                 arguments: ["operation": "consume", "value": "late", "evidencePath": root.appendingPathComponent("late-output").path])
                    ])
                    try machine.transition(taskId: task.id, to: .planning)
                    try machine.transition(taskId: task.id, to: .running)
                    try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
                    try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "seed")
                    try machine.transition(taskId: task.id, to: .cancelled, error: "Process interrupted")

                    do {
                        _ = try await AgentLoop.shared.runUsingTaskStateMachineForTesting(
                            goal: "continue", stateMachine: machine)
                    } catch is CancellationError {
                    }
                    let finalTask = machine.getTask(id: task.id)
                    let events = ExecutionTelemetry.shared.snapshot().filter { $0.taskID == task.id }
                    emergencyStopDuringResume = finalTask?.state == .cancelled
                        && finalTask?.steps.map(\.verification) == [.passed, .passed, nil]
                        && finalTask?.steps.indices.contains(2) == true
                        && !events.contains { $0.kind == .stepStarted && $0.stepID == finalTask?.steps[2].id }
                } catch {
                    emergencyStopDuringResume = false
                }
                AgentLoop.shared.resetEmergencyCancellation()
                Config.shared.autonomyLevel = previousLevel
                emergencySemaphore.signal()
            }
            while emergencySemaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            check(emergencyStopDuringResume,
                  "TaskState continuation: emergency stop during resumed execution cancels the task before the next step starts")

            var workerResumeIdempotent = false
            let workerSemaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let previousLevel = Config.shared.autonomyLevel
                Config.shared.autonomyLevel = 2
                ToolRegistry.shared.register(RestartProbeTool())
                do {
                    let machine = TaskStateMachine.shared
                    let counterURL = root.appendingPathComponent("worker-step-one-count.txt")
                    let evidenceURL = root.appendingPathComponent("worker-resolved-value.txt")
                    try Data().write(to: counterURL)
                    let task = machine.createTask(title: "TaskWorker restart continuation",
                                                  goal: "resume authoritative worker state")
                    try machine.setSteps(taskId: task.id, steps: [
                        TaskStep(stepNumber: 1, description: "produce worker value",
                                 toolName: "task_state_restart_probe",
                                 arguments: ["operation": "produce", "value": "worker-seed",
                                             "counterPath": counterURL.path]),
                        TaskStep(stepNumber: 2, description: "consume worker reference",
                                 toolName: "task_state_restart_probe",
                                 arguments: ["operation": "consume", "value": "$step.1.output",
                                             "evidencePath": evidenceURL.path])
                    ])
                    try machine.transition(taskId: task.id, to: .planning)
                    try machine.transition(taskId: task.id, to: .running)
                    try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
                    let firstResult = try await ToolExecutor.shared.execute(
                        toolName: "task_state_restart_probe",
                        arguments: ["operation": "produce", "value": "worker-seed",
                                    "counterPath": counterURL.path])
                    try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: firstResult.output)
                    try machine.transition(taskId: task.id, to: .cancelled, error: "Process interrupted")
                    guard let staleSnapshot = machine.getTask(id: task.id) else {
                        throw JarvisError.actionFailed(action: "TaskStateSelfTest", reason: "Worker task disappeared")
                    }

                    try await TaskWorker().execute(task: staleSnapshot)
                    let afterFirstResume = machine.getTask(id: task.id)
                    var duplicateRejected = false
                    do {
                        try await TaskWorker().execute(task: staleSnapshot)
                    } catch {
                        duplicateRejected = true
                    }
                    let count = try String(contentsOf: counterURL, encoding: .utf8)
                        .split(whereSeparator: \.isNewline).count
                    let resolved = try String(contentsOf: evidenceURL, encoding: .utf8)
                    let allResolved = afterFirstResume.map { current in
                        !current.steps.isEmpty && current.steps.allSatisfy {
                            TaskContinuity.isResolved($0, task: current)
                        }
                    } ?? false
                    workerResumeIdempotent = duplicateRejected
                        && afterFirstResume?.state == .completed
                        && allResolved
                        && count == 1
                        && resolved == "worker-seed"
                        && machine.getTask(id: task.id)?.state == .completed
                } catch {
                    workerResumeIdempotent = false
                }
                Config.shared.autonomyLevel = previousLevel
                workerSemaphore.signal()
            }
            while workerSemaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            check(workerResumeIdempotent,
                  "TaskWorker restart resume: stale task input reloads authority, skips verified work, resolves references, and rejects duplicate execution")

        } catch {
            check(false, "TaskState persistence test fixtures could not be created: \(error.localizedDescription)")
        }
    }

    static func runProcessBoundaryProbe(executableURL: URL) -> (passed: Bool, report: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-restart-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let snapshotURL = root.appendingPathComponent("task-state.json")
            let counterURL = root.appendingPathComponent("step-one-count.txt")
            let evidenceURL = root.appendingPathComponent("resolved-step-two.txt")
            try Data().write(to: counterURL)
            let taskID = UUID()
            let goal = "process the original restart-probe goal"
            let outputValue = "restart-output-\(UUID().uuidString.lowercased())"
            let commonArguments = [snapshotURL.path, counterURL.path, evidenceURL.path,
                                   taskID.uuidString, goal, outputValue]
            let phaseA = runChild(executableURL: executableURL,
                                  arguments: ["--task-state-probe", "A"] + commonArguments)
            guard phaseA.status == 0 else {
                return (false, "PROCESS A failed (exit \(phaseA.status)):\n\(phaseA.output)")
            }
            let phaseB = runChild(executableURL: executableURL,
                                  arguments: ["--task-state-probe", "B"] + commonArguments)
            guard phaseB.status == 0 else {
                return (false, "PROCESS B failed (exit \(phaseB.status)):\n\(phaseA.output)\n\(phaseB.output)")
            }
            let report = phaseA.output + phaseB.output
            let assertions = [
                "task identity and original goal created",
                "step 1 executed through ToolExecutor and independently verified",
                "fresh process restored original task identity and original goal",
                "step 1 remains independently verified after restart",
                "interrupted running step 2 restored unresolved, not complete",
                "reference to missing/unverified step output fails closed",
                "literal continue resumed the original goal",
                "previously verified step 1 executed zero additional times",
                "$step.1.output resolved from persisted evidence and reached ToolExecutor concretely",
                "step 2 independently verified; task completed only after all steps resolved"
            ]
            let missing = assertions.filter { !report.contains($0) }
            let details = missing.isEmpty ? report : report + "[task-state-probe] Missing assertions: \(missing)\n"
            return (missing.isEmpty, details)
        } catch {
            return (false, "Could not run process-boundary probe: \(error.localizedDescription)")
        }
    }

    private static func makeSnapshot(
        at url: URL,
        withCompletedStep: Bool,
        environmentContext: TaskEnvironmentContext? = nil
    ) throws -> JarvisTask {
        let machine = TaskStateMachine(storageURL: url)
        let task = machine.createTask(title: "Persistence fixture", goal: "verify persistence evidence",
                                      environmentContext: environmentContext)
        let steps = withCompletedStep
            ? [TaskStep(stepNumber: 1, description: "fixture step", toolName: "read_file", arguments: ["path": "fixture.txt"])]
            : [TaskStep(stepNumber: 1, description: "fixture step", toolName: "read_file", arguments: ["path": "fixture.txt"]),
               TaskStep(stepNumber: 2, description: "pending step", toolName: "read_file", arguments: ["path": "pending.txt"])]
        try machine.setSteps(taskId: task.id, steps: steps)
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        guard try machine.enablePersistence(for: task.id) else {
            throw JarvisError.actionFailed(action: "TaskStateSelfTest", reason: "Fixture did not enroll for persistence")
        }
        try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
        try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "fixture-output")
        if withCompletedStep {
            try machine.transition(taskId: task.id, to: .verifying)
            try machine.transition(taskId: task.id, to: .completed)
        }
        return task
    }

    private static func makeRunningVerifiedTask(at url: URL) throws -> TaskStateMachine {
        let machine = TaskStateMachine(storageURL: url)
        let task = machine.createTask(title: "Checkpoint failure", goal: "verify failed checkpoint")
        try machine.setSteps(taskId: task.id, steps: [
            TaskStep(stepNumber: 1, description: "fixture step", toolName: "read_file", arguments: ["path": "fixture.txt"])
        ])
        try machine.transition(taskId: task.id, to: .planning)
        try machine.transition(taskId: task.id, to: .running)
        guard try machine.enablePersistence(for: task.id) else {
            throw JarvisError.actionFailed(action: "TaskStateSelfTest", reason: "Checkpoint fixture did not persist")
        }
        try machine.beginStepAttempt(taskId: task.id, stepIndex: 0)
        try machine.completeVerifiedStep(taskId: task.id, stepIndex: 0, output: "fixture-output")
        return machine
    }

    private static func checkSnapshotMutation(
        _ source: [String: Any],
        taskID: UUID,
        at root: URL,
        name: String,
        mutate: (inout [String: Any]) -> Void,
        check: (Bool, String) -> Void,
        description: String
    ) {
        do {
            var changed = source
            var tasks = changed["tasks"] as! [[String: Any]]
            guard let taskIndex = tasks.firstIndex(where: { ($0["id"] as? String) == taskID.uuidString }) else {
                check(false, "TaskState persistence: mutation fixture task was missing")
                return
            }
            mutate(&tasks[taskIndex])
            changed["tasks"] = tasks
            check(rejected(try jsonData(changed), at: root.appendingPathComponent("\(name).json")),
                  "TaskState persistence: \(description)")
        } catch {
            check(false, "TaskState persistence: \(name) mutation failed: \(error.localizedDescription)")
        }
    }

    private static func rejected(_ data: Data, at url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            let machine = TaskStateMachine(storageURL: url)
            return !machine.isPersistenceAvailable && machine.allTasks.isEmpty
        } catch {
            return false
        }
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        try jsonData(object).write(to: url, options: .atomic)
    }

    private static func runChild(executableURL: URL, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}