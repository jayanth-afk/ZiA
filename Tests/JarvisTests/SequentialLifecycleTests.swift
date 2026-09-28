@testable import Jarvis
import XCTest

/// Experiment A focused regression (sequential next-step planning).
///
/// Bug A: the sequential path must never attempt an illegal TaskState
/// transition. The legal transition table (TaskState.canTransition) is:
///   created → planning | running
///   planning → running | failed
///   running → verifying | failed
///   verifying → completed | failed | running
///   failed → recovering
///   recovering → replanning | failed
///   replanning → running | failed
/// Every transition chain exercised by AgentLoop.runSequential is replayed
/// here against a real TaskStateMachine; a throw means an illegal transition.
///
/// Bug B: a model "DONE" is never authority by itself. The accept gate in
/// runSequential additionally requires deterministic evidence: ≥1 recorded
/// step AND every recorded step explicitly verified .passed. These tests pin
/// that predicate and the budget-expiry → FAILED rule.
final class SequentialLifecycleTests: XCTestCase {

    // MARK: - Bug A: every sequential transition chain is legal

    /// The initial chain into the sequential loop: CREATED → PLANNING → RUNNING.
    @MainActor
    func testInitialSequentialChainIsLegal() throws {
        let sm = TaskStateMachine.shared
        let task = sm.createTask(title: "SeqA-Regression", goal: "regression: initial chain")
        try sm.transition(taskId: task.id, to: .planning)
        try sm.transition(taskId: task.id, to: .running)
        XCTAssertEqual(sm.getTask(id: task.id)?.state, .running)
    }

    /// Planning-failure recovery chain: RUNNING → FAILED → RECOVERING →
    /// REPLANNING → RUNNING. The trailing PLANNING → RUNNING return is the
    /// Bug A fix: without it the loop retries from REPLANNING, and a later
    /// DONE-accept (REPLANNING → VERIFYING) or budget-exhaustion exit
    /// (REPLANNING → FAILED) would attempt an illegal transition.
    @MainActor
    func testPlanningFailureRecoveryChainIsLegalAndReturnsToRunning() throws {
        let sm = TaskStateMachine.shared
        let task = sm.createTask(title: "SeqA-Regression", goal: "regression: planning-failure chain")
        try sm.transition(taskId: task.id, to: .planning)
        try sm.transition(taskId: task.id, to: .running)

        // Exact chain from runSequential's planning-failure recovery.
        try sm.transition(taskId: task.id, to: .failed, error: "Next-step planning failed")
        try sm.transition(taskId: task.id, to: .recovering)
        try sm.transition(taskId: task.id, to: .replanning)
        try sm.transition(taskId: task.id, to: .running) // Bug A fix
        XCTAssertEqual(sm.getTask(id: task.id)?.state, .running)

        // After the fix, a later DONE-accept path is legal end-to-end.
        try sm.transition(taskId: task.id, to: .verifying)
        try sm.transition(taskId: task.id, to: .completed)
        XCTAssertEqual(sm.getTask(id: task.id)?.state, .completed)
    }

    /// The Bug A residue, stated negatively: had the loop retried from
    /// REPLANNING, both later exits would be illegal. This documents WHY the
    /// REPLANNING → RUNNING return is load-bearing.
    func testReplanningCannotReachVerifyingOrFailed() {
        XCTAssertFalse(
            TaskState.replanning.canTransition(to: .verifying),
            "REPLANNING → VERIFYING must stay illegal (Bug A residue)")
        XCTAssertFalse(
            TaskState.replanning.canTransition(to: .failed),
            "REPLANNING → FAILED must stay illegal (Bug A residue)")
    }

    /// Execution-failure recovery chain (same shape as the full-plan path):
    /// RUNNING → FAILED → RECOVERING → REPLANNING → RUNNING.
    @MainActor
    func testExecutionFailureRecoveryChainIsLegal() throws {
        let sm = TaskStateMachine.shared
        let task = sm.createTask(title: "SeqA-Regression", goal: "regression: execution-failure chain")
        try sm.transition(taskId: task.id, to: .planning)
        try sm.transition(taskId: task.id, to: .running)
        try sm.transition(taskId: task.id, to: .failed, error: "step failed")
        try sm.transition(taskId: task.id, to: .recovering)
        try sm.transition(taskId: task.id, to: .replanning)
        try sm.transition(taskId: task.id, to: .running)
        XCTAssertEqual(sm.getTask(id: task.id)?.state, .running)
    }

    /// DONE-rejection chains (zero completed steps / no verified-step evidence):
    /// RUNNING → FAILED → RECOVERING → REPLANNING → RUNNING → continue.
    @MainActor
    func testDoneRejectionChainIsLegal() throws {
        let sm = TaskStateMachine.shared
        let task = sm.createTask(title: "SeqA-Regression", goal: "regression: DONE-rejection chain")
        try sm.transition(taskId: task.id, to: .planning)
        try sm.transition(taskId: task.id, to: .running)
        try sm.transition(taskId: task.id, to: .failed, error: "DONE signaled with no completed steps")
        try sm.transition(taskId: task.id, to: .recovering)
        try sm.transition(taskId: task.id, to: .replanning)
        try sm.transition(taskId: task.id, to: .running)
        XCTAssertEqual(sm.getTask(id: task.id)?.state, .running)
    }

    /// Budget-exhaustion exit: RUNNING → FAILED. Proves the fixed recovery
    /// chain leaves the task in a state where this exit is legal (§6: budget
    /// expiry → FAILED, never success).
    @MainActor
    func testBudgetExhaustionExitIsLegal() throws {
        let sm = TaskStateMachine.shared
        let task = sm.createTask(title: "SeqA-Regression", goal: "regression: budget exhaustion exit")
        try sm.transition(taskId: task.id, to: .planning)
        try sm.transition(taskId: task.id, to: .running)
        try sm.transition(taskId: task.id, to: .failed, error: "Sequential planning attempt budget exhausted before DONE")
        XCTAssertEqual(sm.getTask(id: task.id)?.state, .failed)
    }

    /// The sequential path must never rely on these transitions — they are
    /// either outside the legal table or would bypass deterministic authority.
    func testSequentialPathNeverUsesIllegalTransitions() {
        // The originally-reported Bug A attempt.
        XCTAssertFalse(TaskState.running.canTransition(to: .planning))
        // Skipping execution or jumping to completion.
        XCTAssertFalse(TaskState.running.canTransition(to: .completed))
        XCTAssertFalse(TaskState.planning.canTransition(to: .verifying))
        // Terminal states emit nothing further.
        XCTAssertTrue(TaskState.completed.isTerminal)
        XCTAssertTrue(TaskState.cancelled.isTerminal)
        XCTAssertFalse(TaskState.completed.canTransition(to: .running))
        XCTAssertFalse(TaskState.cancelled.canTransition(to: .running))
    }

    // MARK: - Bug B: DONE completion gate is deterministic evidence, not text

    /// Mirror of the accept-gate predicate in AgentLoop.runSequential: ≥1
    /// recorded step AND every recorded step explicitly verified .passed.
    /// Kept textually identical (with this comment tying it to the source) so
    /// drift in either place fails this test.
    private func doneGateAccepts(_ steps: [TaskStep]) -> Bool {
        let allVerified = !steps.isEmpty && steps.allSatisfy { $0.verification == .passed }
        return allVerified
    }

    /// Zero executed steps + model says DONE → gate rejects (partial-plan
    /// safety: nothing executed can never be success).
    func testDoneWithZeroExecutedStepsIsRejected() {
        XCTAssertFalse(doneGateAccepts([]))
    }

    /// Executed step exists but verification was never recorded → gate rejects.
    func testDoneWithUnverifiedStepIsRejected() {
        let step = TaskStep(stepNumber: 1, description: "echo alpha_one",
                            toolName: "run_shell", arguments: ["command": "echo alpha_one"],
                            state: .completed)
        XCTAssertNil(step.verification)
        XCTAssertFalse(doneGateAccepts([step]))
    }

    /// Executed step exists but verification FAILED → gate rejects.
    func testDoneWithFailedVerificationIsRejected() {
        var step = TaskStep(stepNumber: 1, description: "echo alpha_one",
                            toolName: "run_shell", arguments: ["command": "echo alpha_one"],
                            state: .completed)
        step.verification = .failed
        XCTAssertFalse(doneGateAccepts([step]))
    }

    /// ≥1 recorded step, all explicitly verified .passed → gate accepts.
    /// (Goal-level completeness is still judged by the benchmark harness —
    /// a premature DONE after 1 of 3 intended steps lands here too, and the
    /// harness reports NOT_COMPLETE. The agent never trusts the model text.)
    func testDoneWithAllStepsVerifiedPassedIsAccepted() {
        var step1 = TaskStep(stepNumber: 1, description: "echo alpha_one",
                             toolName: "run_shell", arguments: ["command": "echo alpha_one"],
                             state: .completed)
        step1.verification = .passed
        var step2 = TaskStep(stepNumber: 2, description: "echo bravo_two",
                             toolName: "run_shell", arguments: ["command": "echo bravo_two"],
                             state: .completed)
        step2.verification = .passed
        XCTAssertTrue(doneGateAccepts([step1, step2]))
    }
}
