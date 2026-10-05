import Foundation
import CryptoKit
import AppKit

/// Kind of evidence collected by the VerificationEngine.
enum VerificationEvidenceType: String, Sendable, Codable {
    case fileExists
    case fileContent
    case fileHash
    case commandExit
    case artifactState
    case processState
    case taskState
    case browserState
    case externalResult
    case customObservation
}

/// A structured piece of deterministic verification evidence.
struct VerificationEvidence: Sendable, Equatable, Codable {
    let type: VerificationEvidenceType
    let target: String
    let verdict: VerificationOutcome
    let expected: String?
    let observed: String?
    let details: String
    let timestamp: Date

    var isPassed: Bool { verdict == .passed }
}

/// Consolidated report of multiple verifications for a task or operation.
struct VerificationReport: Sendable, Equatable {
    let items: [VerificationEvidence]
    let timestamp: Date

    var isAllPassed: Bool {
        !items.isEmpty && items.allSatisfy { $0.isPassed }
    }

    var passedCount: Int {
        items.filter { $0.isPassed }.count
    }

    var failedCount: Int {
        items.filter { $0.verdict == .failed }.count
    }

    var summary: String {
        guard !items.isEmpty else { return "No verification evidence collected." }
        var lines = ["Verification summary: \(passedCount)/\(items.count) checks passed."]
        for item in items {
            let icon = item.isPassed ? "✓" : (item.verdict == .failed ? "✗" : "?")
            lines.append("  \(icon) [\(item.type.rawValue)] \(item.target): \(item.details)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Reusable deterministic verification abstraction.
///
/// Guarantees:
/// - Evidence is deterministically gathered from reality (filesystem, process table,
///   exit codes, cryptographic hashes, browser state).
/// - Never guesses or infers success from model output alone.
/// - Conforms to the single source of truth for sensitive paths.
enum VerificationEngine {

    // MARK: - Filesystem verification

    static func verifyFileExists(path: String) -> VerificationEvidence {
        let expanded = (path as NSString).expandingTildeInPath
        if SensitivePaths.contains(expanded) {
            return VerificationEvidence(
                type: .fileExists, target: path, verdict: .unavailable,
                expected: "accessible path", observed: "sensitive path",
                details: "Cannot verify existence of sensitive path.", timestamp: .now)
        }
        let exists = FileManager.default.fileExists(atPath: expanded)
        return VerificationEvidence(
            type: .fileExists, target: path,
            verdict: exists ? .passed : .failed,
            expected: "file exists", observed: exists ? "exists" : "missing",
            details: exists ? "File exists at \(expanded)." : "File not found at \(expanded).",
            timestamp: .now)
    }

    static func verifyFileContent(path: String, contains: String? = nil, exact: String? = nil) -> VerificationEvidence {
        let expanded = (path as NSString).expandingTildeInPath
        if SensitivePaths.contains(expanded) {
            return VerificationEvidence(
                type: .fileContent, target: path, verdict: .unavailable,
                expected: "accessible path", observed: "sensitive path",
                details: "Cannot verify content of sensitive path.", timestamp: .now)
        }
        guard let text = FileSystemObserver.shared.readText(path: expanded) else {
            return VerificationEvidence(
                type: .fileContent, target: path, verdict: .failed,
                expected: "readable file", observed: "unreadable or missing",
                details: "File could not be read at \(expanded).", timestamp: .now)
        }

        if let exact {
            let matched = text == exact
            return VerificationEvidence(
                type: .fileContent, target: path,
                verdict: matched ? .passed : .failed,
                expected: "\(exact.count) chars exact match",
                observed: "\(text.count) chars",
                details: matched ? "File content exactly matches expectation." : "File content does not match exact expectation.",
                timestamp: .now)
        }

        if let contains {
            let containsSubstring = text.contains(contains)
            return VerificationEvidence(
                type: .fileContent, target: path,
                verdict: containsSubstring ? .passed : .failed,
                expected: "contains '\(contains.prefix(40))'",
                observed: containsSubstring ? "substring found" : "substring missing",
                details: containsSubstring ? "File contains expected text." : "File missing expected text.",
                timestamp: .now)
        }

        return VerificationEvidence(
            type: .fileContent, target: path, verdict: .passed,
            expected: "readable UTF-8", observed: "\(text.count) chars",
            details: "File is readable non-empty text.", timestamp: .now)
    }

    static func verifyFileHash(path: String, expectedSHA256: String) -> VerificationEvidence {
        let expanded = (path as NSString).expandingTildeInPath
        if SensitivePaths.contains(expanded) {
            return VerificationEvidence(
                type: .fileHash, target: path, verdict: .unavailable,
                expected: expectedSHA256, observed: "sensitive",
                details: "Cannot compute hash of sensitive path.", timestamp: .now)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
            return VerificationEvidence(
                type: .fileHash, target: path, verdict: .failed,
                expected: expectedSHA256, observed: "unreadable",
                details: "File could not be read to compute SHA-256.", timestamp: .now)
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let matched = actual.lowercased() == expectedSHA256.lowercased()
        return VerificationEvidence(
            type: .fileHash, target: path,
            verdict: matched ? .passed : .failed,
            expected: expectedSHA256, observed: actual,
            details: matched ? "SHA-256 matches expected digest." : "SHA-256 mismatch (expected \(expectedSHA256.prefix(12)), got \(actual.prefix(12))).",
            timestamp: .now)
    }

    // MARK: - Command execution verification

    static func verifyCommandExit(exitCode: Int32, expectedExitCode: Int32 = 0, stdout: String? = nil, requiredOutputFragment: String? = nil) -> VerificationEvidence {
        var verdict: VerificationOutcome = exitCode == expectedExitCode ? .passed : .failed
        var details = "Command exited with code \(exitCode) (expected \(expectedExitCode))."

        if verdict == .passed, let fragment = requiredOutputFragment, let out = stdout {
            if !out.contains(fragment) {
                verdict = .failed
                details += " Required output fragment '\(fragment.prefix(40))' missing."
            } else {
                details += " Output verified."
            }
        }

        return VerificationEvidence(
            type: .commandExit, target: "command",
            verdict: verdict,
            expected: "exit \(expectedExitCode)" + (requiredOutputFragment != nil ? " with fragment" : ""),
            observed: "exit \(exitCode)",
            details: details,
            timestamp: .now)
    }

    // MARK: - Artifact verification

    @MainActor
    static func verifyArtifact(path: String, expectedSHA256: String? = nil) -> VerificationEvidence {
        let expanded = (path as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: expanded)
        guard exists else {
            return VerificationEvidence(
                type: .artifactState, target: path, verdict: .failed,
                expected: "artifact exists", observed: "missing",
                details: "Artifact file does not exist at \(expanded).", timestamp: .now)
        }

        if let expectedHash = expectedSHA256 {
            return verifyFileHash(path: expanded, expectedSHA256: expectedHash)
        }

        return VerificationEvidence(
            type: .artifactState, target: path, verdict: .passed,
            expected: "artifact exists", observed: "exists",
            details: "Artifact exists and is accessible.", timestamp: .now)
    }

    // MARK: - Process verification

    static func verifyProcess(named processName: String, shouldBeRunning: Bool = true) -> VerificationEvidence {
        let runningApps = NSWorkspace.shared.runningApplications
        let isRunning = runningApps.contains { app in
            app.localizedName?.lowercased() == processName.lowercased() ||
            app.bundleIdentifier?.lowercased() == processName.lowercased()
        }
        let matched = isRunning == shouldBeRunning
        return VerificationEvidence(
            type: .processState, target: processName,
            verdict: matched ? .passed : .failed,
            expected: shouldBeRunning ? "running" : "stopped",
            observed: isRunning ? "running" : "not running",
            details: matched ? "Process state matches expectation." : "Process \(processName) was \(isRunning ? "running" : "not running"), expected \(shouldBeRunning ? "running" : "stopped").",
            timestamp: .now)
    }

    // MARK: - Task verification

    static func verifyTask(taskID: UUID, expectedState: TaskState = .completed) -> VerificationEvidence {
        guard let task = TaskStateMachine.shared.getTask(id: taskID) else {
            return VerificationEvidence(
                type: .taskState, target: taskID.uuidString, verdict: .failed,
                expected: expectedState.rawValue, observed: "not found",
                details: "Task \(taskID) not found in state machine.", timestamp: .now)
        }
        let matched = task.state == expectedState
        return VerificationEvidence(
            type: .taskState, target: taskID.uuidString,
            verdict: matched ? .passed : .failed,
            expected: expectedState.rawValue, observed: task.state.rawValue,
            details: matched ? "Task state is \(expectedState.rawValue)." : "Task state is \(task.state.rawValue), expected \(expectedState.rawValue).",
            timestamp: .now)
    }

    // MARK: - External result verification

    static func verifyExternalResult(request: ExternalAgentRequest, response: ExternalAgentResponse) -> VerificationEvidence {
        let isCorrelated = response.isCorrelated(with: request)
        return VerificationEvidence(
            type: .externalResult, target: request.id.uuidString,
            verdict: isCorrelated ? .passed : .failed,
            expected: "correlated response for \(request.id)",
            observed: "requestID=\(response.requestID), correlationID=\(response.correlationID)",
            details: isCorrelated ? "External response correctly correlated and fresh." : "External response failed correlation or deadline check.",
            timestamp: .now)
    }
}
