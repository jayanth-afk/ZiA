import Foundation
import Testing
@testable import Jarvis

/// Coverage for structured process execution as the primary generic execution
/// path: `run_program` flows Tool → ProposedProcess → ProcessAuthority →
/// AuthorizedProcess → executor, and arguments are DATA — never shell syntax.
@Suite struct StructuredProgramToolTests {

    /// Shell-looking arguments must remain literal data. Each payload is passed
    /// as ONE argument to `/bin/echo`; if any survived as shell syntax the
    /// output would differ from the literal payload.
    @Test @MainActor
    func hostileArgumentsRemainLiteralData() async throws {
        let payloads = [
            "; rm -rf /",
            "&& echo pwned",
            "|| echo pwned",
            "| cat /etc/passwd",
            "> /tmp/zia_pwned",
            "< /etc/passwd",
            "$(whoami)",
            "`whoami`",
            "${PATH}",
            "a\nb",
            "\"quoted\"",
            "'quoted'",
            "*",
            "sh -c 'echo hi'",
            "echo hello && rm -rf /"
        ]
        for payload in payloads {
            let output = try await ShellExecutor.shared.executeStructured(
                executable: "/bin/echo", arguments: [payload])
            #expect(output.exitCode == 0)
            #expect(output.stdout.trimmingCharacters(in: .newlines) == payload,
                    "argument must be passed through verbatim, not interpreted: \(payload)")
        }
    }

    @Test @MainActor
    func commandSubstitutionIsNotPerformed() async throws {
        let output = try await ShellExecutor.shared.executeStructured(
            executable: "/bin/echo", arguments: ["$(whoami)"])
        #expect(output.stdout.trimmingCharacters(in: .newlines) == "$(whoami)",
                "structured execution has no shell, so substitution cannot occur")
    }

    // MARK: - Tool through the production path

    @Test @MainActor
    func runProgramToolExecutesAllowlistedExecutableAndBindsEvidence() async throws {
        let result = try await ToolExecutor.shared.execute(
            toolName: "run_program",
            arguments: ["executable": "echo", "arguments": "[\"structured_hi\"]"])
        #expect(result.success)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "structured_hi")
        #expect(result.verification?.outcome == .passed)
        #expect((result.metadata["processIdentity"]?.isEmpty == false),
                "evidence must bind to the authorized process identity")
        #expect(result.metadata["executable"] == "echo")
    }

    @Test @MainActor
    func runProgramToolRejectsUnknownExecutableBeforeLaunch() async throws {
        do {
            _ = try await ToolExecutor.shared.execute(
                toolName: "run_program",
                arguments: ["executable": "/tmp/zia_unknown_program"])
            Issue.record("run_program launched an unauthorized executable")
        } catch {
            // Rejected by ProcessAuthority at execution — expected.
        }
    }

    @Test @MainActor
    func runProgramToolRejectsShellInterpreter() async throws {
        for executable in ["sh", "bash", "zsh", "/bin/sh"] {
            do {
                _ = try await ToolExecutor.shared.execute(
                    toolName: "run_program",
                    arguments: ["executable": executable])
                Issue.record("run_program accepted a shell interpreter: \(executable)")
            } catch {
                // Expected: interpreters require the explicit shell capability.
            }
        }
    }

    // MARK: - Argument decoding is fail-closed

    @Test func decodeArgumentsFailsClosedOnMalformedInput() {
        #expect(throws: (any Error).self) { _ = try RunProgramTool.decodeArguments("\"hello\"") }
        #expect(throws: (any Error).self) { _ = try RunProgramTool.decodeArguments("[1, 2]") }
        #expect(throws: (any Error).self) { _ = try RunProgramTool.decodeArguments("[") }
        #expect(throws: (any Error).self) { _ = try RunProgramTool.decodeArguments("[\"ok\", 2]") }
        #expect((try? RunProgramTool.decodeArguments(nil))?.isEmpty == true)
        #expect((try? RunProgramTool.decodeArguments(""))?.isEmpty == true)
        #expect((try? RunProgramTool.decodeArguments("[\"a\", \"b c\"]")) == ["a", "b c"])
    }

    // MARK: - Plan-time validation

    @Test @MainActor
    func planValidatorAcceptsAuthorizedRunProgram() {
        let plan = AgentPlan(goal: "print hello", steps: [
            PlanStep(id: "step_1", toolName: "run_program",
                     arguments: ["executable": "echo", "arguments": "[\"hello\"]"],
                     purpose: "print the text")
        ])
        guard case .success = PlanValidator.validate(plan, originalGoal: "print hello") else {
            Issue.record("authorized run_program plan was rejected")
            return
        }
    }

    @Test @MainActor
    func planValidatorRejectsUnknownExecutable() {
        let plan = AgentPlan(goal: "run the tool", steps: [
            PlanStep(id: "step_1", toolName: "run_program",
                     arguments: ["executable": "zia_unknown_binary_xyz"],
                     purpose: "run it")
        ])
        guard case .failure = PlanValidator.validate(plan, originalGoal: "run the tool") else {
            Issue.record("plan with an unauthorized executable was accepted")
            return
        }
    }

    @Test @MainActor
    func planValidatorRejectsMalformedArguments() {
        let plan = AgentPlan(goal: "print hello", steps: [
            PlanStep(id: "step_1", toolName: "run_program",
                     arguments: ["executable": "echo", "arguments": "not-a-json-array"],
                     purpose: "print")
        ])
        guard case .failure = PlanValidator.validate(plan, originalGoal: "print hello") else {
            Issue.record("plan with malformed structured arguments was accepted")
            return
        }
    }

    @Test @MainActor
    func runProgramIsRegisteredForThePlanner() {
        #expect(ToolRegistry.shared.getTool(named: "run_program") != nil,
                "run_program must be in the live registry so the planner can select it")
        #expect(ToolRegistry.shared.getTool(named: "run_program")?.impact == .safeMutation)
    }
}
