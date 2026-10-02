import Foundation
import Testing
@testable import Jarvis

/// Adversarial regression coverage for `git` as an execution trampoline.
///
/// `git` is deliberately allowed as a program (Zia needs `git status`, `git log`,
/// `git diff`, …). But several git forms launch ANOTHER executable that layer 3
/// never sees: config overrides for `alias`/`pager`/`editor`/`fsmonitor`/
/// `sshCommand`/`credential.helper`/`diff.external`, plus the execution
/// subcommands `filter-branch`, `filter-repo`, `difftool`, `mergetool`,
/// `rebase --exec`, `bisect run`, and `submodule foreach`.
///
/// These tests are zero-model-call and exercise the exact API used by
/// PlanValidator, TaskExecutionCoordinator, TaskWorker, ShellExecutor, and
/// DeterministicRouter (`CommandSandbox.isSafe`).
@Suite struct CommandSandboxGitTrampolineTests {

    @Test @MainActor
    func configOverrideCannotLaunchProgram() {
        #expect(!CommandSandbox.shared.isSafe("git -c alias.pwn='!echo hi' pwn"),
                "git -c alias=!cmd executes arbitrary code and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git -c core.pager='!echo hi' log"),
                "git -c core.pager executes arbitrary code and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git -c core.fsmonitor='!echo hi' status"),
                "git -c core.fsmonitor executes arbitrary code and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git --config core.editor='!echo hi' commit"),
                "git --config executes arbitrary code and must be blocked")
    }

    @Test @MainActor
    func executionSubcommandsAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("git rebase --exec 'echo hi' HEAD~1"),
                "git rebase --exec runs a command per commit and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git bisect run echo hi"),
                "git bisect run executes an arbitrary command and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git submodule foreach 'echo hi'"),
                "git submodule foreach executes a command and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git filter-branch --tree-filter 'echo hi' HEAD"),
                "git filter-branch executes commands and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git difftool --no-prompt HEAD"),
                "git difftool launches a configured external program and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("git config core.pager '!echo hi'"),
                "writing an execution config value must be blocked")
    }

    // MARK: - Adversarial negative: legitimate read-only git must survive

    @Test @MainActor
    func legitimateGitCommandsRemainAllowed() {
        #expect(CommandSandbox.shared.isSafe("git status"))
        #expect(CommandSandbox.shared.isSafe("git log --oneline -5"))
        #expect(CommandSandbox.shared.isSafe("git diff"))
        #expect(CommandSandbox.shared.isSafe("git diff --staged"))
        #expect(CommandSandbox.shared.isSafe("git branch"))
        #expect(CommandSandbox.shared.isSafe("git rev-parse HEAD"))
        #expect(CommandSandbox.shared.isSafe("git show HEAD"))
        #expect(CommandSandbox.shared.isSafe("git remote -v"))
        #expect(CommandSandbox.shared.isSafe("git config --get user.name"),
                "reading git config must remain allowed")
        #expect(CommandSandbox.shared.isSafe("git stash list"))
        // `-c` is a subcommand flag here, NOT a global config override.
        #expect(CommandSandbox.shared.isSafe("git diff -c"),
                "git diff -c is a subcommand flag and must not be mistaken for a config override")
        #expect(CommandSandbox.shared.isSafe("git show -c HEAD"),
                "git show -c is a subcommand flag and must not be mistaken for a config override")
    }
}
