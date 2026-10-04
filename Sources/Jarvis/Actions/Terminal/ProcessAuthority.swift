import Foundation
import CryptoKit

/// Errors raised by the execution-authority layer. Every one of these means the
/// request never reached a process primitive.
enum ProcessAuthorityError: LocalizedError {
    case emptyExecutable
    case unknownExecutable(String)
    case unauthorizedExecutable(String)
    case rejectedExecutablePath(String)
    case invalidArgument(String)
    case invalidWorkingDirectory(String)
    case interpreterRequiresShellCapability(String)
    case unauthorizedArguments(String, [String])
    case executableChangedAfterAuthorization(String)
    case invalidTimeout(Double)
    case unsafeRepositoryConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .emptyExecutable:
            return "Process request has an empty executable"
        case .unknownExecutable(let name):
            return "Executable '\(name)' could not be resolved in a trusted directory"
        case .unauthorizedExecutable(let path):
            return "Executable '\(path)' is not authorized for structured execution"
        case .rejectedExecutablePath(let token):
            return "Executable path '\(token)' is outside the trusted executable directories"
        case .invalidArgument(let reason):
            return "Process argument rejected: \(reason)"
        case .invalidWorkingDirectory(let path):
            return "Working directory '\(path)' is not an existing directory"
        case .interpreterRequiresShellCapability(let name):
            return "Program '\(name)' is a shell interpreter and requires the explicit shell capability"
        case .unauthorizedArguments(let path, let args):
            return "Arguments \(args) are not an authorized shape for '\(path)'"
        case .executableChangedAfterAuthorization(let path):
            return "Authorized executable '\(path)' changed between authorization and launch"
        case .invalidTimeout(let seconds):
            return "Process timeout \(seconds)s is outside the authorized range (0, \(ProcessAuthority.maximumTimeoutSeconds)]"
        case .unsafeRepositoryConfiguration(let reason):
            return "Repository configuration is not inert for a worktree-reading git command: \(reason)"
        }
    }
}

/// A process request PROPOSED by intelligence (planner, deterministic router,
/// recovery, or a direct internal caller).
///
/// Constructing a proposal grants NOTHING. It is a description of what the
/// caller wants to run. Only `ProcessAuthority` can turn a proposal into an
/// `AuthorizedProcess`, and only an `AuthorizedProcess` reaches the process
/// primitive. This is the structural separation of proposal from authority.
///
/// A structured proposal carries an executable plus an argument vector — there
/// is no shell string to interpret, so the authority layer never has to answer
/// the ambiguous question "is this arbitrary string safe?". Shell interpretation
/// is a *separate* capability that must be requested explicitly.
struct ProposedProcess: Sendable {
    enum Capability: Sendable, Equatable {
        /// Launch one specific executable with an explicit argument vector.
        /// Nothing in the request is re-interpreted by a shell.
        case structured
        /// Interpret a shell command line. Shell interpretation is a distinct,
        /// explicitly-granted capability.
        case shell
    }

    let capability: Capability
    /// `.structured`: the requested executable (bare name or path).
    /// `.shell`: the requested shell command line.
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let timeoutSeconds: Double
    let requestedImpact: PermissionGate.ActionImpact

    static func structured(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        timeoutSeconds: Double = 30.0,
        requestedImpact: PermissionGate.ActionImpact = .readOnly
    ) -> ProposedProcess {
        ProposedProcess(capability: .structured, executable: executable,
                        arguments: arguments, workingDirectory: workingDirectory,
                        timeoutSeconds: timeoutSeconds, requestedImpact: requestedImpact)
    }

    static func shell(
        command: String,
        timeoutSeconds: Double = 30.0,
        requestedImpact: PermissionGate.ActionImpact = .destructive
    ) -> ProposedProcess {
        ProposedProcess(capability: .shell, executable: command, arguments: [],
                        workingDirectory: nil, timeoutSeconds: timeoutSeconds,
                        requestedImpact: requestedImpact)
    }
}

/// An AUTHORIZED process request. This is the ONLY representation the executor
/// accepts.
///
/// Immutability is structural, not conventional: every field is `let`, and the
/// initializer is `fileprivate`, so only `ProcessAuthority` (the same file) can
/// mint one. No planner, replanner, task worker, recovery path, tool argument,
/// or mutable shared state can alter the executable, argument vector,
/// environment, working directory, timeout, or impact after authorization —
/// changing any of them requires a fresh authorization decision.
struct AuthorizedProcess: Sendable {
    let capability: ProposedProcess.Capability
    /// Canonical, symlink-resolved, absolute executable URL.
    let executableURL: URL
    let arguments: [String]
    /// The explicit environment the process runs with (never the raw ambient
    /// environment for structured execution).
    let environment: [String: String]
    let workingDirectory: URL?
    let timeoutSeconds: Double
    let impact: PermissionGate.ActionImpact
    /// Deterministic identity of exactly what was authorized. Evidence binds to
    /// this, never to a later re-read of mutable caller input.
    let identity: String

    fileprivate init(
        capability: ProposedProcess.Capability,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeoutSeconds: Double,
        impact: PermissionGate.ActionImpact
    ) {
        self.capability = capability
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.impact = impact
        self.identity = Self.computeIdentity(
            capability: capability,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            impact: impact)
    }

    /// Canonical executable path (convenience; equals `executableURL.path`).
    var executablePath: String { executableURL.path }

    private static func computeIdentity(
        capability: ProposedProcess.Capability,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeoutSeconds: Double,
        impact: PermissionGate.ActionImpact
    ) -> String {
        var canonical = ""
        // Length-prefixed framing prevents field-boundary ambiguity (e.g. an
        // argument that happens to contain the delimiter).
        func frame(_ value: String) {
            canonical += "\(value.utf8.count):\(value)"
        }
        frame(capability == .shell ? "shell" : "structured")
        frame(executableURL.path)
        for argument in arguments { frame("arg=\(argument)") }
        for key in environment.keys.sorted() { frame("env=\(key)=\(environment[key] ?? "")") }
        frame("cwd=\(workingDirectory?.path ?? "")")
        frame("timeout=\(timeoutSeconds)")
        frame("impact=\(impact)")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The execution authority.
///
/// Invariant: **unknown executable ≠ authorized executable.** A path is
/// authorized only if its canonical (symlink-resolved) form is explicitly
/// listed inside a root-owned, system-protected directory. The absence of a
/// path from a denylist never grants authority; the presence of a path in the
/// allowlist is the *only* thing that does.
///
/// This class is deliberately NOT the only line of defense. PermissionGate,
/// impact levels, destructive-action confirmation, CommandSandbox (as shell
/// syntax defense-in-depth), execution-boundary validation, cancellation,
/// process-group cleanup, and verification/evidence all remain in force. The
/// authority layer *adds* the missing structural boundary: it decides executable
/// identity, environment, and working directory before a process exists.
@MainActor
final class ProcessAuthority {
    static let shared = ProcessAuthority()

    private init() {}

    // MARK: - Trusted executable identity

    /// Root-owned, system-protected directories. User-writable locations
    /// (`/usr/local/bin`, `/opt/homebrew/bin`, `/tmp`, the home directory) are
    /// deliberately excluded: authority must not depend on a directory an
    /// unprivileged process can write to.
    static let trustedExecutableDirectories: [String] = ["/bin", "/usr/bin", "/sbin", "/usr/sbin"]

    /// Explicit allowlist of executables Zia may launch *structurally*, named by
    /// canonical path. Only leaf programs that cannot themselves launch another
    /// program appear here (no `env`/`find`/`xargs`/`sort`/interpreters), so a
    /// structured request cannot be a trampoline. Comparisons are canonicalized
    /// at first use so a symlinked trusted directory resolves consistently.
    private static let rawAuthorizedExecutables: [String] = [
        "/bin/echo", "/bin/ls", "/bin/cat", "/bin/pwd",
        "/usr/bin/date", "/usr/bin/wc", "/usr/bin/head", "/usr/bin/tail",
        "/usr/bin/grep", "/usr/bin/stat", "/usr/bin/which", "/usr/bin/diff",
        "/usr/bin/uniq", "/usr/bin/mdfind"
    ]

    static let authorizedExecutables: Set<String> = Set(
        rawAuthorizedExecutables.map { canonicalPath(for: $0) })

    private static let trustedCanonicalDirectories: [String] =
        trustedExecutableDirectories.map { canonicalPath(for: $0) }

    /// The shell interpreter used by the explicitly-granted shell capability.
    static let shellInterpreterPath = canonicalPath(for: "/bin/zsh")

    /// Upper bound on any authorized process lifetime. A caller cannot request
    /// an unbounded (or negative/NaN) timeout: timeout is part of the authorized
    /// request, so it is validated and bounded here rather than trusted.
    nonisolated static let maximumTimeoutSeconds: Double = 600

    nonisolated static func canonicalPath(for path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Fixed search order used ONLY to resolve a bare executable name to a
    /// canonical path so it can be checked against the allowlist. This is
    /// deliberately NOT the ambient `PATH`: the caller's environment can never
    /// influence which binary a structured request resolves to.
    private static let fixedSearchDirectories: [String] = ["/bin", "/usr/bin", "/sbin", "/usr/sbin"]

    // MARK: - Public API

    /// Turn a proposal into an authorized request, or reject it.
    func authorize(_ proposal: ProposedProcess) throws -> AuthorizedProcess {
        switch proposal.capability {
        case .structured:
            return try authorizeStructured(proposal)
        case .shell:
            return try authorizeShell(proposal)
        }
    }

    /// Re-verify an authorized request immediately before the process is
    /// created. Closes the "authorize → executable replaced → launch" window to
    /// a bounded re-check at the final choke point, and re-runs the shell syntax
    /// defense for the shell capability.
    func revalidateAtLaunch(_ authorized: AuthorizedProcess) throws {
        let fresh = Self.canonicalPath(for: authorized.executableURL.path)
        guard fresh == authorized.executableURL.path else {
            throw ProcessAuthorityError.executableChangedAfterAuthorization(authorized.executableURL.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fresh, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: fresh) else {
            throw ProcessAuthorityError.executableChangedAfterAuthorization(fresh)
        }
        switch authorized.capability {
        case .structured:
            guard Self.isWithinTrustedDirectories(fresh), Self.isStructuredProgram(fresh) else {
                throw ProcessAuthorityError.unauthorizedExecutable(fresh)
            }
            if let policy = Self.restrictedArgumentPolicy(for: fresh) {
                guard policy(authorized.arguments) else {
                    throw ProcessAuthorityError.unauthorizedArguments(fresh, authorized.arguments)
                }
            }
            try Self.validateTimeout(authorized.timeoutSeconds)
            try Self.assertRepositoryInspectionIsSafeIfNeeded(
                canonical: fresh, arguments: authorized.arguments, directory: authorized.workingDirectory)
        case .shell:
            guard fresh == Self.shellInterpreterPath else {
                throw ProcessAuthorityError.executableChangedAfterAuthorization(fresh)
            }
            // authorized.arguments is immutable, so this re-checks the *same*
            // command that was authorized — defense in depth, not re-authority.
            // The shape is fixed by the authority: `zsh -f -c <command>`.
            if authorized.arguments.count == 3,
               authorized.arguments[0] == "-f", authorized.arguments[1] == "-c" {
                try CommandSandbox.shared.validateCommand(authorized.arguments[2])
            }
        }
    }

    // MARK: - Structured authorization

    private func authorizeStructured(_ proposal: ProposedProcess) throws -> AuthorizedProcess {
        let resolved = try resolveExecutable(proposal.executable)
        let canonical = Self.canonicalPath(for: resolved.path)

        guard Self.isWithinTrustedDirectories(canonical) else {
            throw ProcessAuthorityError.rejectedExecutablePath(canonical)
        }
        guard !Self.shellInterpreters.contains(canonical) else {
            throw ProcessAuthorityError.interpreterRequiresShellCapability(canonical)
        }
        // A program is structurally authorized either as an unrestricted leaf
        // program or under an explicit, pinned ARGUMENT policy (e.g. read-only
        // git). An executable outside both is never authorized.
        guard Self.isStructuredProgram(canonical) else {
            throw ProcessAuthorityError.unauthorizedExecutable(canonical)
        }
        if let policy = Self.restrictedArgumentPolicy(for: canonical) {
            guard policy(proposal.arguments) else {
                throw ProcessAuthorityError.unauthorizedArguments(canonical, proposal.arguments)
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: canonical) else {
            throw ProcessAuthorityError.unauthorizedExecutable(canonical)
        }
        try Self.validateArguments(proposal.arguments)
        try Self.validateTimeout(proposal.timeoutSeconds)

        let workingDirectory = try Self.resolveWorkingDirectory(proposal.workingDirectory)
        try Self.assertRepositoryInspectionIsSafeIfNeeded(
            canonical: canonical, arguments: proposal.arguments, directory: workingDirectory)

        return AuthorizedProcess(
            capability: .structured,
            executableURL: URL(fileURLWithPath: canonical),
            arguments: proposal.arguments,
            environment: Self.minimalEnvironment(),
            workingDirectory: workingDirectory,
            timeoutSeconds: proposal.timeoutSeconds,
            impact: proposal.requestedImpact)
    }

    // MARK: - Shell authorization (separate capability)

    private func authorizeShell(_ proposal: ProposedProcess) throws -> AuthorizedProcess {
        let command = proposal.executable
        try Self.validateTimeout(proposal.timeoutSeconds)
        // Legacy syntax defense remains in force (denylist + program analysis +
        // protected-target + exfiltration heuristics). It is defense in depth:
        // the authority decision here is that the caller explicitly requested
        // the shell capability.
        try CommandSandbox.shared.validateCommand(command)

        // Bind executable identity for path-like program tokens: an absolute or
        // relative path outside the trusted directories can never be launched,
        // even through the shell (`/tmp/payload`, `./payload`, `~/x`), while
        // bare names continue to resolve through the shell's fixed PATH.
        for token in CommandSandbox.shared.launchedExecutableTokens(in: command)
        where token.contains("/") {
            let canonical = Self.canonicalPath(for: token)
            guard Self.isWithinTrustedDirectories(canonical) else {
                throw ProcessAuthorityError.rejectedExecutablePath(token)
            }
        }

        let interpreter = Self.shellInterpreterPath
        guard Self.isWithinTrustedDirectories(interpreter),
              FileManager.default.isExecutableFile(atPath: interpreter) else {
            throw ProcessAuthorityError.unauthorizedExecutable(interpreter)
        }

        // `-f` disables ALL shell startup files (`.zshenv`, `/etc/zshrc`, …).
        // Without it, non-interactive `zsh -c` sources the user's `.zshenv`
        // before running the command — arbitrary code that the CommandSandbox
        // never analyzed. The shell capability is privileged, but command
        // analysis must not be bypassed by ambient shell configuration.
        return AuthorizedProcess(
            capability: .shell,
            executableURL: URL(fileURLWithPath: interpreter),
            arguments: ["-f", "-c", command],
            environment: Self.shellEnvironment(),
            workingDirectory: nil,
            timeoutSeconds: proposal.timeoutSeconds,
            impact: proposal.requestedImpact)
    }

    // MARK: - Executable resolution

    private static let shellInterpreters: Set<String> = Set(
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/ksh", "/bin/tcsh"]
            .map { canonicalPath(for: $0) })

    private func resolveExecutable(_ requested: String) throws -> URL {
        guard !requested.isEmpty else { throw ProcessAuthorityError.emptyExecutable }
        guard !requested.contains("\n"), !requested.contains("\0") else {
            throw ProcessAuthorityError.invalidArgument("executable contains control characters")
        }

        if requested.contains("/") {
            // Explicit path (absolute or relative). Authority still binds to the
            // canonical resolved path — a relative token is resolved against the
            // current directory purely to obtain that identity.
            return URL(fileURLWithPath: requested)
        }

        // Bare name: fixed trusted-directory search, NEVER ambient PATH.
        for directory in Self.fixedSearchDirectories {
            let candidate = "\(directory)/\(requested)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw ProcessAuthorityError.unknownExecutable(requested)
    }

    /// Whether a canonical executable may be launched structurally at all: an
    /// unrestricted allowlisted leaf program, or a program with an explicit
    /// argument policy.
    private static func isStructuredProgram(_ canonicalPath: String) -> Bool {
        authorizedExecutables.contains(canonicalPath)
            || restrictedProgramPolicies[canonicalPath] != nil
    }

    /// Programs authorized ONLY for a pinned set of argument shapes. `git` can
    /// launch other programs (`-c`, `--exec-path`, aliases, external diff), so
    /// it is never an unrestricted structured program; these read-only shapes
    /// cannot launch anything.
    private static let restrictedProgramPolicies: [String: @Sendable ([String]) -> Bool] = [
        canonicalPath(for: "/usr/bin/git"): { isReadOnlyGitInvocation($0) }
    ]

    private static func restrictedArgumentPolicy(for canonicalPath: String) -> (([String]) -> Bool)? {
        restrictedProgramPolicies[canonicalPath]
    }

    /// Deterministic, pinned read-only `git` argument shapes. Anything not
    /// listed (writes, config overrides, pager/exec options, subcommands that
    /// launch programs) is rejected — this is an allowlist of argv, not a
    /// denylist of flags.
    nonisolated static func isReadOnlyGitInvocation(_ arguments: [String]) -> Bool {
        guard let subcommand = arguments.first else { return false }
        switch subcommand {
        case "status":
            let flags: Set<String> = ["--porcelain", "--short", "--branch", "-b", "-s"]
            return arguments.dropFirst().allSatisfy { flags.contains($0) }
        case "rev-parse":
            return arguments == ["rev-parse", "--abbrev-ref", "HEAD"]
                || arguments == ["rev-parse", "HEAD"]
                || arguments == ["rev-parse", "--show-toplevel"]
        case "branch":
            return arguments == ["branch"] || arguments == ["branch", "--show-current"]
        case "log":
            if arguments == ["log", "--oneline"] { return true }
            if arguments.count == 4, arguments[1] == "--oneline", arguments[2] == "-n",
               let count = Int(arguments[3]), count > 0, count <= 100 { return true }
            return false
        case "diff":
            return arguments == ["diff"] || arguments == ["diff", "--stat"]
                || arguments == ["diff", "--name-only"]
        default:
            return false
        }
    }

    private static func isWithinTrustedDirectories(_ canonicalPath: String) -> Bool {
        trustedCanonicalDirectories.contains { directory in
            canonicalPath.hasPrefix(directory + "/")
        }
    }

    private static func validateArguments(_ arguments: [String]) throws {
        for argument in arguments {
            if argument.contains("\0") {
                throw ProcessAuthorityError.invalidArgument("argument contains a NUL byte")
            }
        }
    }

    private static func validateTimeout(_ seconds: Double) throws {
        guard seconds.isFinite, seconds > 0, seconds <= maximumTimeoutSeconds else {
            throw ProcessAuthorityError.invalidTimeout(seconds)
        }
    }

    // MARK: - Worktree-reading git defense

    /// git subcommands that read the WORKTREE (not just refs/objects). These can
    /// run programs named by the repository's own `.git/config` and
    /// `.gitattributes` — clean/smudge filters, external diff drivers, textconv,
    /// fsmonitor. Repository content is DATA, not authority, so a worktree-reading
    /// git invocation is authorized only when the repository's effective config
    /// defines none of those program-launching keys.
    static let worktreeReadingGitSubcommands: Set<String> = ["status", "diff"]

    /// Config key prefixes that can name an external program. `filter.<driver>.*`
    /// and `diff.<driver>.textconv`/`diff.<driver>.command` are how git binds a
    /// file attribute to a program, so their presence anywhere in the effective
    /// config makes a worktree read unsafe. Exact keys cover fsmonitor, pager,
    /// editor, hooks, signature verification, and credential/ssh helpers.
    nonisolated private static let dangerousGitConfigPrefixes = ["filter.", "pager."]
    nonisolated private static let dangerousGitConfigKeys: Set<String> = [
        "core.fsmonitor", "core.pager", "core.editor", "core.hookspath",
        "core.sshcommand", "core.gitproxy", "log.showsignature", "gpg.program",
        "credential.helper", "sequence.editor", "core.alternateRefsCommand".lowercased()
    ]

    nonisolated static func isDangerousGitConfigKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if dangerousGitConfigKeys.contains(lower) { return true }
        if dangerousGitConfigPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower == "diff.external" { return true }
        if lower.hasPrefix("diff.") && (lower.hasSuffix(".textconv") || lower.hasSuffix(".command")) {
            return true
        }
        return false
    }

    /// Whether the repository reachable from `directory` (or Zia's own cwd when
    /// nil) has an inert config for a worktree-reading git command. Fails CLOSED:
    /// an unreadable/non-repository directory is treated as unsafe. The check
    /// neutralizes system/global config the same way real structured execution
    /// does, so it reasons about exactly the config git will actually read.
    nonisolated static func repositoryInspectionIsInert(at directory: String?) -> Bool {
        let workingDirectory = directory ?? FileManager.default.currentDirectoryPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: canonicalPath(for: "/usr/bin/git"))
        process.arguments = ["-C", workingDirectory, "config", "--list", "--includes", "--name-only", "-z"]
        process.environment = gitConfigInspectionEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let keys = String(decoding: data, as: UTF8.self).split(separator: "\0")
        return !keys.contains { isDangerousGitConfigKey(String($0)) }
    }

    /// The environment used to enumerate a repository's effective config: system
    /// and global config are neutralized (they are also neutralized for real
    /// structured execution), so only the repository's own local/worktree config
    /// is inspected. It deliberately omits the config overrides below so the
    /// enumeration does not report the authority's own neutralization keys as if
    /// they were repository-dangerous config.
    nonisolated static func gitConfigInspectionEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "GIT_OPTIONAL_LOCKS": "0"
        ]
    }

    /// Highest-precedence config overrides so no repository/global config can
    /// re-enable signature verification, the fsmonitor daemon, or an external
    /// pager for an authority-launched git process.
    nonisolated static let gitConfigOverrides: [String: String] = [
        "GIT_CONFIG_COUNT": "3",
        "GIT_CONFIG_KEY_0": "log.showSignature",
        "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "core.fsmonitor",
        "GIT_CONFIG_VALUE_1": "false",
        "GIT_CONFIG_KEY_2": "core.pager",
        "GIT_CONFIG_VALUE_2": "cat"
    ]

    /// The neutralized environment for an internal, fixed-executable git launch
    /// (e.g. development history). Ref/object-only commands carry the same
    /// ambient-config exposure as structured git, so they use the same
    /// authority-owned environment rather than inheriting Zia's.
    nonisolated static func gitProcessEnvironment() -> [String: String] {
        gitConfigInspectionEnvironment().merging(gitConfigOverrides) { _, new in new }
    }

    private static func resolveWorkingDirectory(_ requested: String?) throws -> URL? {
        guard let requested, !requested.isEmpty else { return nil }
        guard !requested.contains("\0") else {
            throw ProcessAuthorityError.invalidWorkingDirectory(requested)
        }
        let url = URL(fileURLWithPath: requested).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProcessAuthorityError.invalidWorkingDirectory(requested)
        }
        return url
    }

    // MARK: - Environment policy (Phase 6)

    /// Structured execution gets a fixed, minimal environment. The ambient
    /// environment is NOT inherited: a poisoned `DYLD_INSERT_LIBRARIES`,
    /// `PATH`, or similar variable in Zia's own process must not be able to turn
    /// an authorized leaf binary into a trampoline.
    ///
    /// A fixed set of git variables is included for every structured program.
    /// Non-git programs ignore them; git programs get system/global config and
    /// program-launching defaults neutralized, so the working directory's
    /// repository is the only config that reaches the process. These are
    /// authority-owned and cannot be supplied by the caller.
    private static func minimalEnvironment() -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "none"
        ]
        // Env-level config overrides have the highest precedence: no repository
        // config can re-enable signature verification, the fsmonitor daemon, or
        // an external pager for a structured git run.
        environment.merge(gitConfigOverrides) { _, new in new }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            environment["HOME"] = home
        }
        environment["LANG"] = "en_US.UTF-8"
        return environment
    }

    /// A worktree-reading git command is authorized only in a repository whose
    /// effective config cannot launch a program. `status`/`diff` read file
    /// content through clean filters, external diff drivers, textconv, and the
    /// fsmonitor hook — all of which are named by the repository itself. This is
    /// the boundary that keeps repository content DATA rather than authority.
    private static func assertRepositoryInspectionIsSafeIfNeeded(
        canonical: String,
        arguments: [String],
        directory: URL?
    ) throws {
        guard canonical == canonicalPath(for: "/usr/bin/git"),
              let subcommand = arguments.first,
              worktreeReadingGitSubcommands.contains(subcommand) else { return }
        guard repositoryInspectionIsInert(at: directory?.path) else {
            throw ProcessAuthorityError.unsafeRepositoryConfiguration(subcommand)
        }
    }

    /// Shell execution inherits a *sanitized* environment: the ambient values
    /// minus every variable that redirects program loading or resolution, and
    /// with a fixed PATH. The shell capability is broad by design, but ambient
    /// executable-resolution redirection is still removed.
    private static func shellEnvironment() -> [String: String] {
        let ambient = ProcessInfo.processInfo.environment
        let passthroughKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"]
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // Non-interactive shell: no prompts, no pager/terminal games.
            "TERM": "dumb",
            "SHELL": "/bin/zsh"
        ]
        for key in passthroughKeys {
            if let value = ambient[key] { environment[key] = value }
        }
        return environment
    }
}
