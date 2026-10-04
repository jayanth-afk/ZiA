import Foundation
import Testing
@testable import Jarvis

/// Security regression coverage for repository-content-to-code-execution.
///
/// A repository's own `.git/config` and `.gitattributes` can bind a file
/// attribute to an external program (clean/smudge filters, external diff,
/// textconv, fsmonitor). An otherwise "read-only" `git status`/`git diff` then
/// executes that program — repository content becoming authority. The authority
/// layer therefore authorizes worktree-reading git only in a repository whose
/// effective config cannot launch a program.
///
/// These tests use a harmless marker (`/bin/echo`) — no destructive payload is
/// ever run.
@Suite struct GitRepositoryInspectionGuardTests {

    // MARK: - Fixtures

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessAuthority.canonicalPath(for: "/usr/bin/git"))
        process.arguments = arguments
        process.environment = ProcessAuthority.gitConfigInspectionEnvironment()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments) failed in fixture setup")
    }

    /// A real, disposable repository. Not a repository is also a valid fail-closed
    /// input, but the filter/fsmonitor vectors need a genuine `.git/config`.
    private func makeRepository(hostile: Bool) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zia-repo-guard-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runGit(["-C", directory.path, "init", "-q", "."])
        try runGit(["-C", directory.path, "config", "user.email", "guard@zia.test"])
        try runGit(["-C", directory.path, "config", "user.name", "guard"])
        if hostile {
            // A filter driver the repository itself defines: `git status`/`diff`
            // would execute this command while reading worktree content.
            try runGit(["-C", directory.path, "config", "filter.evil.clean", "/bin/echo FILTER_RAN; cat"])
            try runGit(["-C", directory.path, "config", "filter.evil.smudge", "/bin/echo FILTER_RAN; cat"])
            try runGit(["-C", directory.path, "config", "core.fsmonitor", "/bin/echo FSMON_RAN"])
            try "*.txt filter=evil\n".write(
                to: directory.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    @MainActor
    private func expectRejected(_ message: String, _ operation: @MainActor () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected rejection: \(message)")
        } catch {
            // Rejected by the authority layer — expected.
        }
    }

    // MARK: - Worktree-reading git in a hostile repository

    @Test @MainActor
    func hostileRepositoryConfigRejectsWorktreeReadingGit() throws {
        let repo = try makeRepository(hostile: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        // Precondition: the guard actually sees the hostile repository.
        #expect(!ProcessAuthority.repositoryInspectionIsInert(at: repo.path),
                "a repository with a self-defined filter driver must not be inert")

        for arguments in [["status", "--porcelain"], ["diff"], ["diff", "--stat"]] {
            expectRejected("worktree-reading git \(arguments) in a hostile repository") {
                _ = try ProcessAuthority.shared.authorize(.structured(
                    executable: "git", arguments: arguments, workingDirectory: repo.path))
            }
        }
    }

    @Test @MainActor
    func hostileRepositoryStillAllowsRefsOnlyGit() throws {
        let repo = try makeRepository(hostile: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        // Ref/object commands do not read worktree content through filters, so a
        // hostile repository config cannot make them execute a program.
        for arguments in [["rev-parse", "--abbrev-ref", "HEAD"], ["branch", "--show-current"], ["log", "--oneline"]] {
            let authorized = try ProcessAuthority.shared.authorize(.structured(
                executable: "git", arguments: arguments, workingDirectory: repo.path))
            #expect(authorized.arguments == arguments)
        }
    }

    @Test @MainActor
    func inertRepositoryAllowsWorktreeReadingGit() throws {
        let repo = try makeRepository(hostile: false)
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(ProcessAuthority.repositoryInspectionIsInert(at: repo.path))

        let authorized = try ProcessAuthority.shared.authorize(.structured(
            executable: "git", arguments: ["status", "--porcelain"], workingDirectory: repo.path))
        #expect(authorized.arguments == ["status", "--porcelain"])
    }

    @Test @MainActor
    func nonRepositoryFailsClosed() {
        #expect(!ProcessAuthority.repositoryInspectionIsInert(at: "/zia-no-such-repository-\(UUID().uuidString)"))
    }

    @Test @MainActor
    func revalidationReChecksTheRepositoryAtLaunch() throws {
        let repo = try makeRepository(hostile: false)
        defer { try? FileManager.default.removeItem(at: repo) }

        // Authorize while the repository is inert, then make it hostile before
        // launch. The launch-time re-check must refuse to launch.
        let authorized = try ProcessAuthority.shared.authorize(.structured(
            executable: "git", arguments: ["status", "--porcelain"], workingDirectory: repo.path))
        try runGit(["-C", repo.path, "config", "filter.evil.clean", "/bin/echo FILTER_RAN; cat"])

        expectRejected("launch-time revalidation with a now-hostile repository") {
            try ProcessAuthority.shared.revalidateAtLaunch(authorized)
        }
    }

    // MARK: - Config key classification

    @Test @MainActor
    func dangerousConfigKeysAreClassified() {
        let dangerous = [
            "filter.evil.clean", "filter.lfs.process", "core.fsmonitor", "core.pager",
            "diff.external", "diff.custom.textconv", "diff.some.command",
            "log.showsignature", "gpg.program", "credential.helper", "core.hookspath"
        ]
        for key in dangerous {
            #expect(ProcessAuthority.isDangerousGitConfigKey(key), "\(key) must be treated as program-launching")
        }
        let benign = ["core.repositoryformatversion", "core.bare", "user.email", "remote.origin.url", "branch.master.merge"]
        for key in benign {
            #expect(!ProcessAuthority.isDangerousGitConfigKey(key), "\(key) must remain inert")
        }
    }

    // MARK: - Timeout bounding

    @Test @MainActor
    func timeoutsAreBounded() {
        for seconds in [0.0, -1.0, Double.nan, Double.infinity, ProcessAuthority.maximumTimeoutSeconds + 1] {
            expectRejected("timeout \(seconds)") {
                _ = try ProcessAuthority.shared.authorize(.structured(executable: "/bin/echo", timeoutSeconds: seconds))
            }
        }
        let authorized = try? ProcessAuthority.shared.authorize(
            .structured(executable: "/bin/echo", timeoutSeconds: ProcessAuthority.maximumTimeoutSeconds))
        #expect(authorized?.timeoutSeconds == ProcessAuthority.maximumTimeoutSeconds)
    }

    // MARK: - Authority-owned git environment

    @Test @MainActor
    func internalGitEnvironmentNeutralizesAmbientConfig() {
        // Fixed-executable internal git launches (development history) must not
        // inherit a repository-global log.showSignature + gpg.program pair.
        let environment = ProcessAuthority.gitProcessEnvironment()
        #expect(environment["GIT_CONFIG_KEY_0"] == "log.showSignature")
        #expect(environment["GIT_CONFIG_VALUE_0"] == "false")
        #expect(environment["GIT_CONFIG_NOSYSTEM"] == "1")
        // Enumeration must NOT include the overrides, or the guard would see its
        // own neutralization keys as repository-dangerous config.
        #expect(ProcessAuthority.gitConfigInspectionEnvironment()["GIT_CONFIG_COUNT"] == nil)
    }

    @Test @MainActor
    func structuredEnvironmentNeutralizesGitConfigSources() throws {
        let authorized = try ProcessAuthority.shared.authorize(.structured(executable: "git", arguments: ["log", "--oneline"]))
        #expect(authorized.environment["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(authorized.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(authorized.environment["GIT_CONFIG_SYSTEM"] == "/dev/null")
        #expect(authorized.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(authorized.environment["GIT_CONFIG_COUNT"] == "3")
    }
}
