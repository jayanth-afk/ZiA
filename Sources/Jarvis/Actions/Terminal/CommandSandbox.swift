import Foundation

/// Enforces security guardrails for shell command execution.
///
/// Layered defense (not a simple blacklist):
///   1. Exact-pattern blacklist (fast path, defense in depth)
///   2. Normalized rescan — strips quoting/substitution syntax before re-checking
///      (defeats r'm' -'r'f, $(echo rm) -rf, base64|sh chains, osascript injection)
///   2b. Command-generation rejection — command substitution, backtick/parameter/
///      ANSI-C expansion, process substitution, and `system(`/`popen(` could
///      synthesize a command layer 3 never sees, so they are rejected outright
///   3. Program analysis — EVERY program a pipeline/chain segment can launch is
///      checked against a dangerous-program list, unwrapping wrapper/trampoline
///      programs (env/nohup/xargs/nice/…) and `find -exec`, and rejecting
///      code-evaluation interpreters (python/node/ruby/swift/…), build/package
///      runners, interactive programs (vim/less/gdb/…), and remote-execution
///      launchers (ssh/scp/rsync/ftp/…) as the same class as the
///      already-blocked sh/bash/eval/osascript
///   4. Protected-target scan — destructive verbs aimed at protected paths
///      (/, /System, ~/.ssh, etc.) are always blocked
///   5. Exfiltration heuristics — local credential files piped/posted to network
///
/// The LLM never receives arbitrary shell access: every command passes through
/// this sandbox (validate at plan time, RE-VALIDATE at execute time — the
/// executor must never trust a pre-validated string).
@MainActor
final class CommandSandbox {
    static let shared = CommandSandbox()

    // MARK: - Layer 1: Exact blacklist (fast path)

    private let blockedPatterns: [String] = [
        "rm -rf /",
        "rm -rf ~",
        "rm -rf *",
        ":(){ :|:& };:",
        "mkfs",
        "dd if=",
        "sudo ",
        "chmod -R 777 /",
        "chown -R",
        "diskutil erase",
        "diskutil partition",
        "> /dev/sda",
        "> /dev/disk"
    ]

    // MARK: - Layer 3: Dangerous programs (checked per chain/pipeline segment)

    private let dangerousPrograms: Set<String> = [
        "rm", "sudo", "doas", "pkexec", "mkfs", "dd", "diskutil", "osascript",
        "sh", "bash", "zsh", "dash", "csh", "tcsh", "ksh",
        "eval", "exec", "source", "curl", "wget", "nc", "ncat", "telnet",
        "killall", "kill", "launchctl", "csrutil", "nvram", "pmset",
        "security", "defaults", "tccutil", "spctl", "xattr"
    ]

    /// General-purpose language runtimes that evaluate code supplied inline
    /// (`-c`/`-e`/`--eval`), as a module (`-m`), or from a script file. They
    /// grant the same arbitrary filesystem/process/network authority as the
    /// already-blocked `sh`/`bash`/`eval`/`exec`/`osascript`, so they are
    /// rejected by the same deterministic boundary. Zia has no production
    /// dependency on running interpreter code through `run_shell`, so the
    /// policy is fail-closed (whole-program rejection) rather than attempting
    /// to parse arbitrary languages.
    private let codeExecutionInterpreters: Set<String> = [
        "python", "python2", "python3", "pythonw",
        "perl", "ruby", "irb",
        "node", "nodejs", "deno", "bun",
        "php", "php7", "php8",
        "lua", "luajit", "tclsh", "wish",
        "rscript", "julia",
        "swift", "swiftc"
    ]

    /// Build / package / task runners whose whole function is to execute
    /// project- or package-controlled code (build files, install hooks,
    /// plugins). They are the same capability class as the interpreters above;
    /// the repository inventory shows Zia has no production or test usage of
    /// any of them, so they are rejected as unsupported execution capabilities.
    private let codeExecutionRunners: Set<String> = [
        "make", "gmake", "cmake", "ninja",
        "npm", "npx", "pnpm", "yarn", "bunx",
        "cargo", "go",
        "xcodebuild", "xcrun",
        "bazel", "gradle", "mvn", "ant",
        "rake", "bundle", "bundler", "gem",
        "pip", "pip3", "poetry", "conda",
        "brew", "docker", "podman", "fastlane"
    ]

    /// Interactive programs with a documented child-process escape: editors
    /// (`:!cmd`, `--eval`, `-c`), pagers (`!cmd`), `man` (`-P`, MANPAGER),
    /// debuggers (`shell`), and database CLIs (`.shell`/`system`). Zia runs
    /// `run_shell` non-interactively and has no production or test use of any
    /// of them, so they are the same execution-capability class as the
    /// interpreters and build runners.
    private let interactiveEscapePrograms: Set<String> = [
        "vim", "vi", "nvim", "ex", "ed", "emacs", "nano", "pico", "joe", "micro",
        "less", "more", "most", "pg",
        "man",
        "gdb", "lldb",
        "sqlite3", "mysql", "psql", "mongo", "mongosh", "redis-cli"
    ]

    /// Remote-execution / network-launcher programs. Each can launch another
    /// program (or ship data to an arbitrary host): `ssh [host] <command>` runs
    /// an arbitrary remote command and `ssh -o ProxyCommand=`/`LocalCommand` run
    /// a LOCAL one; `rsync -e`/`--rsh` runs an arbitrary local transport; `ftp`
    /// exposes a local `!command` escape; `scp`/`sftp`/`rcp` target arbitrary
    /// hosts. Zia has no production or test use of any of them, so they are the
    /// same execution-capability class as the interpreters and build runners.
    private let remoteExecutionPrograms: Set<String> = [
        "ssh", "scp", "sftp", "rsync", "rcp", "rlogin", "rexec", "ftp"
    ]

    /// Environment variables that redirect program loading or command
    /// resolution. Assigning one in command position can turn an allowed binary
    /// into a trampoline (e.g. `DYLD_INSERT_LIBRARIES=… ls`, `PATH=… ls`,
    /// `GIT_PAGER=… git log`), so those assignments are rejected.
    private let injectionVariables: Set<String> = [
        "PATH", "IFS", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS",
        "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
        "PYTHONSTARTUP", "NODE_OPTIONS", "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB",
        "PAGER", "LESSOPEN", "LESSCLOSE", "EDITOR", "VISUAL",
        "GIT_PAGER", "GIT_EDITOR", "GIT_SSH", "GIT_SSH_COMMAND",
        "GIT_EXTERNAL_DIFF", "GIT_SEQUENCE_EDITOR", "GIT_PROXY_COMMAND",
        // Pager/config redirection gaps: `man`'s pager and git's config source.
        "MANPAGER", "MORE",
        "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT",
        // tar reads extra options from the environment, including the
        // external-command options handled by tarExecutionRisk(of:).
        "TAR_OPTIONS"
    ]

    /// Environment-variable name prefixes that also redirect execution: git's
    /// `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` can define an arbitrary
    /// pager/alias program.
    private let injectionVariablePrefixes: [String] = ["GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"]

    /// Wrapper/trampoline programs that forward execution to a LATER program.
    /// A leading wrapper must never hide the real executable from layer 3
    /// (e.g. `env rm …`, `nohup rm …`, `xargs rm`, `nice -n 10 rm …`).
    private let wrapperPrograms: Set<String> = [
        "env", "nice", "nohup", "time", "stdbuf", "setsid", "command", "builtin", "xargs"
    ]

    /// Per-wrapper options that consume the FOLLOWING token as a value. The
    /// unwrapper skips leading option flags to find the launched program, so a
    /// non-numeric option value (e.g. `stdbuf -o L`, `xargs -I @`, `env -u FOO`)
    /// must also be skipped or it is mistaken for the program and hides the real
    /// executable (`stdbuf -o L sh -c …`, `xargs -I @ rm`). Kept per-wrapper so
    /// an option that is boolean for one wrapper (`env -i`) is not wrongly
    /// treated as value-taking. Attached forms (`-oL`, `--output=L`) are a single
    /// token and need no extra skip; options that only take numeric values are
    /// omitted (the numeric skip covers them).
    private let wrapperValueOptions: [String: Set<String>] = [
        "stdbuf": ["-i", "-o", "-e", "--input", "--output", "--error"],
        "env": ["-u", "-s", "-c", "--unset", "--split-string", "--chdir"],
        "nice": ["--adjustment"],
        "time": ["-f", "--format"],
        "xargs": [
            "-i", "-n", "-l", "-s", "-e", "-d", "-a",
            "--max-args", "--max-chars", "--max-lines", "--delimiter",
            "--arg-file", "--replace", "--eof"
        ]
    ]

    /// Flags that introduce a program launched by the current program
    /// (e.g. `find . -exec rm {} +`, `find . -execdir rm {} +`).
    private let execIntroducerFlags: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]

    /// Constructs that EXECUTE or SYNTHESIZE a command the layer-3 program
    /// analysis cannot see, so a denylist cannot reason about them:
    /// command substitution (`$(…)`, backticks), parameter/brace expansion
    /// (`${…}`), ANSI-C/locale quoting (`$'…'`, `$"…"`), process substitution
    /// (`<(…)`, `>(…)`), and inline code-execution primitives usable from text
    /// processors such as awk (`system(…)`, `popen(…)`, `"cmd" | getline`).
    /// These are invalid or unnecessary in Zia's legitimate `run_shell`
    /// commands (echo/pwd/cat/ls/git/sed/awk field access …), so they are
    /// rejected outright (fail-closed).
    private let unsafeShellConstructs: [String] = ["$(", "`", "${", "$'", "$\"", "<(", ">(", "system(", "popen(", "| getline", "|getline"]

    /// Read-only programs allowed to run unsupervised. Anything NOT in this set
    /// and NOT obviously benign is treated as requiring confirmation upstream.
    private let knownSafePrograms: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "find", "wc", "file", "stat",
        "pwd", "echo", "date", "whoami", "uname", "df", "du", "ps", "top",
        "which", "git", "sed", "awk", "sort",
        "uniq", "diff", "less", "open", "mdfind", "env", "printenv", "true", "false"
    ]

    // MARK: - Layer 4: Protected targets

    private let protectedPrefixes: [String] = [
        "/", "/system", "/library", "/etc", "/usr", "/bin", "/sbin", "/var",
        "/private", "/dev", "/volumes"
    ]

    private let protectedHomeSubpaths: [String] = [
        ".ssh", ".gnupg", ".aws", ".kube", ".config/gcloud",
        ".env", ".netrc", ".zsh_history", ".bash_history"
    ]

    // MARK: - Layer 5: Exfiltration verbs

    private let exfilVerbs: [String] = ["curl", "wget", "nc", "ncat", "scp", "rsync", "ssh", "ftp"]

    private init() {}

    // MARK: - Public API

    /// Validate a shell command string against all defense layers.
    /// Throws JarvisError.commandBlocked if any layer flags the command.
    func validateCommand(_ command: String) throws {
        let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !cleaned.isEmpty else {
            throw JarvisError.actionFailed(action: "executeCommand", reason: "Command is empty")
        }

        // Layer 1: exact blacklist
        for pattern in blockedPatterns where cleaned.contains(pattern) {
            JarvisLogger.security.fault("BLOCKED (layer 1 exact): '\(command)' contains '\(pattern)'")
            throw JarvisError.commandBlocked(command: command, reason: "Dangerous pattern '\(pattern)' is blacklisted")
        }

        // Layer 2: normalized rescan (strips quoting/substitution obfuscation)
        let normalized = normalize(cleaned)
        for pattern in blockedPatterns where normalized.contains(pattern) {
            JarvisLogger.security.fault("BLOCKED (layer 2 normalized): '\(command)' normalizes to '\(normalized)'")
            throw JarvisError.commandBlocked(command: command, reason: "Command obfuscates a blacklisted pattern")
        }

        // Layer 2b: reject shell command generation / inline code execution. A
        // denylist cannot see through command substitution, backtick/parameter/
        // ANSI-C expansion, process substitution, or `system(`/`popen(` — the
        // shell (or a text processor) runs a command that layer 3 never sees
        // (e.g. `echo hi$(rm file)`). Evaluated on the raw cleaned command so
        // the construct syntax is still intact.
        for construct in unsafeShellConstructs where cleaned.contains(construct) {
            JarvisLogger.security.fault("BLOCKED (layer 2b command generation): '\(command)' contains '\(construct)'")
            throw JarvisError.commandBlocked(command: command, reason: "Shell command generation '\(construct)' is not permitted")
        }

        // Layer 3: program analysis on every pipeline/chain segment. EVERY
        // program a segment can actually launch is checked, not merely its
        // leading token: wrapper/trampoline programs (`env`, `nohup`, `xargs`,
        // `command`, `nice`, …) and `find -exec`/`-execdir` actions forward
        // execution to another program, and that program is the one the
        // dangerous-program list must see.
        for segment in segments(of: normalized) {
            for program in executingPrograms(of: segment)
            where dangerousPrograms.contains(program)
                || codeExecutionInterpreters.contains(program)
                || codeExecutionRunners.contains(program)
                || interactiveEscapePrograms.contains(program)
                || remoteExecutionPrograms.contains(program) {
                JarvisLogger.security.fault("BLOCKED (layer 3 program): '\(command)' runs dangerous program '\(program)'")
                throw JarvisError.commandBlocked(command: command, reason: "Program '\(program)' is not permitted")
            }
            if let gitRisk = gitExecutionRisk(of: segment) {
                JarvisLogger.security.fault("BLOCKED (layer 3 git trampoline): '\(command)': \(gitRisk)")
                throw JarvisError.commandBlocked(command: command, reason: gitRisk)
            }
            if let tarRisk = tarExecutionRisk(of: segment) {
                JarvisLogger.security.fault("BLOCKED (layer 3 tar trampoline): '\(command)': \(tarRisk)")
                throw JarvisError.commandBlocked(command: command, reason: tarRisk)
            }
            if let sortRisk = sortExecutionRisk(of: segment) {
                JarvisLogger.security.fault("BLOCKED (layer 3 sort trampoline): '\(command)': \(sortRisk)")
                throw JarvisError.commandBlocked(command: command, reason: sortRisk)
            }
            if let injectionRisk = environmentInjectionRisk(of: segment) {
                JarvisLogger.security.fault("BLOCKED (layer 3 env injection): '\(command)': \(injectionRisk)")
                throw JarvisError.commandBlocked(command: command, reason: injectionRisk)
            }
        }

        // Layer 4: destructive verb aimed at a protected target
        if targetsProtectedPath(normalized) {
            JarvisLogger.security.fault("BLOCKED (layer 4 target): '\(command)' targets a protected path")
            throw JarvisError.commandBlocked(command: command, reason: "Command targets a protected system path")
        }

        // Layer 5: credential exfiltration heuristics
        if attemptsExfiltration(normalized) {
            JarvisLogger.security.fault("BLOCKED (layer 5 exfil): '\(command)' ships local files to a network program")
            throw JarvisError.commandBlocked(command: command, reason: "Possible credential/data exfiltration")
        }
    }

    /// Check if a command is safe without throwing.
    func isSafe(_ command: String) -> Bool {
        do {
            try validateCommand(command)
            return true
        } catch {
            return false
        }
    }

    /// Whether the command's programs are all known-safe (vs merely unblocked).
    func isFullyBenign(_ command: String) -> Bool {
        let normalized = normalize(command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let programs = segments(of: normalized).compactMap { executable(of: $0) }
        guard !programs.isEmpty else { return false }
        return programs.allSatisfy { knownSafePrograms.contains($0) }
    }

    // MARK: - Layer 2: Normalization

    /// Strip obfuscation syntax so the rescan sees through quoting tricks,
    /// command substitution, variable indirection, and encoded chains.
    private func normalize(_ command: String) -> String {
        var result = command

        // Repeatedly collapse quoting / backslash escapes / substitution wrappers
        var previous = ""
        var iterations = 0
        let wrappers = ["'", "\"", "`", "\\", "(", ")", "$", "{", "}"]
        while result != previous && iterations < 8 {
            previous = result
            for char in wrappers {
                result = result.replacingOccurrences(of: String(char), with: "")
            }
            // Collapse internal whitespace for pattern matching
            result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            iterations += 1
        }

        // Decode a leading base64 blob piped into a decoder (echo X | base64 -d | sh)
        if result.contains("base64") || result.contains("openssl") {
            for blob in extractPossibleBase64Blobs(in: result) {
                if let decoded = decodeBase64Safely(blob) {
                    result += " " + decoded.lowercased()
                }
            }
        }

        return result
    }

    private func extractPossibleBase64Blobs(in command: String) -> [String] {
        // Tokens of >= 8 chars consisting only of base64 alphabet
        let pattern = #"\b[A-Za-z0-9+/=]{8,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = command as NSString
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            let token = ns.substring(with: m.range)
            // Filter out ordinary words (must contain at least one non-alphabetic char typical of base64)
            return token.contains(where: { "+/=".contains($0) || ($0.isNumber && token.count > 10) }) ? token : nil
        }
    }

    private func decodeBase64Safely(_ blob: String) -> String? {
        guard let data = Data(base64Encoded: blob) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Layer 3 helpers

    /// Split a command into its pipeline/chain segments ("&&", "||", ";", "|", newline).
    private func segments(of command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var iterator = command.makeIterator()
        var previousChar: Character?

        while let char = iterator.next() {
            if char == "&" && previousChar == "&" {
                if !current.isEmpty { parts.append(current) }
                current = ""
                previousChar = nil
                continue
            }
            if char == "|" && previousChar == "|" {
                if !current.isEmpty { parts.append(current) }
                current = ""
                previousChar = nil
                continue
            }
            // A single `&` (job control) separates two commands exactly like
            // `;`/`|`. It must be segmented, or the program after it is never
            // program-checked (`echo hi & sh -c '…'`). `&&` is already handled
            // above, so this only sees the single-ampersand form.
            if char == ";" || char == "|" || char == "&" || char == "\n" {
                if !current.isEmpty { parts.append(current) }
                current = ""
                previousChar = char
                continue
            }
            current.append(char)
            previousChar = char
        }
        if !current.isEmpty { parts.append(current) }

        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Extract the leading executable of a segment (skipping env assignments).
    private func executable(of segment: String) -> String? {
        for token in segment.split(separator: " ").map(String.init) {
            if isEnvironmentAssignment(token) { continue }
            return executableName(of: token)
        }
        return nil
    }

    /// Every program a single segment can cause to execute.
    ///
    /// - The primary executable: the first token that is not an environment
    ///   assignment, an option flag, a numeric option value, or a wrapper
    ///   program. Wrappers (and their option/numeric arguments) are skipped so
    ///   `nice -n 10 rm …` resolves to `rm`, not `10`.
    /// - Any program introduced by an `-exec`/`-execdir`/`-ok` action.
    private func executingPrograms(of segment: String) -> [String] {
        let tokens = segment.split(separator: " ").map(String.init)
        var programs: [String] = []

        for index in programCandidateIndices(in: tokens) {
            programs.append(executableName(of: tokens[index]))
        }

        for (offset, token) in tokens.enumerated() where execIntroducerFlags.contains(token) {
            guard offset + 1 < tokens.count else { continue }
            let candidate = tokens[offset + 1]
            guard !candidate.hasPrefix("-") else { continue }
            programs.append(executableName(of: candidate))
        }

        return programs
    }

    /// Index of the token that is the segment's primary executable, applying
    /// the same environment-assignment / option / numeric / wrapper skipping
    /// used by `executingPrograms`.
    private func primaryExecutableIndex(in tokens: [String]) -> Int? {
        var index = 0
        var activeWrapper: String?
        var valueForOption = false
        while index < tokens.count {
            let token = tokens[index]
            if valueForOption {
                // Consume the value of a preceding value-taking wrapper option.
                valueForOption = false
                index += 1
                continue
            }
            if isEnvironmentAssignment(token) {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                if let wrapper = activeWrapper,
                   wrapperValueOptions[wrapper]?.contains(token) == true {
                    valueForOption = true
                }
                index += 1
                continue
            }
            if token.allSatisfy(\.isNumber) {
                index += 1
                continue
            }
            let name = executableName(of: token)
            if wrapperPrograms.contains(name) {
                activeWrapper = name
                index += 1
                continue
            }
            return index
        }
        return nil
    }

    /// Token indices that can name a program the segment launches, in order.
    /// Unlike `primaryExecutableIndex`, this ALSO yields the value of a
    /// value-taking wrapper option, because that value can itself be the
    /// launched program (`env -S 'sh -c …'`) or the placeholder preceding it
    /// (`xargs -i rm`, where `-i` may omit its argument). Fail-closed: a value
    /// that happens to name an execution program is rejected rather than guessed
    /// away.
    private func programCandidateIndices(in tokens: [String]) -> [Int] {
        var indices: [Int] = []
        var index = 0
        var activeWrapper: String?
        var isOptionValue = false
        while index < tokens.count {
            let token = tokens[index]
            if isOptionValue {
                indices.append(index)
                isOptionValue = false
                index += 1
                continue
            }
            if isEnvironmentAssignment(token) {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                if let wrapper = activeWrapper,
                   wrapperValueOptions[wrapper]?.contains(token) == true {
                    isOptionValue = true
                }
                index += 1
                continue
            }
            if token.allSatisfy(\.isNumber) {
                index += 1
                continue
            }
            let name = executableName(of: token)
            if wrapperPrograms.contains(name) {
                activeWrapper = name
                index += 1
                continue
            }
            indices.append(index)
            break
        }
        return indices
    }

    /// Deterministic recognition of `git` forms that LAUNCH another program.
    /// `git` itself stays allowed (`status`/`log`/`diff`/… are legitimate
    /// reads), but config overrides and the execution subcommands grant the same
    /// arbitrary-process authority as the already-blocked interpreters and are
    /// the missing piece of the layer-3 program analysis. Bounded and O(tokens):
    /// no language parsing, no process spawning.
    private func gitExecutionRisk(of segment: String) -> String? {
        let tokens = segment.split(separator: " ").map(String.init)
        guard let gitIndex = primaryExecutableIndex(in: tokens),
              executableName(of: tokens[gitIndex]) == "git",
              gitIndex + 1 < tokens.count else { return nil }
        let args = Array(tokens[(gitIndex + 1)...])

        // Global config overrides can define alias/pager/editor/fsmonitor/
        // sshCommand/credential.helper programs. Matched precisely: `--config*`
        // is always the global override, while a bare `-c` is a config override
        // only when followed by a `key=value` token — this avoids false
        // positives on subcommand flags that merely share the token
        // (e.g. `git diff -c`, `git show -c`, `git commit -c HEAD`).
        if args.contains(where: {
            $0 == "--config" || $0 == "--config-env"
                || $0.hasPrefix("--config=") || $0.hasPrefix("--config-env=")
        }) {
            return "git config override can launch an arbitrary program"
        }
        for (i, arg) in args.enumerated() where arg == "-c" {
            if i + 1 < args.count, !args[i + 1].hasPrefix("-"), args[i + 1].contains("=") {
                return "git config override can launch an arbitrary program"
            }
        }
        if args.contains(where: { $0 == "--exec" || $0.hasPrefix("--exec=") }) {
            return "git --exec runs a command"
        }
        if args.contains(where: { ["filter-branch", "filter-repo", "difftool", "mergetool"].contains($0) }) {
            return "git filter-branch/filter-repo/difftool/mergetool launches another program"
        }
        if let idx = args.firstIndex(of: "bisect"), args[(idx + 1)...].contains("run") {
            return "git bisect run executes a command"
        }
        if let idx = args.firstIndex(of: "submodule"), args[(idx + 1)...].contains("foreach") {
            return "git submodule foreach executes a command"
        }
        if let idx = args.firstIndex(of: "config") {
            let rest = Array(args[(idx + 1)...])
            let writeFlags = ["--add", "--unset", "--unset-all", "--replace-all",
                              "--rename-section", "--remove-section", "--edit"]
            if rest.contains(where: { writeFlags.contains($0) })
                || rest.filter({ !$0.hasPrefix("-") }).count >= 2 {
                return "git config write can persist an execution program"
            }
        }
        return nil
    }

    /// Rejects archive-tool options that launch an external program. bsdtar
    /// (`/usr/bin/tar`) spawns the program named by `--use-compress-program`/`-I`
    /// as a subprocess (observed: it attempts to run the supplied command), and
    /// GNU tar adds `--to-command`/`--to-program` (per-member program) and
    /// `--checkpoint-action=exec=…`. Each is the same arbitrary-process
    /// authority as the already-blocked interpreters. Scoped to `tar` so
    /// ordinary `-i`/`--to-*` flags on other tools are unaffected. O(tokens).
    private func tarExecutionRisk(of segment: String) -> String? {
        let tokens = segment.split(separator: " ").map(String.init)
        guard let tarIndex = primaryExecutableIndex(in: tokens),
              executableName(of: tokens[tarIndex]) == "tar",
              tarIndex + 1 < tokens.count else { return nil }
        for token in tokens[(tarIndex + 1)...] {
            // `-I` (normalized to lowercase `i`), an attached `-Iprog`, or a
            // bundled short-option cluster containing it (`-cIf`). macOS
            // bsdtar has no ordinary `-i` option, so any `i` in a single-dash
            // cluster means `-I` (fail-closed, scoped to tar).
            if token.count > 1, token.hasPrefix("-"), !token.hasPrefix("--"), token.contains("i") {
                return "tar -I/--use-compress-program launches an external program"
            }
            if token.hasPrefix("--use-compress") // covers abbreviations
                || token.hasPrefix("--to-command") || token.hasPrefix("--to-program")
                || token.hasPrefix("--checkpoint") {
                return "tar option launches an external program"
            }
        }
        return nil
    }

    /// Rejects `sort --compress-program[=]PROG`. GNU/BSD `sort` spawns PROG as a
    /// subprocess to (de)compress its input — the same arbitrary-process
    /// authority as tar's `--use-compress-program` and the blocked interpreters.
    /// Both the `--compress-program=PROG` and the space-separated
    /// `--compress-program PROG` forms are rejected; abbreviations are covered by
    /// the `--compress` prefix. Scoped to `sort` so the option name on any other
    /// tool is unaffected. O(tokens).
    private func sortExecutionRisk(of segment: String) -> String? {
        let tokens = segment.split(separator: " ").map(String.init)
        guard let sortIndex = primaryExecutableIndex(in: tokens),
              executableName(of: tokens[sortIndex]) == "sort" else { return nil }
        for token in tokens[(sortIndex + 1)...] where token.hasPrefix("--compress") {
            return "sort --compress-program launches an external program"
        }
        return nil
    }

    /// Rejects environment assignments in COMMAND POSITION that redirect
    /// program loading or command resolution. Only assignments before the
    /// primary executable are considered — `echo FOO=bar` keeps NAME=value as an
    /// ordinary argument and is not injection.
    private func environmentInjectionRisk(of segment: String) -> String? {
        let tokens = segment.split(separator: " ").map(String.init)
        let programIndex = primaryExecutableIndex(in: tokens) ?? tokens.count
        for token in tokens.prefix(programIndex) {
            guard let equals = token.firstIndex(of: "=") else { continue }
            let name = String(token[..<equals]).uppercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            if injectionVariables.contains(name)
                || injectionVariablePrefixes.contains(where: { name.hasPrefix($0) }) {
                return "environment variable \(name) can redirect program loading or execution"
            }
        }
        return nil
    }

    /// True for `NAME=value` environment assignments (leading letter or `_`).
    private func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter || first == "_" else { return false }
        return token.dropFirst().contains("=")
    }

    /// Shell control operators the shell acts on even when no whitespace
    /// separates them from a program name (`sh<<<'cmd'`, `sh</tmp/script`,
    /// `sh>out`). A program token is everything before the first of these.
    private static let programNameTerminators: Set<Character> = ["<", ">", "|", "&", ";", "`", "(", ")"]

    /// Program basename of a command token. Shell control operators glued to the
    /// program name are stripped FIRST — redirection/here-string syntax must not
    /// hide the program from the layer-3 program analysis (`sh<<<'cmd'` has to
    /// resolve to `sh`, not to the opaque `sh<<<'cmd'`) — then a leading path is
    /// removed.
    private func executableName(of token: String) -> String {
        var name = token
        if let terminator = name.firstIndex(where: { Self.programNameTerminators.contains($0) }) {
            name = String(name[..<terminator])
        }
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    // MARK: - Layer 4 helpers

    private func targetsProtectedPath(_ command: String) -> Bool {
        // Applies to ANY program: neither `rm` nor `cat` should touch protected
        // targets, and upward traversal is always treated as an escape attempt.
        for segment in segments(of: command) {
            let tokens = segment.split(separator: " ").map(String.init)

            for token in tokens.dropFirst() where token.contains("/") {
                let path = collapseDotDot(token)
                if protectedPrefixes.contains(path) { return true }
                if protectedPrefixes.contains(where: { path.hasPrefix($0 + "/") }) { return true }
                if path.hasPrefix("/dev/") { return true }
                // Path traversal that escapes upward past the working directory
                if token.contains("../") || token.hasPrefix("..") { return true }
                // Home-protected subpaths (~/.ssh, ~/.aws, ...)
                if path.hasPrefix("~") {
                    let relative = String(path.dropFirst())
                    for sub in protectedHomeSubpaths {
                        if relative == sub || relative.hasPrefix(sub + "/") || relative.hasPrefix("/" + sub) { return true }
                    }
                }
                if path.hasPrefix("/users/") || path.hasPrefix("/home/") {
                    for sub in protectedHomeSubpaths {
                        if path.contains("/" + sub) { return true }
                    }
                }
            }
        }
        return false
    }

    // MARK: - Layer 5 helpers

    private func attemptsExfiltration(_ command: String) -> Bool {
        let segmentsList = segments(of: command)

        for (index, segment) in segmentsList.enumerated() {
            guard let program = executable(of: segment), exfilVerbs.contains(program) else { continue }

            // 1. A pipe INTO a network program (cat file | curl …)
            if index > 0 { return true }

            // 2. Input file arguments (@file, -d @, --data-binary, or a credential-ish path)
            let credentialMarkers = [".ssh", "id_rsa", "id_ed25519", ".aws/credentials", ".env",
                                     ".netrc", ".gnupg", "keychain", "credentials", ".kube/config"]
            for token in segment.split(separator: " ").map(String.init) {
                let t = collapseDotDot(token)
                if t.hasPrefix("@") { return true }
                if credentialMarkers.contains(where: { t.contains($0) }) { return true }
                if t.contains("keychain") || t.contains("security find-generic-password") { return true }
            }

            // 3. Reading secrets via a preceding segment then uploading
            let priorText = segmentsList[..<index].joined(separator: " ")
            if credentialMarkers.contains(where: { priorText.contains($0) }) { return true }
        }
        return false
    }

    /// Collapse "a/../" traversal sequences so ../../../../etc/passwd
    /// resolves to a form the protected-prefix check can see.
    private func collapseDotDot(_ token: String) -> String {
        var result = token
        while result.contains("../") {
            result = result.replacingOccurrences(of: "../", with: "")
        }
        return result
    }
}
