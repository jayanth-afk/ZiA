import Foundation

/// Safe, non-blocking shell command execution running off MainActor.
/// Guardrail 1 & 8: Runs in background actor and supports first-class process cancellation.
actor ShellExecutor {
    static let shared = ShellExecutor()

    struct CommandOutput: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let durationMs: Double
    }

    private var runningProcesses: [UUID: Process] = [:]

    private init() {}

    // MARK: - Public API

    /// Execute a shell command asynchronously in the background.
    func execute(_ command: String, timeoutSeconds: Double = 30.0) async throws -> CommandOutput {
        // Validate with sandbox on MainActor
        try await CommandSandbox.shared.validateCommand(command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processID = UUID()
        runningProcesses[processID] = process

        let startTime = CFAbsoluteTimeGetCurrent()

        return try await withTaskCancellationHandler {
            do {
                try process.run()

                // Await completion with cancellation check
                while process.isRunning {
                    if Task.isCancelled {
                        process.terminate()
                        runningProcesses.removeValue(forKey: processID)
                        throw CancellationError()
                    }
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms polling
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

                runningProcesses.removeValue(forKey: processID)

                return CommandOutput(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    durationMs: elapsed
                )
            } catch {
                process.terminate()
                runningProcesses.removeValue(forKey: processID)
                throw error
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Cancel all currently running shell processes (e.g. on EmergencyStop).
    func cancelAll() {
        for (_, process) in runningProcesses {
            if process.isRunning {
                process.terminate()
            }
        }
        runningProcesses.removeAll()
    }
}
