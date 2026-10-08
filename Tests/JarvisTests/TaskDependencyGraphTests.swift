import Foundation
import Testing
@testable import Jarvis

@Suite("TaskDependencyGraphTests")
final class TaskDependencyGraphTests {

    // MARK: - submission-time validation

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
        // a -> b, and b is already waiting on a (existingDependents: b depends on a).
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
        // a -> b, b already depends on c, c already depends on a.
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
        // a depends on b and c; b and c both already depend on d.
        let diag = await graph.validateSubmission(
            taskID: a,
            prerequisiteIDs: [b, c],
            existingDependents: [b: [d], c: [d]],
            allKnownTaskIDs: [a, b, c, d]
        )
        #expect(diag == nil)
    }

    // MARK: - event-driven unblock

    @Test func prerequisiteRegistrationTracksDependent() async {
        let graph = TaskDependencyGraph()
        let dependent = UUID()
        let prereq = UUID()
        await graph.registerWaiting(taskID: dependent, prerequisiteIDs: [prereq])
        let ready = await graph.potentialDependents(of: prereq)
        #expect(ready.contains(dependent))
    }

    @Test func multipleDependentsAllBecomePotentiallyReady() async {
        let graph = TaskDependencyGraph()
        let d1 = UUID()
        let d2 = UUID()
        let prereq = UUID()
        await graph.registerWaiting(taskID: d1, prerequisiteIDs: [prereq])
        await graph.registerWaiting(taskID: d2, prerequisiteIDs: [prereq])
        let ready = await graph.potentialDependents(of: prereq)
        #expect(ready.contains(d1))
        #expect(ready.contains(d2))
    }

    @Test func dependentsAreReturnedInDeterministicOrder() async {
        let graph = TaskDependencyGraph()
        let later = UUID(uuidString: "FFFFFF00-0000-0000-0000-000000000000")!
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let prereq = UUID()
        await graph.registerWaiting(taskID: later, prerequisiteIDs: [prereq])
        await graph.registerWaiting(taskID: earlier, prerequisiteIDs: [prereq])
        let ready = await graph.potentialDependents(of: prereq)
        guard ready.count >= 2 else {
            Issue.record("expected at least 2 dependents")
            return
        }
        #expect(ready[0] == earlier)
        #expect(ready[1] == later)
    }

    @Test func alreadySignaledPrerequisiteDoesNotReproduceDependent() async {
        let graph = TaskDependencyGraph()
        let dependent = UUID()
        let prereq = UUID()
        await graph.registerWaiting(taskID: dependent, prerequisiteIDs: [prereq])
        _ = await graph.potentialDependents(of: prereq)
        let again = await graph.potentialDependents(of: prereq)
        #expect(again.isEmpty)
    }

    @Test func unregisteringWaitingTaskRemovesItFromDependents() async {
        let graph = TaskDependencyGraph()
        let dependent = UUID()
        let prereq = UUID()
        await graph.registerWaiting(taskID: dependent, prerequisiteIDs: [prereq])
        await graph.unregisterWaiting(taskID: dependent)
        let ready = await graph.potentialDependents(of: prereq)
        #expect(ready.isEmpty)
    }

    @Test func dependencyEdgesReflectsRegisteredCausality() async {
        let graph = TaskDependencyGraph()
        let dependent = UUID()
        let prereq = UUID()
        await graph.registerWaiting(taskID: dependent, prerequisiteIDs: [prereq])
        let edges = await graph.dependencyEdges()
        #expect(edges[dependent]?.contains(prereq) == true)
    }

    @Test func waitingListIsBoundedAndDoesNotGrowWithoutLimit() async {
        let graph = TaskDependencyGraph()
        let prereq = UUID()
        let limit = TaskDependencyGraph.maximumDependentsPerTask * 4 + 50
        for i in 0..<limit {
            let dependent = UUID()
            await graph.registerWaiting(taskID: dependent, prerequisiteIDs: [prereq])
        }
        let waiting = await graph.waiting
        #expect(waiting.count <= TaskDependencyGraph.maximumDependentsPerTask * 4)
    }

    @Test func dependentsPerPrereqIsBounded() async {
        let graph = TaskDependencyGraph()
        let prereq = UUID()
        let limit = TaskDependencyGraph.maximumDependentsPerTask + 50
        for _ in 0..<limit {
            let dependent = UUID()
            await graph.registerWaiting(taskID: dependent, prerequisiteIDs: [prereq])
        }
        let edges = await graph.dependencyEdges()
        #expect((edges[prereq]?.count ?? 0) <= TaskDependencyGraph.maximumDependentsPerTask)
    }
}
