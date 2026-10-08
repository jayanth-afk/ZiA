import Testing
@testable import Jarvis

@Suite("TaskDependencyGraphTests")
final class TaskDependencyGraphTests {

    @Test func selfDependencyIsRejected() async {
        let graph = TaskDependencyGraph()
        let taskA = UUID()
        let diag = await graph.validateSubmission(
            taskID: taskA,
            prerequisiteIDs: [taskA],
            existingDependents: [:],
            allKnownTaskIDs: [taskA]
        )
        #expect(diag?.contains("itself") == true)
    }

    @Test func directCycleIsRejected() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        let diag = await graph.validateSubmission(
            taskID: a,
            prerequisiteIDs: [b],
            existingDependents: [b: [a]],
            allKnownTaskIDs: [a, b]
        )
        #expect(diag?.contains("cycle") == true)
    }

    @Test func indirectCycleIsRejected() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let diag = await graph.validateSubmission(
            taskID: a,
            prerequisiteIDs: [b],
            existingDependents: [b: [c], c: [a]],
            allKnownTaskIDs: [a, b, c]
        )
        #expect(diag?.contains("cycle") == true)
    }

    @Test func missingPrerequisiteIsRejected() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        let diag = await graph.validateSubmission(
            taskID: a,
            prerequisiteIDs: [b],
            existingDependents: [:],
            allKnownTaskIDs: [a]
        )
        #expect(diag?.contains("not present") == true)
    }

    @Test func acyclicSubmissionIsAccepted() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let diag = await graph.validateSubmission(
            taskID: a,
            prerequisiteIDs: [b],
            existingDependents: [b: [c]],
            allKnownTaskIDs: [a, b, c]
        )
        #expect(diag == nil)
    }

    @Test func diamondDependencyIsAccepted() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let diag = await graph.validateSubmission(
            taskID: a,
            prerequisiteIDs: [b, c],
            existingDependents: [b: [d], c: [d]],
            allKnownTaskIDs: [a, b, c, d]
        )
        #expect(diag == nil)
    }

    @Test func prerequisiteCompletionMakesDependentPotentiallyEligible() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        await graph.registerWaiting(taskID: a, prerequisiteIDs: [b])
        let ready = await graph.potentialDependents(of: b)
        #expect(ready.contains(a))
    }

    @Test func failedPrerequisiteDoesNotMakeDependentEligible() async {
        let graph = TaskDependencyGraph()
        let a = UUID()
        let b = UUID()
        await graph.registerWaiting(taskID: a, prerequisiteIDs: [b])
        let outcome = TaskDependencyGraph.DependencyOutcome(taskID: b, outcome: .failed, at: .now)
        let madeReady = await graph.recordOutcome(outcome)
        #expect(madeReady.isEmpty)
    }
}
