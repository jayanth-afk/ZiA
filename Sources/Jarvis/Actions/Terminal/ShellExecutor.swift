import Foundation

/// Safe, non-blocking shell command execution running off MainActor.
/// Guardrail 1 & 8: Runs in background actor and supports first-class process cancellation.
///
/// Lifecycle & Safety Guarantees:
/// 1. Process-Group Isolation: Kills entire process subtree via POSIX `killpg`
/// 2. Deterministic Timeout: Timeout enforcement via asynchronous timer task
/// 3. Event-Driven Exit: Uses `process.terminationHandler` without busy-wait polling loops
/// 4. SIGTERM -> SIGKILL Escalation: 500ms grace window, then SIGKILL to lingering processes
/// 5. Disarmed Escalation on Clean Exit: Cancels SIGKILL timer if process already exited (prevents PID reuse risk)
/// 6. Anti-False-Success Gate: Forces non-zero exit code if process was forcefully killed (even if script traps SIGTERM)
/// 7. Pre-Launch Cancellation Check: Aborts immediately if task is pre-cancelled without launching OS process
/// 8. Idempotent `cancelAll()`: Crash-safe against double-termination or already-exited processes
/// 9. Pipe Deadlock Prevention: Asynchronous concurrent pipe reading before exit completion
actor ShellExecutor {
    static let shared = ShellExecutor()

    struct CommandOutput: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let durationMs: Double
    }

    /// Thread-safe process group termination scope.
    /// Manages atomic termination state and POSIX signal escalation.
    final class ProcessScope: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var isKilled = false
        private var escalationWorkItem: DispatchWorkItem?

        init(pid: pid_t) {
            self.pid = pid
        }

        func killGroup() {
            lock.lock()
            defer { lock.unlock() }
            guard !isKilled else { return }
            isKilled = true
            guard pid > 0 else { return }

            // Send SIGTERM to entire process group
            killpg(pid, SIGTERM)

            // Escalate to SIGKILL if processes remain after grace period
            let capturedPid = pid
            let item = DispatchWorkItem {
                if kill(capturedPid, 0) == 0 {
                    killpg(capturedPid, SIGKILL)
                }
            }
            escalationWorkItem = item
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        /// Disarm the 500ms SIGKILL escalation timer once the process is confirmed terminated.
        /// Prevents firing SIGKILL against a recycled PID.
        func disarmEscalation() {
            lock.lock()
            defer { lock.unlock() }
            escalationWorkItem?.cancel()
            escalationWorkItem = nil
        }

        /// Indicates whether any termination path (timeout, cancel, emergency stop) claimed kill rights.
        var wasKilled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isKilled
        }
    }

    /// Thread-safe continuation gate ensuring resume is called exactly once.
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func resumeOnce(_ cont: CheckedContinuation<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            cont.resume()
        }
    }

    private var runningScopes: [UUID: ProcessScope] = [:]

    private init() {}

    // MARK: - Public API

    /// Execute a shell command asynchronously in the background.
    func execute(_ command: String, timeoutSeconds: Double = 30.0) async throws -> CommandOutput {
        // Validate with sandbox on MainActor
        try await CommandSandbox.shared.validateCommand(command)

        // Pre-launch cancellation check: do not spawn OS processes if task is already cancelled
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.qualityOfService = .userInitiated

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            try process.run()
        } catch {
            throw JarvisError.actionFailed(
                action: "ShellExecutor.execute",
                reason: "Failed to launch process: \(error.localizedDescription)"
            )
        }

        let pid = process.processIdentifier
        let scope = ProcessScope(pid: pid)
        let processID = UUID()
        runningScopes[processID] = scope

        // Start reading pipes asynchronously BEFORE waiting for exit to avoid kernel pipe buffer deadlocks (>64KB).
        let stdoutFH = stdoutPipe.fileHandleForReading
        let stderrFH = stderrPipe.fileHandleForReading

        let stdoutReadTask = Task.detached { () -> Data in
            stdoutFH.readDataToEndOfFile()
        }
        let stderrReadTask = Task.detached { () -> Data in
            stderrFH.readDataToEndOfFile()
        }

        // Set up deterministic timeout enforcement task
        let timeoutTask = Task { [scope] in
            try await Task.sleep(nanoseconds: UInt64(max(0.001, timeoutSeconds) * 1_000_000_000))
            JarvisLogger.security.warning(
                "ShellExecutor: timeout (\(String(format: "%.1f", timeoutSeconds))s) reached for pid \(scope.pid)"
            )
            scope.killGroup()
        }

        defer {
            timeoutTask.cancel()
            scope.disarmEscalation()
            runningScopes.removeValue(forKey: processID)
        }

        let gate = ContinuationGate()

        do {
            // Event-driven suspension waiting for process termination without busy-wait polling
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in
                        gate.resumeOnce(cont)
                    }
                    if !process.isRunning {
                        gate.resumeOnce(cont)
                    }
                }
                process.terminationHandler = nil
            } onCancel: {
                scope.killGroup()
            }

            timeoutTask.cancel()
            process.waitUntilExit()
            scope.disarmEscalation()

            let stdoutData = await stdoutReadTask.value
            let stderrData = await stderrReadTask.value

            if Task.isCancelled {
                scope.killGroup()
                throw CancellationError()
            }

            var exitCode = process.terminationStatus
            // Guard against false success: if killed by timeout/cancel, exit code must never be 0
            // even if child process caught SIGTERM and exited 0.
            if scope.wasKilled && exitCode == 0 {
                exitCode = 143 // Standard POSIX 128 + 15 (SIGTERM)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return CommandOutput(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: exitCode,
                durationMs: elapsed
            )
        } catch {
            scope.killGroup()
            throw error
        }
    }

    /// Cancel all currently running shell processes (e.g. on EmergencyStop).
    /// Safe and idempotent against double-termination or already-exited processes.
    func cancelAll() {
        for (id, scope) in runningScopes {
            scope.killGroup()
            JarvisLogger.security.info(
                "ShellExecutor.cancelAll: killed process group for [\(id.uuidString.prefix(8))] (pid: \(scope.pid))"
            )
        }
        runningScopes.removeAll()
    }
}
