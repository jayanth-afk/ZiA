import Foundation

/// Enforces security guardrails and blacklist patterns for shell command execution.
@MainActor
final class CommandSandbox {
    static let shared = CommandSandbox()

    // Explicit blacklist of destructive or high-risk shell patterns
    private let blockedPatterns = [
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
        "| sh",
        "| bash",
        "| zsh",
        "| /bin/sh",
        "| /bin/bash",
        "curl |",
        "wget |",
        "> /dev/sda",
        "> /dev/disk"
    ]

    private init() {}

    // MARK: - Public API

    /// Validate a shell command string against safety blacklist.
    /// Throws JarvisError.commandBlocked if dangerous pattern is found.
    func validateCommand(_ command: String) throws {
        let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !cleaned.isEmpty else {
            throw JarvisError.actionFailed(action: "executeCommand", reason: "Command is empty")
        }

        for pattern in blockedPatterns {
            if cleaned.contains(pattern) {
                JarvisLogger.security.fault("BLOCKED DANGEROUS COMMAND: '\(command)' contains '\(pattern)'")
                throw JarvisError.commandBlocked(command: command, reason: "Dangerous pattern '\(pattern)' is blacklisted")
            }
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
}
