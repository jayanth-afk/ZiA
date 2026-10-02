import Foundation
import Testing
@testable import Jarvis

/// Adversarial regression coverage for interpreter / code-evaluation commands.
///
/// CommandSandbox already blocks `sh`, `bash`, `zsh`, `eval`, `exec`, `source`,
/// and `osascript` precisely because they can execute arbitrary code. A general
/// scripting interpreter (`python3 -c …`, `node -e …`, `swift -e …`) grants the
/// exact same authority, so it must be rejected by the same deterministic
/// boundary — otherwise a model-proposed `run_shell` command reaches
/// ShellExecutor with full filesystem/process/network authority.
///
/// These tests are zero-model-call and exercise the exact API used by
/// PlanValidator, TaskExecutionCoordinator, TaskWorker, and DeterministicRouter
/// (`CommandSandbox.isSafe`).
@Suite struct CommandSandboxInterpreterTests {

    // MARK: - Code-evaluation forms must be rejected

    @Test @MainActor
    func pythonCodeEvaluationIsRejected() {
        #expect(!CommandSandbox.shared.isSafe("python3 -c \"import os; os.remove('x')\""),
                "python3 -c executes arbitrary code and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("python3 -c \"import subprocess; subprocess.run(['rm','x'])\""),
                "python3 -c washing rm through subprocess must be blocked")
        #expect(!CommandSandbox.shared.isSafe("python3 -c \"print('hello')\""),
                "even a benign python3 -c is a code-evaluation form the boundary rejects")
        #expect(!CommandSandbox.shared.isSafe("python -c \"print(1)\""),
                "python (2/alias) -c must be blocked")
        #expect(!CommandSandbox.shared.isSafe("python3 -m http.server"),
                "python3 -m executes an arbitrary module and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("python3 script.py"),
                "python3 <script> executes arbitrary code and must be blocked")
    }

    @Test @MainActor
    func otherInterpretersAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("node -e \"require('fs').unlinkSync('x')\""))
        #expect(!CommandSandbox.shared.isSafe("node --eval \"require('fs').unlinkSync('x')\""))
        #expect(!CommandSandbox.shared.isSafe("node script.js"))
        #expect(!CommandSandbox.shared.isSafe("perl -e 'unlink \"x\"'"))
        #expect(!CommandSandbox.shared.isSafe("ruby -e 'File.delete(\"x\")'"))
        #expect(!CommandSandbox.shared.isSafe("php -r 'unlink(\"x\");'"))
        #expect(!CommandSandbox.shared.isSafe("lua -e 'os.remove(\"x\")'"))
        #expect(!CommandSandbox.shared.isSafe("deno eval \"Deno.removeSync('x')\""))
        #expect(!CommandSandbox.shared.isSafe("Rscript -e 'unlink(\"x\")'"))
        #expect(!CommandSandbox.shared.isSafe("julia -e 'rm(\"x\")'"))
        #expect(!CommandSandbox.shared.isSafe("tclsh script.tcl"))
    }

    @Test @MainActor
    func swiftCodeEvaluationIsRejected() {
        #expect(!CommandSandbox.shared.isSafe("swift -e 'print(1)'"),
                "swift -e evaluates arbitrary code and must be blocked")
        #expect(!CommandSandbox.shared.isSafe("swiftc -o /tmp/x x.swift"),
                "swiftc compiles arbitrary code and must be blocked")
    }

    // MARK: - Absolute paths and wrappers must not hide the interpreter

    @Test @MainActor
    func absolutePathAndWrappersCannotHideInterpreter() {
        #expect(!CommandSandbox.shared.isSafe("/usr/bin/python3 -c \"print(1)\""),
                "an absolute interpreter path must not evade layer 3")
        #expect(!CommandSandbox.shared.isSafe("/opt/homebrew/bin/python3 -c \"print(1)\""),
                "a Homebrew interpreter path must not evade layer 3")
        #expect(!CommandSandbox.shared.isSafe("/usr/local/bin/node -e \"1\""))
        #expect(!CommandSandbox.shared.isSafe("env python3 -c \"print(1)\""),
                "the env wrapper must not hide python3")
        #expect(!CommandSandbox.shared.isSafe("nice -n 10 python3 -c \"print(1)\""),
                "the nice wrapper must not hide python3")
        #expect(!CommandSandbox.shared.isSafe("command python3 -c \"print(1)\""))
        #expect(!CommandSandbox.shared.isSafe("printf '%s' x | xargs python3"),
                "xargs must not hide python3")
        #expect(!CommandSandbox.shared.isSafe("find . -name '*.py' -exec python3 {} +"),
                "find -exec must not hide python3")
    }

    // MARK: - Adversarial negative: no over-blocking of legitimate commands

    @Test @MainActor
    func interpreterNameAsArgumentOrFilenameIsNotBlocked() {
        // Layer 3 analyzes the executed program, not argument/filename text.
        #expect(CommandSandbox.shared.isSafe("cat python_notes.txt"),
                "a filename containing 'python' must not trigger the interpreter rule")
        #expect(CommandSandbox.shared.isSafe("echo python3"),
                "merely echoing the word python3 must not be blocked")
        #expect(CommandSandbox.shared.isSafe("grep python3 notes.md"),
                "searching for the word python3 must not be blocked")
    }

    @Test @MainActor
    func establishedSafeCommandsRemainAllowed() {
        #expect(CommandSandbox.shared.isSafe("ls -la ~/Documents"))
        #expect(CommandSandbox.shared.isSafe("git status"))
        #expect(CommandSandbox.shared.isSafe("echo hello"))
        #expect(CommandSandbox.shared.isSafe("pwd"))
        #expect(CommandSandbox.shared.isSafe("cat ~/Documents/notes.txt"))
    }
}
