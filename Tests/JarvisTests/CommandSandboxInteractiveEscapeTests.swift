import Foundation
import Testing
@testable import Jarvis

/// Adversarial coverage for the interactive-program shell-escape class.
///
/// Zia runs `run_shell` non-interactively (`/bin/zsh -c` with captured stdout),
/// and the repository inventory shows no production or test use of any editor,
/// pager, debugger, or database CLI. These programs expose a documented
/// child-process escape (`vim -c ':!cmd'`, `less` `!cmd`, `man -P cmd`,
/// `gdb`/`lldb` `shell`, `.shell`/`system` in DB CLIs) so an allowed-looking
/// command can launch another program. They are therefore the same
/// execution-capability class as the interpreters and runners.
@Suite struct CommandSandboxInteractiveEscapeTests {

    @Test @MainActor
    func editorsWithShellEscapeAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("vim -c ':!echo ZIA_PROBE' -c ':q'"))
        #expect(!CommandSandbox.shared.isSafe("vim +'!echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("vi -c '!echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("nvim -c '!echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("ex -c '!echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("ed -s file.txt"))
        #expect(!CommandSandbox.shared.isSafe("emacs --batch --eval '(shell-command \"echo ZIA_PROBE\")'"))
        #expect(!CommandSandbox.shared.isSafe("nano file.txt"))
    }

    @Test @MainActor
    func pagersAndDebuggersAndDatabaseCLIsAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("less ~/Documents/notes.txt"))
        #expect(!CommandSandbox.shared.isSafe("more ~/Documents/notes.txt"))
        #expect(!CommandSandbox.shared.isSafe("most ~/Documents/notes.txt"))
        #expect(!CommandSandbox.shared.isSafe("man -P 'echo ZIA_PROBE' ls"))
        #expect(!CommandSandbox.shared.isSafe("gdb -ex 'shell echo ZIA_PROBE' ./bin"))
        #expect(!CommandSandbox.shared.isSafe("lldb -o 'platform shell echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("sqlite3 test.db '.shell echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("mysql -e '\\! echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("redis-cli '!echo ZIA_PROBE'"))
    }

    @Test @MainActor
    func escapeProgramsAreNotHidableByPathOrWrapper() {
        #expect(!CommandSandbox.shared.isSafe("/usr/bin/vim -c ':!echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("env less ~/Documents/notes.txt"))
        #expect(!CommandSandbox.shared.isSafe("command man ls"))
        #expect(!CommandSandbox.shared.isSafe("nice -n 5 nano file.txt"))
    }

    // MARK: - Phase 4: missing environment/config injection gaps

    @Test @MainActor
    func pagerAndGitConfigInjectionGapsAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("MANPAGER='!echo ZIA_PROBE' man ls"))
        #expect(!CommandSandbox.shared.isSafe("GIT_CONFIG_GLOBAL=/tmp/evil git status"))
        #expect(!CommandSandbox.shared.isSafe("GIT_CONFIG_SYSTEM=/tmp/evil git status"))
        #expect(!CommandSandbox.shared.isSafe("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0='!echo hi' git log"))
        #expect(!CommandSandbox.shared.isSafe("GIT_CONFIG_KEY_0=x git log"))
    }

    // MARK: - Adversarial negative: the legitimate capability set is untouched

    @Test @MainActor
    func legitimateCapabilitiesRemainAllowed() {
        let allowed = [
            "ls -la ~/Documents", "pwd", "cat ~/Documents/notes.txt",
            "head -n 5 ~/Documents/notes.txt", "tail -n 5 ~/Documents/notes.txt",
            "grep -n foo ~/Documents/notes.txt", "wc -l ~/Documents/notes.txt",
            "file ~/Documents/notes.txt", "stat ~/Documents/notes.txt",
            "date", "whoami", "uname -a", "df -h", "du -sh ~/Documents", "ps aux",
            "echo hello", "sed -n '1p' ~/Documents/notes.txt",
            "awk '{print $1}' ~/Documents/notes.txt", "sort ~/Documents/notes.txt",
            "diff ~/Documents/notes.txt ~/Documents/notes.txt",
            "git status", "git log --oneline -5", "git diff", "git show HEAD",
            "sleep 5", "seq 1 10", "true", "false"
        ]
        for command in allowed {
            #expect(CommandSandbox.shared.isSafe(command), "legitimate command must remain allowed: \(command)")
        }
    }

    @Test @MainActor
    func escapeProgramNameAsArgumentIsNotBlocked() {
        #expect(CommandSandbox.shared.isSafe("echo vim"),
                "echo-ing the word vim must not be blocked")
        #expect(CommandSandbox.shared.isSafe("grep less ~/Documents/notes.txt"),
                "searching for the word less must not be blocked")
    }
}
