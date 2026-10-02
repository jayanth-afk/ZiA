import Foundation
import Testing
@testable import Jarvis

/// Adversarial regression coverage for shell command generation.
///
/// `ShellExecutor` runs every command through `/bin/zsh -c`, so syntactically
/// valid text can synthesize a *different* command at execution time. Layer 3
/// analyzes the tokens the sandbox can see; command substitution, backtick and
/// parameter/ANSI-C expansion, and process substitution generate commands it
/// cannot see. `echo hi$(rm file)` reads as `echo …` to layer 3 but deletes a
/// file when zsh runs it.
///
/// These tests are zero-model-call and exercise the exact API used by
/// PlanValidator, TaskExecutionCoordinator, TaskWorker, ShellExecutor, and
/// DeterministicRouter (`CommandSandbox.isSafe`).
@Suite struct CommandSandboxSubstitutionTests {

    // MARK: - Generated commands must be rejected

    @Test @MainActor
    func commandSubstitutionCannotHideDangerousCommand() {
        #expect(!CommandSandbox.shared.isSafe("echo hi$(rm ~/Documents/zia_probe.txt)"),
                "command substitution executes rm and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("echo `rm ~/Documents/zia_probe.txt`"),
                "backtick substitution executes rm and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("$(rm ~/Documents/zia_probe.txt)"),
                "a bare substitution must be blocked")
        #expect(!CommandSandbox.shared.isSafe("$(echo rm) -rf /"),
                "the audit's substitution vector must remain blocked")
    }

    @Test @MainActor
    func expansionAndQuotingCannotObfuscateDangerousCommand() {
        #expect(!CommandSandbox.shared.isSafe("echo ${IFS}rm ~/Documents/zia_probe.txt"),
                "parameter expansion obfuscation must be blocked")
        #expect(!CommandSandbox.shared.isSafe("echo $'\\x72\\x6d' -rf ~/Documents/zia_probe.txt"),
                "ANSI-C quoting can encode rm and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("cat <(rm ~/Documents/zia_probe.txt)"),
                "process substitution must be blocked")
        #expect(!CommandSandbox.shared.isSafe("awk 'BEGIN{system(\"rm ~/Documents/zia_probe.txt\")}'"),
                "awk system() is inline code execution and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("python3 -c \"print(1)\""),
                "interpreter code-eval remains blocked alongside substitution")
    }

    // MARK: - Adversarial negative: legitimate shell commands must survive

    @Test @MainActor
    func legitimateCommandsRemainAllowed() {
        #expect(CommandSandbox.shared.isSafe("echo hello"))
        #expect(CommandSandbox.shared.isSafe("git status"))
        #expect(CommandSandbox.shared.isSafe("ls -la ~/Documents"))
        #expect(CommandSandbox.shared.isSafe("cat ~/Documents/notes.txt"))
        // `$1`/`$HOME` are not command-generating constructs and must not be
        // mistaken for expansion syntax.
        #expect(CommandSandbox.shared.isSafe("awk '{print $1}' ~/Documents/notes.txt"),
                "awk field references must not be blocked")
        #expect(CommandSandbox.shared.isSafe("echo $HOME"),
                "a plain variable reference does not execute code and must not be blocked")
        #expect(CommandSandbox.shared.isSafe("sed -n '1p' ~/Documents/notes.txt"),
                "sed without expansion must remain allowed")
    }
}
