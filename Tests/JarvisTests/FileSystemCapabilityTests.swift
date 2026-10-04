import Foundation
import Testing
@testable import Jarvis

/// Safe filesystem / search / patch capabilities. These tests exercise the
/// capability contract directly (execute → observe → verify) inside a scratch
/// directory under the app's own Application Support folder, which the existing
/// `FileManagerJarvis` safety boundary permits.
@Suite struct FileSystemCapabilityTests {

    private func makeBaseDir() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("zia-fs-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func createDirectoryCreatesAndVerifies() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("nested/deep").path

        let tool = CreateDirectoryTool()
        let result = try await tool.execute(arguments: ["path": target])
        let observed = try await tool.observe(expected: result)
        #expect(tool.verifyDetailed(expected: result, observed: observed).isSuccess)
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test func appendFileGrowsAndVerifies() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("log.txt").path

        let tool = AppendFileTool()
        let args: [String: any Sendable] = ["path": file, "content": "first line\n"]
        let result = try await tool.execute(arguments: args)
        let observed = try await tool.observe(expected: result)
        #expect(tool.verifyDetailed(expected: result, observed: observed).isSuccess)
        let contents = try String(contentsOfFile: file, encoding: .utf8)
        #expect(contents == "first line\n")
    }

    @Test func replaceInFileFirstOccurrenceAndVerifies() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("code.txt").path
        try "let a = 1\nlet b = 1\n".write(toFile: file, atomically: true, encoding: .utf8)

        let tool = ReplaceInFileTool()
        let args: [String: any Sendable] = ["path": file, "find": "= 1", "replace": "= 2"]
        let result = try await tool.execute(arguments: args)
        #expect(result.metadata["replacements"] == "1")
        let observed = try await tool.observe(expected: result)
        #expect(tool.verifyDetailed(expected: result, observed: observed).isSuccess)
        let contents = try String(contentsOfFile: file, encoding: .utf8)
        #expect(contents == "let a = 2\nlet b = 1\n")
    }

    @Test func replaceInFileAllOccurrences() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("code.txt").path
        try "let a = 1\nlet b = 1\n".write(toFile: file, atomically: true, encoding: .utf8)

        let tool = ReplaceInFileTool()
        let args: [String: any Sendable] = ["path": file, "find": "= 1", "replace": "= 2", "all": 1]
        let result = try await tool.execute(arguments: args)
        #expect(result.metadata["replacements"] == "2")
        let contents = try String(contentsOfFile: file, encoding: .utf8)
        #expect(contents == "let a = 2\nlet b = 2\n")
    }

    @Test func replaceInFileRejectsAbsentText() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("code.txt").path
        try "hello".write(toFile: file, atomically: true, encoding: .utf8)
        await #expect(throws: JarvisError.self) {
            _ = try await ReplaceInFileTool().execute(arguments: ["path": file, "find": "absent", "replace": "x"])
        }
    }

    @Test func movePathMovesAndVerifies() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("a.txt").path
        let destination = base.appendingPathComponent("b.txt").path
        try "hello".write(toFile: source, atomically: true, encoding: .utf8)

        let tool = MoveOrCopyPathTool(move: true)
        let result = try await tool.execute(arguments: ["source": source, "destination": destination])
        let observed = try await tool.observe(expected: result)
        #expect(tool.verifyDetailed(expected: result, observed: observed).isSuccess)
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(FileManager.default.fileExists(atPath: destination))
    }

    @Test func deletePathRemovesAndVerifies() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("gone.txt").path
        try "x".write(toFile: file, atomically: true, encoding: .utf8)

        let tool = DeletePathTool()
        let result = try await tool.execute(arguments: ["path": file])
        let observed = try await tool.observe(expected: result)
        #expect(tool.verifyDetailed(expected: result, observed: observed).isSuccess)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func listDirectoryRefusesSensitivePath() async {
        await #expect(throws: (any Error).self) {
            _ = try await ListDirectoryTool().execute(arguments: ["path": "~/.ssh"])
        }
    }

    @Test func searchAndGrepFindContent() async throws {
        let base = try makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try "needle here\n".write(toFile: base.appendingPathComponent("haystack.txt").path,
                                  atomically: true, encoding: .utf8)

        let search = try await SearchFilesTool().execute(
            arguments: ["directory": base.path, "name_contains": "haystack"])
        #expect(search.metadata["count"] == "1")

        let grep = try await GrepFilesTool().execute(
            arguments: ["directory": base.path, "pattern": "needle"])
        #expect(Int(grep.metadata["count"] ?? "0") ?? 0 >= 1)
    }
}

/// Classified retry policy.
@Suite struct RecoveryPolicyTests {

    @Test func nonRecoverableCategories() {
        #expect(!RecoveryPolicy.isRecoverable(.permission))
        #expect(!RecoveryPolicy.isRecoverable(.cancellation))
        #expect(!RecoveryPolicy.isRecoverable(.syntax))
    }

    @Test func recoverableCategories() {
        #expect(RecoveryPolicy.isRecoverable(.execution))
        #expect(RecoveryPolicy.isRecoverable(.timeout))
        #expect(RecoveryPolicy.isRecoverable(.verification))
        #expect(RecoveryPolicy.isRecoverable(.unavailable))
    }
}
