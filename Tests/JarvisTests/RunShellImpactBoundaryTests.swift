import Foundation
import Testing
@testable import Jarvis

/// Locks the authority boundary between CommandSandbox (syntactic safety of a
/// command string) and PermissionGate (impact authorization).
///
/// `run_shell` is declared `.destructive`, so EVERY shell command — including
/// ones the sandbox considers safe and mutating ones (`sed -i`, `find -delete`,
/// `tee`, `>` redirection) — passes the destructive autonomy gate regardless of
/// the sandbox verdict. "CommandSandbox says safe" must never become
/// "PermissionGate says permitted".
@Suite(.serialized) struct RunShellImpactBoundaryTests {

    @Test @MainActor
    func runShellIsDeclaredDestructive() {
        let tool = ToolRegistry.shared.getTool(named: "run_shell")
        #expect(tool?.impact == .destructive,
                "run_shell must stay .destructive so the sandbox verdict can never imply permission")
    }

    @Test @MainActor
    func sandboxSafeShellCommandIsDeniedBelowDestructiveAutonomy() async {
        DestructiveActionManager.shared.cancel()
        let original = Config.shared.autonomyLevel
        Config.shared.autonomyLevel = 1 // L1 supervised: destructive actions need confirmation
        defer { Config.shared.autonomyLevel = original }

        do {
            _ = try await ToolExecutor.shared.execute(
                toolName: "run_shell", arguments: ["command": "echo zia_gate_probe"])
            Issue.record("A sandbox-safe shell command was permitted below the destructive autonomy level")
        } catch let error as JarvisError {
            guard case .permissionDenied = error else {
                Issue.record("Expected permissionDenied, got: \(error)")
                return
            }
        } catch {
            Issue.record("Expected JarvisError.permissionDenied, got: \(error)")
        }
    }

    @Test @MainActor
    func mutationIsContainedByTheImpactGateNotTheSandbox() {
        // These are sandbox-SAFE: they are user-file mutations, not blocked
        // program/code execution. The sandbox is a code-execution boundary; the
        // destructive impact gate is what contains mutation. Asserting both
        // halves locks the separation of concerns.
        #expect(CommandSandbox.shared.isSafe("sed -i '' s/a/b/ ~/Documents/zia_probe.txt"))
        #expect(CommandSandbox.shared.isSafe("find ~/Documents -name '*.tmp' -delete"))
        #expect(ToolRegistry.shared.getTool(named: "run_shell")?.impact == .destructive)
    }
}
