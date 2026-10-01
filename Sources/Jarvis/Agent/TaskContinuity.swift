import Foundation

/// Read-only continuity handoff grounded only in recent authoritative TaskState.
/// It never resumes a task or turns conversation/model context into execution authority.
enum TaskContinuity {
    enum Query: Sendable, Equatable {
        case status
        case remaining
        case continueTask
        case verification
    }

    private enum Selection {
        case noTask
        case stale
        case ambiguous
        case task(JarvisTask)
    }

    static let maxTaskAge: TimeInterval = 15 * 60

    static func query(for goal: String) -> Query? {
        var normalized = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = normalized.last, ".?!".contains(last) { normalized.removeLast() }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please ", "can you please ", "can you ", "could you please ", "could you "] {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        switch normalized {
        case "what are we doing", "what are we working on", "what were you doing", "what was i doing":
            return .status
        case "what's left", "what is left", "what's left to do", "what remains":
            return .remaining
        case "continue", "continue the task", "continue from where you stopped", "continue where you left off",
             "finish it", "finish what you were doing", "finish that":
            return .continueTask
        case "did that work", "did it work", "did it succeed":
            return .verification
        default:
            return nil
        }
    }

    static func summary(
        query: Query,
        tasks: [JarvisTask],
        now: Date = .now,
        maxAge: TimeInterval = maxTaskAge
    ) -> String {
        switch selectTask(in: tasks, now: now, maxAge: maxAge) {
        case .noTask:
            return "I don't have a current task recorded in TaskState. Conversation, memory, or model output isn't enough to infer one. What would you like me to continue?"
        case .stale:
            return "The most recent TaskState is stale. I won't continue or infer unfinished work from it without a fresh task state."
        case .ambiguous:
            return "I found multiple possible TaskState tasks. Which one do you mean? I haven't resumed or changed any task."
        case .task(let task):
            return render(query: query, task: task)
        }
    }

    static func resumableTaskID(
        tasks: [JarvisTask],
        now: Date = .now,
        maxAge: TimeInterval = maxTaskAge
    ) -> UUID? {
        guard case .task(let task) = selectTask(in: tasks, now: now, maxAge: maxAge),
              task.state == .failed || task.state == .cancelled,
              task.retryCount < task.maxRetries,
              firstIncompleteStepIndex(task: task) != nil else { return nil }
        return task.id
    }

    static func firstIncompleteStepIndex(task: JarvisTask) -> Int? {
        task.steps.indices.first { !isResolved(task.steps[$0], task: task) }
    }

    private static func selectTask(in tasks: [JarvisTask], now: Date, maxAge: TimeInterval) -> Selection {
        guard !tasks.isEmpty else { return .noTask }

        let inProgress = tasks.filter { task in
            switch task.state {
            case .created, .planning, .running, .verifying, .recovering, .replanning:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
        if inProgress.count > 1 { return .ambiguous }
        if let task = inProgress.first {
            return isFresh(task, now: now, maxAge: maxAge) ? .task(task) : .stale
        }

        let recent = tasks.filter { isFresh($0, now: now, maxAge: maxAge) }
        guard let latestUpdate = recent.map(\.updatedAt).max() else { return .stale }
        let latestTasks = recent.filter { $0.updatedAt == latestUpdate }
        guard latestTasks.count == 1, let task = latestTasks.first else { return .ambiguous }
        return .task(task)
    }

    private static func isFresh(_ task: JarvisTask, now: Date, maxAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(task.updatedAt)
        return age >= 0 && age <= maxAge
    }

    private static func render(query: Query, task: JarvisTask) -> String {
        let title = String(task.goal.prefix(180))
        let verifiedSteps = task.steps.filter { independentlyVerified($0, task: task) }
        let remainingSteps = task.steps.filter { !isResolved($0, task: task) }
        let count = "\(verifiedSteps.count)/\(task.steps.count) steps passed independent verification"
        let remaining = remainingSteps.prefix(4).map { step in
            "Step \(step.stepNumber): \(String(step.description.prefix(100))) (\(stepStatus(step)))"
        }
        let remainingText = remaining.isEmpty
            ? "No recorded step remains unverified."
            : "Still unverified: \(remaining.joined(separator: "; "))."

        let response: String
        switch task.state {
        case .completed:
            response = task.steps.allSatisfy { isResolved($0, task: task) }
                ? "Task \"\(title)\" is complete. \(count). Nothing remains to continue."
                : "TaskState marks \"\(title)\" complete, but not every step has passed independent verification. \(count). \(remainingText)"
        case .failed:
            let detail = task.steps.first(where: { $0.state == .failed || $0.verification == .failed
                || $0.verification == .inconclusive || $0.verification == .unavailable })
                .map { step in
                    let outcome = step.verification.map { " (verification \($0.rawValue))" } ?? ""
                    return " Failed at step \(step.stepNumber)\(outcome): \(String((step.error ?? step.description).prefix(160)))."
                } ?? ""
            let retryLimit = task.retryCount >= task.maxRetries ? " The task's retry limit is exhausted." : ""
            response = "Task \"\(title)\" failed. \(count).\(detail)\(retryLimit) I won't replay an unverified step automatically. Please clarify how you'd like to proceed."
        case .cancelled:
            let reason = task.error.map { " Recorded reason: \(String($0.prefix(120)))." } ?? ""
            let retryLimit = task.retryCount >= task.maxRetries ? " The task's retry limit is exhausted." : ""
            response = "Task \"\(title)\" was interrupted or stopped.\(reason) \(count). \(remainingText)\(retryLimit) I haven't resumed it. Please clarify how you'd like to proceed."
        default:
            let state = task.state.rawValue.lowercased()
            let currentStep = task.steps.first(where: { $0.state == .running })
                ?? task.steps.first(where: { $0.state == .created })
            let currentText = currentStep.map {
                " Current step: \($0.stepNumber), \"\(String($0.description.prefix(100)))\"."
            } ?? ""
            response = "Current task: \"\(title)\" (\(state)). \(count).\(currentText) \(remainingText)"
        }

        switch query {
        case .verification:
            let toolSteps = task.steps.filter { $0.toolName != nil }
            if task.state == .completed && !toolSteps.isEmpty
                && toolSteps.allSatisfy({ independentlyVerified($0, task: task) }) {
                return "Yes. Task \"\(title)\" completed and all recorded tool steps passed independent verification."
            }
            if let failed = task.steps.first(where: { $0.verification == .failed }) {
                return "No. Step \(failed.stepNumber) failed verification: \(String((failed.error ?? failed.description).prefix(160)))."
            }
            return "I can't confirm that task worked from independent TaskState verification. \(response)"
        case .continueTask:
            return "\(response) This is a read-only handoff; no action was started or retried."
        case .status, .remaining:
            return response
        }
    }

    static func independentlyVerified(_ step: TaskStep, task: JarvisTask) -> Bool {
        guard step.verification == .passed,
              step.state == .completed || step.state == .running || step.state == .cancelled else { return false }
        guard let record = task.resolutionRecords.last(where: {
            $0.stepNumber == step.stepNumber && $0.toolName == step.toolName
        }), record.verification == .passed else { return false }
        if step.output != nil || record.rawOutput != nil {
            return step.output == record.rawOutput
        }
        return true
    }

    static func isResolved(_ step: TaskStep, task: JarvisTask) -> Bool {
        if step.toolName == nil {
            return step.state == .completed && step.verification == .notApplicable
        }
        return independentlyVerified(step, task: task)
    }

    private static func stepStatus(_ step: TaskStep) -> String {
        if step.verification == .failed { return "verification failed" }
        if step.verification == .inconclusive { return "verification inconclusive" }
        if step.verification == .unavailable { return "verification unavailable" }
        return step.state.rawValue.lowercased()
    }
}