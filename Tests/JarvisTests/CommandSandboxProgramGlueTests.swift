import Testing
@testable import Jarvis

/// Regression: a blocked program must not be hidden by the shell SYNTAX that
/// surrounds it.
///
/// Real-world failure this prevents: the layer-3 program analysis only looked at
/// the basename of each whitespace-separated token. Because redirection and
/// here-string operators need no surrounding whitespace, an interpreter could be
/// glued to them and never recognised:
///
///     sh<<<'echo pwned'     → executes an arbitrary here-string as a script
///     sh</tmp/script        → executes an arbitrary local file as a script
///     sh>out                → same, with the interpreter still the program
///
/// A single `&` had the same effect at the segment level: segments() split on
/// `&&`, `||`, `;`, `|` and newlines but NOT on a lone `&`, so everything after
/// `prog & sh` was never program-checked. And `sort --compress-program=PROG`
/// spawns PROG as a subprocess (the same authority as the tar option the audit
/// already blocked), which the `=`-attached form hid from the program analysis.
///
/// Each case below must be rejected while the ordinary use of the same syntax
/// stays permitted (the fix is precise, not a blanket ban on redirection).
@Suite struct CommandSandboxProgramGlueTests {

    @MainActor
    private func allBlocked(_ commands: [String]) {
        for command in commands {
            #expect(!CommandSandbox.shared.isSafe(command),
                    "sandbox must reject '\(command)'")
        }
    }

    /// A blocked interpreter glued to a here-string / redirection is the program.
    @Test @MainActor
    func interpreterGluedToRedirectionIsRejected() {
        allBlocked([
            "sh<<<'echo pwned'",
            "bash<<<'echo pwned'",
            "zsh<<<'echo pwned'",
            "sh<<<pwd",
            "/bin/sh<<<'echo pwned'",
            "bash<<</tmp/x",
            "sh</etc/passwd",
            "sh</tmp/x",
            "sh<file",
            "sh>out",
            "/bin/sh</tmp/x",
        ])
    }

    /// A single `&` (job control) separates commands just like `;`.
    @Test @MainActor
    func trailingBackgroundCommandIsProgramChecked() {
        allBlocked([
            "echo hi & sh",
            "echo hi & sh -c 'echo pwned'",
            "true & sh",
            "pwd & bash<<<'echo pwned'",
        ])
    }

    /// `sort --compress-program[=]PROG` launches PROG as a subprocess.
    @Test @MainActor
    func sortCompressProgramIsRejected() {
        allBlocked([
            "sort --compress-program=sh /tmp/f",
            "sort --compress-program sh /tmp/f",
            "sort --compress-program=/tmp/x /tmp/f",
        ])
    }

    /// The fix must not break the benign use of the very same syntax.
    @Test @MainActor
    func benignRedirectionAndChainingStillAllowed() {
        let commands = [
            "wc<<<'x'",
            "sed 's/a/b/' /tmp/f",
            "git status",
            "find . -name '*.tmp' -delete",
            "sort /tmp/f",
            "sort -u /tmp/f",
            "ls 2>&1",
            "echo hi & ",
            "echo hello",
            "pwd",
            "cat /tmp/f | sort",
            "git log --oneline -5",
        ]
        for command in commands {
            #expect(CommandSandbox.shared.isSafe(command),
                    "ordinary command '\(command)' must remain permitted")
        }
    }
}
