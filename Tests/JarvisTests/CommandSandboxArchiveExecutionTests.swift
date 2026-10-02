import Foundation
import Testing
@testable import Jarvis

/// Adversarial coverage for archive tools that launch external programs.
///
/// bsdtar (macOS `/usr/bin/tar`) spawns the program named by
/// `--use-compress-program`/`-I` as a subprocess (observed: it attempted to run
/// the supplied command and reported "Can't write to program: …"). GNU tar adds
/// `--to-command`/`--to-program` (run a program per member) and
/// `--checkpoint-action=exec=…`. Each grants the same arbitrary-process
/// authority as the already-blocked interpreters, so those options are rejected.
/// `TAR_OPTIONS` can inject the same options via the environment.
///
/// Plain archive listing/creation (`tar -tf`, `tar -cf`) stays allowed.
@Suite struct CommandSandboxArchiveExecutionTests {

    @Test @MainActor
    func tarExternalCompressProgramIsRejected() {
        #expect(!CommandSandbox.shared.isSafe("tar -I 'sh -c \"echo ZIA_PROBE\"' -cf /tmp/x.tar ~/Documents"))
        #expect(!CommandSandbox.shared.isSafe("tar --use-compress-program='sh -c \"echo ZIA_PROBE\"' -cf /tmp/x.tar ~/Documents"))
        #expect(!CommandSandbox.shared.isSafe("tar -cf /tmp/x.tar --use-compress-program=sh ~/Documents"))
    }

    @Test @MainActor
    func tarToCommandAndCheckpointExecAreRejected() {
        #expect(!CommandSandbox.shared.isSafe("tar --to-command='sh -c \"echo ZIA_PROBE\"' -xf /tmp/x.tar"))
        #expect(!CommandSandbox.shared.isSafe("tar --checkpoint-action=exec='echo ZIA_PROBE' -cf /tmp/x.tar ~/Documents"))
    }

    @Test @MainActor
    func bundledShortOptionsAndAbbreviationsAreRejected() {
        // GNU tar bundles short options; `-cIf` contains `-I`.
        #expect(!CommandSandbox.shared.isSafe("tar -cIf /tmp/x.tar 'sh -c \"echo ZIA_PROBE\"' ~/Documents"))
        // Long-option abbreviations still name the same launcher option.
        #expect(!CommandSandbox.shared.isSafe("tar --use-compress='sh -c \"echo ZIA_PROBE\"' -cf /tmp/x.tar ~/Documents"))
    }

    @Test @MainActor
    func tarOptionsEnvironmentInjectionIsRejected() {
        #expect(!CommandSandbox.shared.isSafe("TAR_OPTIONS='--use-compress-program=sh -c echo' tar -cf /tmp/x.tar ~/Documents"))
    }

    @Test @MainActor
    func archiveLaunchersAreNotHidableByPathOrWrapper() {
        #expect(!CommandSandbox.shared.isSafe("/usr/bin/tar -I 'sh -c \"echo ZIA_PROBE\"' -cf /tmp/x.tar ~/Documents"))
        #expect(!CommandSandbox.shared.isSafe("env tar -I 'sh -c \"echo ZIA_PROBE\"' -cf /tmp/x.tar ~/Documents"))
    }

    // MARK: - No-overblock: ordinary archive usage remains allowed

    @Test @MainActor
    func legitimateArchiveUsageRemainsAllowed() {
        let allowed = [
            "tar -tf ~/Documents/archive.tar",
            "tar -tzf ~/Documents/archive.tar.gz",
            "tar -cf ~/Documents/out.tar ~/Documents/notes.txt",
            "tar -czf ~/Documents/out.tar.gz ~/Documents/notes.txt",
            "tar -xf ~/Documents/archive.tar -C ~/Documents"
        ]
        for command in allowed {
            #expect(CommandSandbox.shared.isSafe(command), "legitimate archive command must remain allowed: \(command)")
        }
    }

    @Test @MainActor
    func tarNameAsArgumentIsNotBlocked() {
        #expect(CommandSandbox.shared.isSafe("echo tar"),
                "echo-ing the word tar must not be blocked")
    }
}
