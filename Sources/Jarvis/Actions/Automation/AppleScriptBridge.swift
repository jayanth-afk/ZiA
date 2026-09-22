import Foundation

/// Safe, background executor for AppleScript automation.
/// Guardrail 1: Executes outside MainActor so UI remains fluid.
actor AppleScriptBridge {
    static let shared = AppleScriptBridge()

    private init() {}

    // MARK: - Public API

    /// Execute an AppleScript string via osascript process with timeout and cancellation.
    func execute(_ script: String, timeoutSeconds: Double = 15.0) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            do {
                try process.run()

                let startTime = Date()
                while process.isRunning {
                    if Task.isCancelled {
                        process.terminate()
                        throw CancellationError()
                    }
                    if Date().timeIntervalSince(startTime) > timeoutSeconds {
                        process.terminate()
                        throw JarvisError.actionFailed(action: "executeAppleScript", reason: "AppleScript execution timed out after \(timeoutSeconds)s")
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus != 0 {
                    let errStr = String(data: stderrData, encoding: .utf8) ?? "Unknown AppleScript error"
                    throw JarvisError.actionFailed(action: "executeAppleScript", reason: errStr.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                let output = String(data: stdoutData, encoding: .utf8) ?? ""
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                process.terminate()
                throw error
            }
        } onCancel: {
            process.terminate()
        }
    }
}
