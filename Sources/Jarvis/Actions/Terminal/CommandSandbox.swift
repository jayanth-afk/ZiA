import Foundation

/// Enforces security guardrails for shell command execution.
///
/// Layered defense (not a simple blacklist):
///   1. Exact-pattern blacklist (fast path, defense in depth)
///   2. Normalized rescan — strips quoting/substitution syntax before re-checking
///      (defeats r'm' -'r'f, $(echo rm) -rf, base64|sh chains, osascript injection)
///   3. Program analysis — each pipeline/chain segment's executable is checked
///      against a dangerous-program list (defeats "echo safe && rm -rf /")
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

    /// Wrapper/trampoline programs that forward execution to a LATER program.
    /// A leading wrapper must never hide the real executable from layer 3
    /// (e.g. `env rm …`, `nohup rm …`, `xargs rm`, `nice -n 10 rm …`).
    private let wrapperPrograms: Set<String> = [
        "env", "nice", "nohup", "time", "stdbuf", "setsid", "command", "builtin", "xargs"
    ]

    /// Flags that introduce a program launched by the current program
    /// (e.g. `find . -exec rm {} +`, `find . -execdir rm {} +`).
    private let execIntroducerFlags: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]

    /// Read-only programs allowed to run unsupervised. Anything NOT in this set
    /// and NOT obviously benign is treated as requiring confirmation upstream.
    private let knownSafePrograms: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "find", "wc", "file", "stat",
        "pwd", "echo", "date", "whoami", "uname", "df", "du", "ps", "top",
        "which", "git", "swift", "swiftc", "python3", "sed", "awk", "sort",
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

        // Layer 3: program analysis on every pipeline/chain segment. EVERY
        // program a segment can actually launch is checked, not merely its
        // leading token: wrapper/trampoline programs (`env`, `nohup`, `xargs`,
        // `command`, `nice`, …) and `find -exec`/`-execdir` actions forward
        // execution to another program, and that program is the one the
        // dangerous-program list must see.
        for segment in segments(of: normalized) {
            for program in executingPrograms(of: segment) where dangerousPrograms.contains(program) {
                JarvisLogger.security.fault("BLOCKED (layer 3 program): '\(command)' runs dangerous program '\(program)'")
                throw JarvisError.commandBlocked(command: command, reason: "Program '\(program)' is not permitted")
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
            if char == ";" || char == "|" || char == "\n" {
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

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // Environment assignments, option flags, and numeric option values
            // are never the executed program.
            if isEnvironmentAssignment(token) || token.hasPrefix("-") || token.allSatisfy(\.isNumber) {
                index += 1
                continue
            }
            let program = executableName(of: token)
            if wrapperPrograms.contains(program) {
                // A wrapper forwards to the next program; keep scanning.
                index += 1
                continue
            }
            programs.append(program)
            break
        }

        for (offset, token) in tokens.enumerated() where execIntroducerFlags.contains(token) {
            guard offset + 1 < tokens.count else { continue }
            let candidate = tokens[offset + 1]
            guard !candidate.hasPrefix("-") else { continue }
            programs.append(executableName(of: candidate))
        }

        return programs
    }

    /// True for `NAME=value` environment assignments (leading letter or `_`).
    private func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter || first == "_" else { return false }
        return token.dropFirst().contains("=")
    }

    /// Basename of a command token (strips a leading path).
    private func executableName(of token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
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
