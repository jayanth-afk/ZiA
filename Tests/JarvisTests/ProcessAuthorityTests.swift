import Foundation
import Testing
@testable import Jarvis

/// Adversarial + no-overblock coverage for the structured process execution
/// authority.
///
/// The invariant under test: **intelligence may propose a process, but only the
/// authority layer may authorize one.** Unknown executables are never
/// automatically trusted; the absence of a path from a denylist grants nothing.
/// Only a canonical path explicitly allowlisted inside a root-owned system
/// directory is authorized, and shell interpretation is a separate capability.
///
/// Every test uses harmless marker executables. No destructive payload is run.
@Suite struct ProcessAuthorityTests {

    // MARK: - Helpers

    private func makeTempExecutable(named name: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zia-authority-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\necho zia_authority_marker\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Asserts that an authorization attempt is rejected. Each test identifies
    /// the rejecting layer in its own comment.
    @MainActor
    private func expectRejected(_ message: String, _ operation: @MainActor () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected authorization rejection: \(message)")
        } catch {
            // Rejected by the authority layer — expected.
        }
    }

    // MARK: - 1. Known authorized executable

    @Test @MainActor
    func knownAuthorizedExecutableIsAccepted() throws {
        let authorized = try ProcessAuthority.shared.authorize(
            .structured(executable: "/bin/echo", arguments: ["hello"]))
        #expect(authorized.capability == .structured)
        #expect(authorized.arguments == ["hello"])
        #expect(authorized.executableURL.path.hasPrefix("/"))
        #expect(ProcessAuthority.authorizedExecutables.contains(authorized.executablePath))
        #expect(!authorized.identity.isEmpty)
    }

    /// A bare name resolves through the FIXED trusted-directory search, never
    /// the ambient PATH.
    @Test @MainActor
    func bareAuthorizedNameResolvesThroughFixedSearch() throws {
        let authorized = try ProcessAuthority.shared.authorize(.structured(executable: "echo"))
        #expect(ProcessAuthority.authorizedExecutables.contains(authorized.executablePath),
                "bare 'echo' must resolve to an allowlisted canonical path")
    }

    // MARK: - 2/3/4/8. Unknown, /tmp, and relative executables

    @Test @MainActor
    func unknownBareExecutableIsRejected() {
        expectRejected("unknown bare executable") {
            _ = try ProcessAuthority.shared.authorize(
                .structured(executable: "zia_no_such_binary_\(UUID().uuidString.prefix(6))"))
        }
    }

    @Test @MainActor
    func randomExecutableInTemporaryDirectoryIsRejected() throws {
        let payload = try makeTempExecutable(named: "zia_payload")
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        expectRejected("random executable in the temporary directory") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: payload.path))
        }
    }

    /// A relative executable resolves against the working directory and is then
    /// rejected because its canonical path is outside the trusted directories.
    /// No working-directory mutation is performed (tests run in parallel).
    @Test @MainActor
    func relativeExecutableIsRejected() {
        expectRejected("relative executable in the current working directory") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: "./zia_no_such_relative"))
        }
    }

    /// A bare name that is not in a trusted system directory is rejected; there
    /// is no cwd/PATH lookup for structured execution.
    @Test @MainActor
    func bareNameNotInTrustedDirectoryIsRejected() {
        expectRejected("bare name resolvable only from the working directory") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: "zia_cwd_only_binary"))
        }
    }

    // MARK: - 5. Renamed copy of an authorized executable

    @Test @MainActor
    func renamedCopyOfAuthorizedExecutableIsRejected() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zia-renamed-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renamed = directory.appendingPathComponent("not_echo")
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: renamed.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renamed.path)

        // Same bytes as an authorized binary, different identity — rejected.
        expectRejected("renamed copy of an authorized executable") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: renamed.path))
        }
    }

    // MARK: - 6. Symlink identity

    @Test @MainActor
    func symlinkToAuthorizedExecutableBindsCanonicalIdentity() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zia-link-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link_to_echo")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/echo")

        let authorized = try ProcessAuthority.shared.authorize(.structured(executable: link.path))
        // Authority binds to the canonical target, not the link path.
        #expect(authorized.executablePath == ProcessAuthority.canonicalPath(for: "/bin/echo"))
        #expect(authorized.executablePath != link.path)
    }

    @Test @MainActor
    func symlinkToUnknownExecutableIsRejected() throws {
        let payload = try makeTempExecutable(named: "zia_link_target")
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        let link = payload.deletingLastPathComponent().appendingPathComponent("zia_link_to_payload")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: payload.path)
        expectRejected("symlink to an unknown executable") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: link.path))
        }
    }

    // MARK: - 7. Wrapper / trampoline executable

    @Test @MainActor
    func trampolineExecutableIsNotStructurallyAuthorized() {
        // `env`/`find`/`xargs` can launch another program, so they are not in the
        // structured allowlist even though they are trusted system binaries.
        for wrapper in ["env", "xargs", "nice", "nohup"] {
            expectRejected("trampoline executable '\(wrapper)'") {
                _ = try ProcessAuthority.shared.authorize(.structured(executable: wrapper))
            }
        }
    }

    // MARK: - 11. Working-directory policy

    @Test @MainActor
    func nonexistentWorkingDirectoryIsRejected() {
        expectRejected("nonexistent working directory") {
            _ = try ProcessAuthority.shared.authorize(
                .structured(executable: "/bin/echo", workingDirectory: "/zia-no-such-directory"))
        }
    }

    @Test @MainActor
    func existingWorkingDirectoryIsAuthorizedExactly() throws {
        let authorized = try ProcessAuthority.shared.authorize(
            .structured(executable: "/bin/echo", workingDirectory: NSTemporaryDirectory()))
        #expect(authorized.workingDirectory?.path ==
                URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
    }

    // MARK: - 12/26. Environment authority

    @Test @MainActor
    func structuredEnvironmentIsFixedAndCannotBeInjected() throws {
        let authorized = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo"))
        #expect(authorized.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(authorized.environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(authorized.environment["LD_PRELOAD"] == nil)
        #expect(authorized.environment["BASH_ENV"] == nil)
    }

    @Test @MainActor
    func shellEnvironmentUsesFixedPathAndDropsLoaderVariables() throws {
        let authorized = try ProcessAuthority.shared.authorize(.shell(command: "echo hi"))
        #expect(authorized.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(authorized.environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(authorized.environment["LD_PRELOAD"] == nil)
    }

    // MARK: - 10. PATH poisoning (shell capability)

    @Test @MainActor
    func shellPathPoisoningIsRejected() {
        expectRejected("PATH poisoning assignment") {
            _ = try ProcessAuthority.shared.authorize(.shell(command: "PATH=/tmp/evil:$PATH ls"))
        }
    }

    // MARK: - 13-19. Shell wrapper and interpreter escapes

    @Test @MainActor
    func shellInterpreterWrappersAreRejected() {
        let attacks = [
            "sh -c 'echo hi'",
            "bash -c 'echo hi'",
            "zsh -c 'echo hi'",
            "/bin/sh -c 'echo hi'",
            "env python -c 'print(1)'",
            "env python3 -c 'print(1)'",
            "nohup ruby -e 'puts 1'",
            "command node -e 'console.log(1)'"
        ]
        for attack in attacks {
            expectRejected("interpreter/wrapper escape '\(attack)'") {
                _ = try ProcessAuthority.shared.authorize(.shell(command: attack))
            }
        }
    }

    // MARK: - 18/19. Command and process substitution

    @Test @MainActor
    func commandAndProcessSubstitutionAreRejected() {
        let attacks = [
            "echo $(whoami)",
            "echo `whoami`",
            "cat <(echo hi)",
            "echo ${PATH}",
            "echo $'\\x41'"
        ]
        for attack in attacks {
            expectRejected("command generation '\(attack)'") {
                _ = try ProcessAuthority.shared.authorize(.shell(command: attack))
            }
        }
    }

    // MARK: - 20. Executable changed after authorization (TOCTOU)

    @Test @MainActor
    func authorizedSymlinkRepointedAfterAuthorizationCannotRedirectLaunch() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zia-toctou-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("payload")
        try "#!/bin/sh\necho zia_toctou_marker\n".write(to: payload, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path)

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/echo")

        // Authorize while the link points at an authorized binary.
        let authorized = try ProcessAuthority.shared.authorize(.structured(executable: link.path))
        let boundIdentity = authorized.executablePath

        // Repoint the link at the unknown payload AFTER authorization.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: payload.path)

        // The authorized URL is immutable and bound to the canonical target, so
        // launch still resolves to the originally authorized binary.
        #expect(authorized.executablePath == boundIdentity)
        #expect(authorized.executablePath == ProcessAuthority.canonicalPath(for: "/bin/echo"))

        // A fresh authorization on the same link now sees the payload and fails.
        expectRejected("repointed symlink re-authorization") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: link.path))
        }
    }

    // MARK: - 21/22. Recovery and deterministic execution cannot bypass authority

    @Test @MainActor
    func deterministicStructuredExecutionCannotIntroduceUnknownExecutable() async throws {
        let payload = try makeTempExecutable(named: "zia_deterministic_payload")
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        do {
            _ = try await ShellExecutor.shared.executeStructured(executable: payload.path)
            Issue.record("Structured executor accepted an unauthorized executable")
        } catch {
            // Rejected before any process was created — expected.
        }
    }

    @Test @MainActor
    func recoveryStyleProposalCannotGrantItselfAuthority() throws {
        // A recovery/replan path is just another proposal. It cannot authorize an
        // unknown executable merely by proposing it.
        let payload = try makeTempExecutable(named: "zia_recovery_payload")
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        expectRejected("recovery-proposed unknown executable") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: payload.path))
        }
    }

    // MARK: - 13/25/27. Authorization immutability and identity binding

    @Test @MainActor
    func authorizationIdentityBindsArgumentsAndExecutable() throws {
        let a = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo", arguments: ["one"]))
        let b = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo", arguments: ["two"]))
        let c = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/ls", arguments: ["one"]))
        #expect(a.identity != b.identity, "different arguments must produce different authorization identities")
        #expect(a.identity != c.identity, "different executables must produce different authorization identities")
        // The authorized argument vector is exactly what was authorized.
        #expect(a.arguments == ["one"])
    }

    @Test @MainActor
    func reauthorizationIsDeterministicForTheSameRequest() throws {
        let first = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo", arguments: ["same"]))
        let second = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo", arguments: ["same"]))
        #expect(first.identity == second.identity)
    }

    @Test @MainActor
    func revalidationAcceptsAGenuineAuthorizedRequest() throws {
        let authorized = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo"))
        try ProcessAuthority.shared.revalidateAtLaunch(authorized)
    }

    /// Directly attempts to mutate an authorized request via the caller's own
    /// value. `AuthorizedProcess` is a value type with `let` fields and a
    /// `fileprivate` initializer, so neither mutating the source array nor
    /// hand-constructing a changed request can alter what was authorized.
    @Test @MainActor
    func authorizedRequestIsImmutableAgainstCallerMutation() throws {
        var arguments = ["original"]
        let authorized = try ProcessAuthority.shared.authorize(
            .structured(executable: "/bin/echo", arguments: arguments))
        let identity = authorized.identity

        arguments.append("mutated")
        arguments[0] = "changed"

        // Mutating the caller's array cannot change what was authorized.
        #expect(authorized.arguments == ["original"])
        #expect(authorized.identity == identity)

        // The mutated arguments are a separate, re-authorizable decision.
        let other = try ProcessAuthority.shared.authorize(
            .structured(executable: "/bin/echo", arguments: arguments))
        #expect(other.identity != identity)
    }

    // MARK: - 23/24. Replay cannot transfer authority to a different action

    @Test @MainActor
    func shellAndStructuredCapabilitiesNeverConflate() throws {
        let structured = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo", arguments: ["x"]))
        let shell = try ProcessAuthority.shared.authorize(.shell(command: "echo x"))
        #expect(structured.capability == .structured)
        #expect(shell.capability == .shell)
        #expect(structured.executablePath != shell.executablePath,
                "a structured request must never degrade into the shell interpreter")
        #expect(structured.identity != shell.identity)
    }

    // MARK: - Executor: shell capability honors executable identity

    @Test @MainActor
    func shellExecutorRejectsAbsolutePathOutsideTrustedDirectories() async throws {
        let payload = try makeTempExecutable(named: "zia_shell_payload")
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        do {
            _ = try await ShellExecutor.shared.execute(payload.path)
            Issue.record("Shell executor launched an untrusted absolute path")
        } catch {
            // Rejected by ProcessAuthority before launch — expected.
        }
    }

    @Test @MainActor
    func shellExecutorRejectsRelativePathOutsideTrustedDirectories() async throws {
        do {
            _ = try await ShellExecutor.shared.execute("./zia_no_such_relative")
            Issue.record("Shell executor launched an untrusted relative path")
        } catch {
            // Expected.
        }
    }

    // MARK: - 9. Legitimate capability set still works end to end

    @Test @MainActor
    func ordinaryStructuredExecutionStillWorks() async throws {
        let output = try await ShellExecutor.shared.executeStructured(
            executable: "/bin/echo", arguments: ["structured_ok"])
        #expect(output.exitCode == 0)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "structured_ok")
        #expect(!output.authorizationIdentity.isEmpty)
    }

    @Test @MainActor
    func shellCapabilityStillExecutesOrdinaryCommands() async throws {
        let output = try await ShellExecutor.shared.execute("echo shell_ok")
        #expect(output.exitCode == 0)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "shell_ok")
    }

    // MARK: - Old-vs-new proof (Phase 10)

    /// Proves the exact limitation of the denylist boundary and the fix:
    /// an unknown executable in a user-writable directory is NOT classified as
    /// dangerous by the denylist, so the old boundary would have allowed it. The
    /// structured authority rejects it because it is not an authorized identity.
    @Test @MainActor
    func denylistDidNotClassifyUnknownExecutableButAuthorityRejectsIt() async throws {
        let payload = try makeTempExecutable(named: "zia_proof_payload")
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }

        // OLD boundary (denylist): nothing about this command matches a blocked
        // pattern or a dangerous program, so it was considered safe.
        #expect(CommandSandbox.shared.isSafe("\(payload.path) arg"),
                "denylist must not classify an unknown executable as dangerous (proving the old gap)")

        // NEW boundary (authority): rejected for both capabilities.
        expectRejected("structured authorization of an unknown executable") {
            _ = try ProcessAuthority.shared.authorize(.structured(executable: payload.path))
        }

        expectRejected("shell authorization of an unknown absolute-path executable") {
            _ = try ProcessAuthority.shared.authorize(.shell(command: payload.path))
        }
    }

    // MARK: - Deterministic capability through the authority pipeline

    @Test @MainActor
    func lineCountCapabilityRunsStructurallyAndVerifies() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zia-linecount-\(UUID().uuidString.prefix(8)).txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        guard let match = DeterministicRouter.shared.match("count the lines in \(file.path)") else {
            Issue.record("line-count capability did not match")
            return
        }
        #expect(match.intent == "file.lineCount")
        let result = try await match.action()
        #expect(result == "3 lines")
    }

    @Test @MainActor
    func lineCountCapabilityRejectsMissingFile() async throws {
        guard let match = DeterministicRouter.shared.match(
            "count the lines in /zia-definitely-missing-\(UUID().uuidString)") else {
            Issue.record("line-count capability did not match")
            return
        }
        do {
            _ = try await match.action()
            Issue.record("line-count capability reported a result for a missing file")
        } catch {
            // Expected: verified existence before running.
        }
    }

    @Test @MainActor
    func echoCapabilityRunsWithoutAShell() async throws {
        guard let match = DeterministicRouter.shared.match("echo hello structured") else {
            Issue.record("echo capability did not match")
            return
        }
        let result = try await match.action()
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello structured")
    }
}
