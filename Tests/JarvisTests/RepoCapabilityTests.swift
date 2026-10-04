import Foundation
import Testing
@testable import Jarvis

/// The `git` capability class: authorized ONLY for pinned read-only argv shapes,
/// so it can never launch another program or mutate the repository. Reached
/// through the deterministic repository-inspection capabilities with no shell
/// and no model call.
@Suite struct RepoCapabilityTests {

    @MainActor
    private func expectRejected(_ message: String, _ operation: @MainActor () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected rejection: \(message)")
        } catch {
            // Expected.
        }
    }

    // MARK: - Pinned git argument policy

    @Test @MainActor
    func pinnedReadOnlyGitShapesAreAuthorized() throws {
        let allowed: [[String]] = [
            ["status"],
            ["status", "--porcelain"],
            ["status", "--short", "--branch"],
            ["rev-parse", "--abbrev-ref", "HEAD"],
            ["rev-parse", "HEAD"],
            ["branch", "--show-current"],
            ["branch"],
            ["log", "--oneline"],
            ["log", "--oneline", "-n", "5"],
            ["diff", "--stat"],
            ["diff", "--name-only"]
        ]
        for args in allowed {
            let authorized = try ProcessAuthority.shared.authorize(.structured(executable: "git", arguments: args))
            #expect(authorized.arguments == args)
        }
    }

    @Test @MainActor
    func dangerousGitInvocationsAreRejected() {
        let rejected: [[String]] = [
            [],
            ["push"],
            ["reset", "--hard"],
            ["clean", "-fd"],
            ["-c", "core.pager=evil", "status"],
            ["--exec-path=/tmp/evil", "status"],
            ["config", "--global", "alias.x", "sh -c evil"],
            ["branch", "-D", "main"],
            ["filter-branch", "--tree-filter", "rm -rf ."],
            ["bisect", "run", "sh"],
            ["submodule", "foreach", "sh -c evil"],
            ["log", "--format=%x06", "--exec=evil"],
            ["status", "&& echo pwned"],
            ["status", "; rm -rf /"]
        ]
        for args in rejected {
            expectRejected("git \(args)") {
                _ = try ProcessAuthority.shared.authorize(.structured(executable: "git", arguments: args))
            }
        }
    }

    @Test @MainActor
    func gitIsNotAnUnrestrictedStructuredProgram() {
        // A bare `git` with no pinned shape must not be treated like `echo`.
        expectRejected("bare git with arbitrary args") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: "git", arguments: ["whatever"]))
        }
    }

    @Test @MainActor
    func planValidatorRejectsDangerousGitInvocation() {
        let plan = AgentPlan(goal: "run the tool", steps: [
            PlanStep(id: "step_1", toolName: "run_program",
                     arguments: ["executable": "git", "arguments": "[\"reset\", \"--hard\"]"],
                     purpose: "reset")
        ])
        guard case .failure = PlanValidator.validate(plan, originalGoal: "run the tool") else {
            Issue.record("plan with a mutating git invocation was accepted")
            return
        }
    }

    @Test @MainActor
    func planValidatorAcceptsPinnedGitStatus() {
        let plan = AgentPlan(goal: "print hello", steps: [
            PlanStep(id: "step_1", toolName: "run_program",
                     arguments: ["executable": "git", "arguments": "[\"status\", \"--porcelain\"]"],
                     purpose: "inspect repo")
        ])
        guard case .success = PlanValidator.validate(plan, originalGoal: "print hello") else {
            Issue.record("pinned read-only git plan was rejected")
            return
        }
    }

    // MARK: - Deterministic capabilities

    @Test @MainActor
    func gitStatusCapabilityRunsStructurally() async throws {
        guard let match = DeterministicRouter.shared.match("git status") else {
            Issue.record("git status capability did not match")
            return
        }
        #expect(match.intent == "repo.status")
        let result = try await match.action()
        #expect(!result.isEmpty)
    }

    @Test @MainActor
    func gitBranchCapabilityRunsStructurally() async throws {
        guard let match = DeterministicRouter.shared.match("current branch") else {
            Issue.record("branch capability did not match")
            return
        }
        #expect(match.intent == "repo.branch")
        let result = try await match.action()
        #expect(!result.isEmpty)
    }
}
