import Testing
@testable import Jarvis

/// Regression: a command must not be able to LAUNCH another program (or a
/// document the OS will execute) from inside `run_shell`.
///
/// Real-world failure this prevents: the layer-3 program analysis only classified
/// INTERPRETERS, runners, pagers, and network launchers. Two launcher classes
/// slipped through and gave full arbitrary-code execution from a command the
/// sandbox called safe:
///
///     open -a Terminal /tmp/x.sh   → Terminal runs the script
///     open -b com.apple.Terminal … → same, selected by bundle id
///     open /tmp/x.command          → LaunchServices runs the .command file
///     . /tmp/x.sh                  → the POSIX `source` builtin evaluates it
///     builtin . /tmp/x.sh          → the same, through a wrapper
///
/// Zia has dedicated, verified `open_app`/`open_browser` tools for legitimate
/// launching, so `run_shell` never needs `open`; the `.`/source builtin is an
/// alias of the already-blocked `source`. Both are now rejected. The fix is
/// precise: `.` used as an ordinary ARGUMENT (`find . -name …`) still works.
@Suite struct CommandSandboxLauncherTests {

    private let launcherEscapes = [
        "open -a Terminal /tmp/zia_probe.sh",
        "open -b com.apple.Terminal /tmp/zia_probe.sh",
        "open -a Terminal --args /tmp/zia_probe.sh",
        "open /tmp/zia_probe.command",
        "open -a Calculator",
        ". /tmp/zia_probe.sh",
        "builtin . /tmp/zia_probe.sh",
        ". ./relative_script.sh",
    ]

    private let stillBenign = [
        "ls /tmp",
        "cat /tmp/foo.txt",
        "echo hello",
        "find . -name '*.tmp' -delete",
        "git status",
        "cat /tmp/f | sort",
        "sort -u /tmp/f",
    ]

    @Test @MainActor
    func programLaunchersAndDotBuiltinAreRejected() {
        for command in launcherEscapes {
            #expect(!CommandSandbox.shared.isSafe(command), "sandbox must reject '\(command)'")
        }
    }

    @Test @MainActor
    func ordinaryDotArgumentAndBenignCommandsRemainPermitted() {
        for command in stillBenign {
            #expect(CommandSandbox.shared.isSafe(command), "ordinary command '\(command)' must remain permitted")
        }
    }
}
