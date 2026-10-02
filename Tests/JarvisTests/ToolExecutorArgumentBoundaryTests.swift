import Foundation
import Testing
@testable import Jarvis

@Suite struct ToolExecutorArgumentBoundaryTests {
    @Test @MainActor
    func undeclaredArgumentIsRejectedBeforeExecution() async throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/zia-arg-boundary-repro-\\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            _ = try await ToolExecutor.shared.execute(
                toolName: "write_file",
                arguments: ["path": path, "content": "boundary-repro", "unexpected": "attacker-controlled"]
            )
            #expect(Bool(false), "Undeclared argument reached real tool execution")
        } catch {
            #expect(error.localizedDescription.contains("Unknown argument 'unexpected'"), "Unexpected error: \\(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: path), "Rejected argument set must not produce a side effect")
    }

    @Test @MainActor
    func missingRequiredArgumentIsRejectedBeforeExecution() async throws {
        do {
            _ = try await ToolExecutor.shared.execute(
                toolName: "write_file",
                arguments: ["path": "/tmp/should-not-be-created.txt"]
            )
            #expect(Bool(false), "Missing required argument reached real tool execution")
        } catch {
            #expect(error.localizedDescription.contains("Missing required argument 'content'"), "Unexpected error: \\(error)")
        }
    }

    @Test @MainActor
    func wrongArgumentTypeIsRejectedBeforeExecution() async throws {
        do {
            _ = try await ToolExecutor.shared.execute(
                toolName: "write_file",
                arguments: ["path": 123, "content": "type-boundary"]
            )
            #expect(Bool(false), "Wrongly typed argument reached real tool execution")
        } catch {
            #expect(error.localizedDescription.contains("Argument 'path' must be a string"), "Unexpected error: \\(error)")
        }
    }
}
