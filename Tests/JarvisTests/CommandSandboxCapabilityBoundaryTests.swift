import Foundation
import Testing
@testable import Jarvis

/// Adversarial + no-overblock coverage for the code-execution capability
/// boundary.
///
/// `run_shell` already rejects the *interpreter* class (`sh`, `python`, `node`,
/// …) because its purpose is to execute arbitrary code. Build / package / task
/// runners are the same capability class: their whole function is to execute
/// project- or package-controlled scripts (build files, install hooks,
/// plugins). The evidence inventory shows Zia has no production or test usage
/// of any of them, so they are rejected as unsupported execution capabilities.
///
/// Adjacent vector: environment assignments that redirect program loading or
/// command resolution (`DYLD_INSERT_LIBRARIES`, `LD_PRELOAD`, `PATH`,
/// `BASH_ENV`, `IFS`, `GIT_PAGER`, `PAGER`, …) can turn an otherwise allowed
/// binary into a trampoline. Only assignments in command position are treated
/// as injection; `echo FOO=bar` stays legal.
@Suite struct CommandSandboxCapabilityBoundaryTests {

    // MARK: - Build / package / task runners

    @Test @MainActor
    func buildAndPackageRunnersAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("make all"))
        #expect(!CommandSandbox.shared.isSafe("make"))
        #expect(!CommandSandbox.shared.isSafe("cmake --build build"))
        #expect(!CommandSandbox.shared.isSafe("npm install"))
        #expect(!CommandSandbox.shared.isSafe("npm run build"))
        #expect(!CommandSandbox.shared.isSafe("npx cowsay hi"))
        #expect(!CommandSandbox.shared.isSafe("yarn build"))
        #expect(!CommandSandbox.shared.isSafe("pnpm install"))
        #expect(!CommandSandbox.shared.isSafe("cargo run"))
        #expect(!CommandSandbox.shared.isSafe("go run main.go"))
        #expect(!CommandSandbox.shared.isSafe("go build ./..."))
        #expect(!CommandSandbox.shared.isSafe("xcodebuild -scheme Jarvis build"))
        #expect(!CommandSandbox.shared.isSafe("xcrun simctl list"))
        #expect(!CommandSandbox.shared.isSafe("bazel build //..."))
        #expect(!CommandSandbox.shared.isSafe("gradle assemble"))
        #expect(!CommandSandbox.shared.isSafe("mvn package"))
        #expect(!CommandSandbox.shared.isSafe("rake test"))
        #expect(!CommandSandbox.shared.isSafe("bundle install"))
        #expect(!CommandSandbox.shared.isSafe("gem install rake"))
        #expect(!CommandSandbox.shared.isSafe("pip3 install requests"))
        #expect(!CommandSandbox.shared.isSafe("brew install wget"))
        #expect(!CommandSandbox.shared.isSafe("docker run alpine echo hi"))
        #expect(!CommandSandbox.shared.isSafe("podman run alpine echo hi"))
    }

    @Test @MainActor
    func absolutePathAndWrapperCannotHideARunner() {
        #expect(!CommandSandbox.shared.isSafe("/usr/bin/make all"),
                "absolute path must not hide a runner")
        #expect(!CommandSandbox.shared.isSafe("env npm install"),
                "the env wrapper must not hide a runner")
        #expect(!CommandSandbox.shared.isSafe("command cargo build"),
                "the command wrapper must not hide a runner")
        #expect(!CommandSandbox.shared.isSafe("nice -n 5 xcodebuild -version"),
                "the nice wrapper must not hide a runner")
    }

    // MARK: - Environment injection

    @Test @MainActor
    func dynamicLoaderAndResolutionInjectionsAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("DYLD_INSERT_LIBRARIES=/tmp/evil.dylib ls"))
        #expect(!CommandSandbox.shared.isSafe("LD_PRELOAD=/tmp/evil.so ls"))
        #expect(!CommandSandbox.shared.isSafe("LD_LIBRARY_PATH=/tmp/evil ls"))
        #expect(!CommandSandbox.shared.isSafe("DYLD_LIBRARY_PATH=/tmp/evil ls"))
        #expect(!CommandSandbox.shared.isSafe("PATH=/tmp/evil:$PATH ls"))
        #expect(!CommandSandbox.shared.isSafe("BASH_ENV=/tmp/evil.sh echo hi"))
        #expect(!CommandSandbox.shared.isSafe("IFS=x ls"))
        #expect(!CommandSandbox.shared.isSafe("GIT_PAGER='!echo hi' git log"),
                "GIT_PAGER can execute a program and must be rejected")
        #expect(!CommandSandbox.shared.isSafe("LESSOPEN='|echo hi' less file"))
        #expect(!CommandSandbox.shared.isSafe("env GIT_SSH_COMMAND='echo hi' git fetch"))
    }

    // MARK: - No over-blocking: legitimate capability set must survive

    @Test @MainActor
    func legitimateReadAndTextProcessingRemainAllowed() {
        let allowed = [
            "ls -la ~/Documents", "pwd", "cat ~/Documents/notes.txt",
            "head -n 5 ~/Documents/notes.txt", "tail -n 5 ~/Documents/notes.txt",
            "grep -n foo ~/Documents/notes.txt", "find ~/Documents -name '*.txt'",
            "wc -l ~/Documents/notes.txt", "file ~/Documents/notes.txt",
            "stat ~/Documents/notes.txt", "date", "whoami", "uname -a",
            "df -h", "du -sh ~/Documents", "ps aux",
            "echo hello", "sed -n '1p' ~/Documents/notes.txt",
            "awk '{print $1}' ~/Documents/notes.txt", "sort ~/Documents/notes.txt",
            "uniq ~/Documents/notes.txt", "diff ~/Documents/notes.txt ~/Documents/notes.txt",
            "mdfind kMDItemFSName==notes", "env", "printenv PATH",
            "git status", "git branch", "git log --oneline -5", "git diff",
            "git rev-parse HEAD", "git show HEAD", "git remote -v",
            "git config --get user.name", "git stash list",
            "sleep 5", "seq 1 10", "exit 0", "true", "false"
        ]
        for command in allowed {
            #expect(CommandSandbox.shared.isSafe(command), "legitimate command must remain allowed: \(command)")
        }
    }

    @Test @MainActor
    func plainVariableTextInArgumentsIsNotInjection() {
        // NAME=value that is an ARGUMENT (after the program) is not an
        // environment assignment and must not be treated as injection.
        #expect(CommandSandbox.shared.isSafe("echo FOO=bar"))
        #expect(CommandSandbox.shared.isSafe("echo DYLD_INSERT_LIBRARIES=x"),
                "printing the literal text must not be blocked")
        #expect(CommandSandbox.shared.isSafe("grep PATH= ~/Documents/notes.txt"))
    }
}
