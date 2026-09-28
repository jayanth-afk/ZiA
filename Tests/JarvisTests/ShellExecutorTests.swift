import XCTest
@testable import Jarvis

/// Deterministic tests for ShellExecutor process lifecycle correctness.
///
/// These tests verify the 6 correctness properties from the Phase 1 rewrite:
/// 1. Normal execution produces correct stdout/stderr/exitCode
/// 2. Timeout enforcement kills the process deterministically
/// 3. Task cancellation kills the process immediately
/// 4. cancelAll() is idempotent (double-call is safe)
/// 5. Process-group isolation (child processes are killed with parent)
/// 6. Pipe reads work correctly for large output
final class ShellExecutorTests: XCTestCase {

    // MARK: - 1. Normal Execution

    /// Verify basic command execution returns correct stdout and exit code.
    func testNormalExecution() async throws {
        let output = try await ShellExecutor.shared.execute("echo hello world", timeoutSeconds: 5.0)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssert(output.durationMs > 0, "Duration should be positive")
    }

    /// Verify stderr is captured correctly.
    func testStderrCapture() async throws {
        let output = try await ShellExecutor.shared.execute("echo error_text >&2", timeoutSeconds: 5.0)
        XCTAssertTrue(output.stderr.contains("error_text"), "stderr should contain the error text")
        XCTAssertEqual(output.exitCode, 0)
    }

    /// Verify non-zero exit codes are captured.
    func testNonZeroExitCode() async throws {
        let output = try await ShellExecutor.shared.execute("exit 42", timeoutSeconds: 5.0)
        XCTAssertEqual(output.exitCode, 42)
    }

    // MARK: - 2. Timeout Enforcement

    /// Verify that a long-running command is killed after the timeout.
    /// The timeout is set to 1 second; the command sleeps for 60 seconds.
    /// The test must complete in well under 60 seconds — if it doesn't,
    /// the timeout enforcement is broken.
    func testTimeoutEnforcement() async throws {
        let start = CFAbsoluteTimeGetCurrent()
        let output = try await ShellExecutor.shared.execute(
            "sleep 60",
            timeoutSeconds: 1.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // The process should have been killed by the timeout.
        // Exit code will be non-zero (SIGTERM = 143, SIGKILL = 137, or similar).
        XCTAssertNotEqual(output.exitCode, 0,
            "Process should have been killed by timeout (exit code: \(output.exitCode))")
        XCTAssertLessThan(elapsed, 5.0,
            "Timeout should have fired within ~1s, but took \(elapsed)s")
    }

    // MARK: - 3. Task Cancellation

    /// Verify that cancelling the Swift Task kills the shell process.
    func testTaskCancellation() async throws {
        let start = CFAbsoluteTimeGetCurrent()

        let task = Task {
            try await ShellExecutor.shared.execute("sleep 60", timeoutSeconds: 30.0)
        }

        // Give the process time to start
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Cancel the task
        task.cancel()

        // Wait for the result
        let result = await task.result
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        switch result {
        case .success:
            // It's acceptable if the process was killed and returned before
            // the cancellation was checked, but the elapsed time must be short.
            XCTAssertLessThan(elapsed, 5.0, "Even if not thrown, should complete quickly")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                "Expected CancellationError but got: \(error)")
        }
        XCTAssertLessThan(elapsed, 5.0,
            "Cancellation should complete within a few seconds, not \(elapsed)s")
    }

    // MARK: - 4. cancelAll() Idempotency

    /// Verify that calling cancelAll() twice in succession does not crash.
    func testCancelAllIdempotent() async {
        // Start a long-running process
        let task = Task {
            try await ShellExecutor.shared.execute("sleep 60", timeoutSeconds: 30.0)
        }

        // Give it time to start
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Call cancelAll twice — this must not crash (no double-terminate exception)
        await ShellExecutor.shared.cancelAll()
        await ShellExecutor.shared.cancelAll() // Must be safe

        // Clean up
        task.cancel()
        _ = await task.result
    }

    // MARK: - 5. Process-Group Cleanup

    /// Verify that child processes spawned by the command are also killed.
    /// The command spawns a background child (`sleep 300 &`), then sleeps.
    /// After cancellation, neither the parent nor the child should remain.
    func testProcessGroupCleanup() async throws {
        // Use a unique marker to identify our test processes
        let marker = "jarvis_shellexec_test_\(UUID().uuidString.prefix(8))"

        let task = Task {
            try await ShellExecutor.shared.execute(
                // The parent spawns a child with a unique marker, then waits
                "bash -c 'sleep 300 & echo \(marker)_child_started; wait'",
                timeoutSeconds: 30.0)
        }

        // Give the child time to start
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Kill via cancelAll
        await ShellExecutor.shared.cancelAll()
        task.cancel()
        _ = await task.result

        // Wait briefly for process cleanup
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        // Verify no orphaned processes with our marker remain
        let checkOutput = try await ShellExecutor.shared.execute(
            "pgrep -f '\(marker)' 2>/dev/null || echo 'no_orphans'",
            timeoutSeconds: 5.0)
        XCTAssertTrue(
            checkOutput.stdout.contains("no_orphans") || checkOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Orphaned child processes should have been killed. pgrep output: \(checkOutput.stdout)")
    }

    // MARK: - 6. Large Output (Pipe Deadlock Prevention)

    /// Verify that commands producing large output (> pipe buffer size) complete
    /// without deadlocking. The standard pipe buffer on macOS is 64KB.
    func testLargeOutputNoPipeDeadlock() async throws {
        // Generate ~100KB of output (well above 64KB pipe buffer)
        let output = try await ShellExecutor.shared.execute(
            "python3 -c 'print(\"A\" * 100000)'",
            timeoutSeconds: 10.0)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertGreaterThan(output.stdout.count, 50000,
            "Should have captured large stdout without deadlock")
    }

    // MARK: - 7. CommandSandbox Integration

    /// Verify that blocked commands are rejected before execution.
    func testSandboxBlockedCommand() async {
        do {
            _ = try await ShellExecutor.shared.execute("sudo rm -rf /", timeoutSeconds: 5.0)
            XCTFail("Should have thrown for blocked command")
        } catch {
            // Expected: command blocked by sandbox
            XCTAssertFalse(error is CancellationError,
                "Should be a sandbox error, not cancellation")
        }
    }

    // MARK: - 8. Empty Command

    /// Verify that empty commands are rejected.
    func testEmptyCommandRejected() async {
        do {
            _ = try await ShellExecutor.shared.execute("", timeoutSeconds: 5.0)
            XCTFail("Should have thrown for empty command")
        } catch {
            // Expected
        }
    }
}
