import Foundation

/// Read-only, Git-grounded development history. It reports committed evidence
/// only; conversation claims and uncommitted model output are not represented
/// as completed development work.
enum DevelopmentHistory {
    struct Commit: Sendable, Equatable {
        let hash: String
        let date: String
        let subject: String
    }

    static func render(commits: [Commit]) -> String {
        guard !commits.isEmpty else { return "I couldn't find any committed Zia development history." }
        let rows = commits.prefix(5).map { "• \($0.date) (\($0.hash)): \($0.subject)" }
        return "Recent committed Zia changes:\n" + rows.joined(separator: "\n")
    }

    static func recentSummary(repositoryRoot: URL? = locateZiaRepository()) -> String {
        guard let repositoryRoot,
              let output = runGit(in: repositoryRoot, arguments: [
                "log", "-5", "--format=%h%x1f%cs%x1f%s"
              ]) else {
            return "I can't access a Zia Git checkout from this runtime, so I can't verify recent code changes."
        }

        let commits = output.split(whereSeparator: \.isNewline).compactMap { line -> Commit? in
            let fields = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return Commit(hash: String(fields[0]), date: String(fields[1]), subject: String(fields[2]))
        }
        return render(commits: commits)
    }

    private static func locateZiaRepository() -> URL? {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<10 {
            let isZiaSourceTree = FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path)
                && FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Sources/Jarvis").path)
            if isZiaSourceTree,
               runGit(in: candidate, arguments: ["rev-parse", "--show-toplevel"]) != nil {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return nil
    }

    /// Safely runs a git subprocess with redirected stderr to avoid kernel pipe deadlocks.
    private static func runGit(in root: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        // Ref/object-only git commands still run with the authority-neutralized
        // environment: a repository-global `log.showSignature` plus a
        // repository-set `gpg.program` would otherwise turn `git log` into
        // arbitrary program execution from repository content.
        process.environment = ProcessAuthority.gitProcessEnvironment()
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        // Redirect stderr to null device to prevent kernel pipe buffer deadlock when stderr exceeds 64KB
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}