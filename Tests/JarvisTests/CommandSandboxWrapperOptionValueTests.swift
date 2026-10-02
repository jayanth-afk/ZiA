import Foundation
import Testing
@testable import Jarvis

/// Adversarial coverage for wrapper option values that are not numeric.
///
/// The layer-3 wrapper unwrapping skips option flags and numeric option
/// values, but a wrapper option with a NON-numeric value (e.g. `stdbuf -o L`)
/// would be mistaken for the executable, hiding the real program the wrapper
/// launches. `xargs -I <placeholder>` similarly injects a non-option token
/// before the command.
@Suite struct CommandSandboxWrapperOptionValueTests {

    @Test @MainActor
    func stdbufNonNumericModeCannotHideLaunchedProgram() {
        #expect(!CommandSandbox.shared.isSafe("stdbuf -o L sh -c 'echo ZIA_PROBE'"))
        #expect(!CommandSandbox.shared.isSafe("stdbuf -e L vim ~/Documents/notes.txt"))
        #expect(!CommandSandbox.shared.isSafe("stdbuf -i L ssh host echo ZIA_PROBE"))
        #expect(!CommandSandbox.shared.isSafe("stdbuf -o L rm -rf ~/Documents/zia_probe.txt"))
    }

    @Test @MainActor
    func xargsPlaceholderCannotHideLaunchedProgram() {
        #expect(!CommandSandbox.shared.isSafe("xargs -I @ rm"))
        #expect(!CommandSandbox.shared.isSafe("xargs -I @ ssh host echo ZIA_PROBE"))
        #expect(!CommandSandbox.shared.isSafe("printf '%s' ~/Documents/zia_probe.txt | xargs -I @ rm"))
    }

    // MARK: - No-overblock: legitimate wrapper usage remains allowed

    @Test @MainActor
    func legitimateWrapperUsageRemainsAllowed() {
        let allowed = [
            "stdbuf -o 0 cat ~/Documents/notes.txt",
            "stdbuf -oL cat ~/Documents/notes.txt",
            "nice -n 10 cat ~/Documents/notes.txt",
            "xargs -n 1 echo",
            "env FOO=bar ls ~/Documents",
            "nohup cat ~/Documents/notes.txt"
        ]
        for command in allowed {
            #expect(CommandSandbox.shared.isSafe(command), "legitimate command must remain allowed: \(command)")
        }
    }
}
