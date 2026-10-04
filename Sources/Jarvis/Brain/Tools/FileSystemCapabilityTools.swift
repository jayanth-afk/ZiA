import Foundation

// MARK: - Read-only filesystem intelligence

/// Lists a directory. Read-only and bounded; sensitive credential locations are
/// refused.
struct ListDirectoryTool: JarvisTool {
    let name = "list_directory"
    let description = "Lists the entries of a directory (names only). Read-only. Sensitive credential locations are refused."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: false,
                          description: "Directory path (default: home directory)"),
        ToolParameterSpec(name: "include_hidden", kind: .int, required: false,
                          description: "1 to include dotfiles (default 0)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let path = (arguments["path"] as? String) ?? "~"
        let includeHidden = (arguments["include_hidden"] as? Int) == 1
        let result = try await MainActor.run { () throws -> (resolved: String, entries: [String]) in
            let fm = FileManagerJarvis.shared
            guard !fm.isSensitivePath(path) else {
                throw JarvisError.commandBlocked(command: "list_directory",
                                                 reason: "Sensitive credential location is not listable")
            }
            let resolved = fm.resolvePath(path)
            let entries = try fm.listDirectory(at: path)
            return (resolved, entries)
        }
        var entries = result.entries
        if includeHidden {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: result.resolved)) ?? entries
            entries = all
        }
        let sorted = entries.sorted()
        return ToolResult(
            success: true,
            output: sorted.isEmpty ? "Directory is empty." : sorted.joined(separator: "\n"),
            sideEffects: [],
            metadata: ["path": result.resolved, "count": String(sorted.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("cannot re-read directory")
    }
}

/// Reports file/directory metadata. Read-only.
struct FileMetadataTool: JarvisTool {
    let name = "file_metadata"
    let description = "Reports size, modification time, and type (file/directory) for a path. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: true, description: "Path to inspect")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'path'")
        }
        let sensitive = await MainActor.run { FileManagerJarvis.shared.isSensitivePath(path) }
        guard !sensitive else {
            throw JarvisError.commandBlocked(command: name, reason: "Sensitive credential location is not inspectable")
        }
        let state = FileSystemObserver.shared.observe(path: path)
        guard state.exists else {
            throw JarvisError.actionFailed(action: name, reason: "No such path: \(path)")
        }
        let size = state.fileSize.map(String.init) ?? "n/a"
        let modified = state.modificationDate.map { "\($0)" } ?? "unknown"
        return ToolResult(
            success: true,
            output: "\(state.path): \(state.isDirectory ? "directory" : "file"), size \(size), modified \(modified), readable \(state.isReadable)",
            sideEffects: [],
            metadata: ["path": state.path, "exists": "true",
                       "isDirectory": state.isDirectory ? "true" : "false",
                       "size": size])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("filesystem did not answer")
    }
}

/// Bounded recursive file search by name. Read-only.
struct SearchFilesTool: JarvisTool {
    let name = "search_files"
    let description = "Recursively finds files whose name contains a substring under a directory (bounded). Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "directory", kind: .string, required: true, description: "Root directory to search"),
        ToolParameterSpec(name: "name_contains", kind: .string, required: false, description: "Substring to match in the file name"),
        ToolParameterSpec(name: "max_results", kind: .int, required: false, description: "Maximum results (default 100)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let directory = arguments["directory"] as? String, !directory.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'directory'")
        }
        let needle = (arguments["name_contains"] as? String)?.lowercased() ?? ""
        let maxResults = min(max((arguments["max_results"] as? Int) ?? 100, 1), 500)

        let sensitive = await MainActor.run { FileManagerJarvis.shared.isSensitivePath(directory) }
        guard !sensitive else {
            throw JarvisError.commandBlocked(command: name, reason: "Sensitive credential location is not searchable")
        }
        let root = (directory as NSString).expandingTildeInPath
        let search = Self.searchFiles(root: root, needle: needle, maxResults: maxResults)
        return ToolResult(
            success: true,
            output: search.results.isEmpty ? "No matching files." : search.results.joined(separator: "\n"),
            sideEffects: [],
            metadata: ["count": String(search.results.count), "visited": String(search.visited)])
    }

    /// Synchronous, bounded enumeration (NSEnumerator iteration is unavailable
    /// in async contexts under strict concurrency).
    static func searchFiles(root: String, needle: String, maxResults: Int, visitLimit: Int = 20_000) -> (results: [String], visited: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], 0)
        }
        var results: [String] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > visitLimit || results.count >= maxResults { break }
            let nameLower = url.lastPathComponent.lowercased()
            if needle.isEmpty || nameLower.contains(needle) {
                results.append(url.path)
            }
        }
        return (results, visited)
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("cannot re-read directory")
    }
}

/// Bounded text search across a directory tree. Read-only; skips sensitive and
/// binary files.
struct GrepFilesTool: JarvisTool {
    let name = "grep_files"
    let description = "Searches file contents for a literal string under a directory (bounded; skips sensitive and binary files). Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "directory", kind: .string, required: true, description: "Root directory to search"),
        ToolParameterSpec(name: "pattern", kind: .string, required: true, description: "Literal text to find"),
        ToolParameterSpec(name: "max_matches", kind: .int, required: false, description: "Maximum matches (default 100)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let directory = arguments["directory"] as? String, !directory.isEmpty,
              let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Requires non-empty 'directory' and 'pattern'")
        }
        let maxMatches = min(max((arguments["max_matches"] as? Int) ?? 100, 1), 500)
        let sensitive = await MainActor.run { FileManagerJarvis.shared.isSensitivePath(directory) }
        guard !sensitive else {
            throw JarvisError.commandBlocked(command: name, reason: "Sensitive credential location is not searchable")
        }
        let root = (directory as NSString).expandingTildeInPath
        let grep = Self.grepFiles(root: root, pattern: pattern, maxMatches: maxMatches)
        return ToolResult(
            success: true,
            output: grep.matches.isEmpty ? "No matches." : grep.matches.joined(separator: "\n"),
            sideEffects: [],
            metadata: ["count": String(grep.matches.count), "filesScanned": String(grep.filesScanned)])
    }

    /// Synchronous, bounded content search. Skips sensitive and binary files.
    static func grepFiles(root: String, pattern: String, maxMatches: Int,
                          fileLimit: Int = 2_000, perFileByteLimit: Int = 512 * 1_024) -> (matches: [String], filesScanned: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], 0)
        }
        let needle = pattern.lowercased()
        var matches: [String] = []
        var filesScanned = 0
        for case let url as URL in enumerator {
            if matches.count >= maxMatches || filesScanned >= fileLimit { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > perFileByteLimit { continue }
            filesScanned += 1
            guard let text = FileSystemObserver.shared.readText(path: url.path, maximumBytes: perFileByteLimit),
                  !text.isEmpty else { continue }
            if text.unicodeScalars.contains(where: { $0.value == 0 }) { continue }
            var lineNumber = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                if line.lowercased().contains(needle) {
                    matches.append("\(url.path):\(lineNumber): \(String(line.prefix(200)))")
                    if matches.count >= maxMatches { break }
                }
            }
        }
        return (matches, filesScanned)
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("cannot re-read directory")
    }
}

// MARK: - Low-impact mutations

/// Creates a directory (with intermediate directories). Low impact.
struct CreateDirectoryTool: JarvisTool {
    let name = "create_directory"
    let description = "Creates a directory, including intermediate directories. Low-impact filesystem mutation."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: true, description: "Directory path to create")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'path'")
        }
        let resolved = try await MainActor.run {
            try FileManagerJarvis.shared.validatedWritablePath(path, operation: name)
        }
        var isDir: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
        if existed && isDir.boolValue {
            return ToolResult(success: true, output: "Directory already exists: \(resolved)",
                              metadata: ["path": resolved, "created": "false"])
        }
        try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
        return ToolResult(success: true, output: "Created directory \(resolved)",
                          sideEffects: ["directory_created"], metadata: ["path": resolved, "created": "true"])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let path = expected.metadata["path"] else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no path recorded")
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ObservationResult(observations: ["exists": exists ? "true" : "false",
                                                "isDirectory": isDir.boolValue ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("filesystem did not answer") }
        guard observed.observations["exists"] == "true", observed.observations["isDirectory"] == "true" else {
            return .failed("directory was not created")
        }
        return .passed(reason: "directory exists")
    }
}

/// Appends text to a file (creating it if absent). Low impact.
struct AppendFileTool: JarvisTool {
    let name = "append_file"
    let description = "Appends text to a file, creating it if necessary. Low-impact filesystem mutation."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: true, description: "File to append to"),
        ToolParameterSpec(name: "content", kind: .string, required: true, description: "Text to append")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty,
              let content = arguments["content"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Requires 'path' and 'content'")
        }
        let result = try await MainActor.run { () throws -> (resolved: String, beforeSize: Int, afterSize: Int) in
            let resolved = try FileManagerJarvis.shared.validatedWritablePath(path, operation: name)
            let before = FileSystemObserver.shared.observe(path: resolved).fileSize ?? 0
            if FileManager.default.fileExists(atPath: resolved), let handle = FileHandle(forWritingAtPath: resolved) {
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data(content.utf8))
            } else {
                try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            }
            let after = FileSystemObserver.shared.observe(path: resolved).fileSize ?? 0
            return (resolved, Int(before), Int(after))
        }
        return ToolResult(
            success: true,
            output: "Appended \(content.utf8.count) byte(s) to \(result.resolved)",
            sideEffects: ["file_appended"],
            metadata: ["path": result.resolved, "beforeSize": String(result.beforeSize),
                       "afterSize": String(result.afterSize)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let path = expected.metadata["path"], let before = Int(expected.metadata["beforeSize"] ?? "") else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no path recorded")
        }
        let state = FileSystemObserver.shared.observe(path: path)
        return ObservationResult(observations: [
            "exists": state.exists ? "true" : "false",
            "grew": ((state.fileSize ?? 0) > Int64(before)) ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("filesystem did not answer") }
        guard observed.observations["exists"] == "true", observed.observations["grew"] == "true" else {
            return .failed("file did not grow after append")
        }
        return .passed(reason: "file grew after append")
    }
}

/// Copy or move a path. Low impact. Both source and destination are validated.
struct MoveOrCopyPathTool: JarvisTool {
    let move: Bool
    var name: String { move ? "move_path" : "copy_path" }
    var description: String { "\(move ? "Moves or renames" : "Copies") a file or directory to a destination. Low-impact filesystem mutation." }
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "source", kind: .string, required: true, description: "Existing source path"),
        ToolParameterSpec(name: "destination", kind: .string, required: true, description: "Destination path")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let source = arguments["source"] as? String, !source.isEmpty,
              let destination = arguments["destination"] as? String, !destination.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Requires 'source' and 'destination'")
        }
        let operation = name
        let isMove = move
        let resolved = try await MainActor.run { () throws -> (src: String, dst: String) in
            let fm = FileManagerJarvis.shared
            guard !fm.isSensitivePath(source) else {
                throw JarvisError.commandBlocked(command: operation, reason: "Sensitive credential source is not movable")
            }
            let src = fm.resolvePath(source)
            let dst = try fm.validatedWritablePath(destination, operation: operation)
            guard FileManager.default.fileExists(atPath: src) else {
                throw JarvisError.actionFailed(action: operation, reason: "Source does not exist: \(source)")
            }
            guard !FileManager.default.fileExists(atPath: dst) else {
                throw JarvisError.actionFailed(action: operation, reason: "Destination already exists: \(destination)")
            }
            if isMove {
                try FileManager.default.moveItem(atPath: src, toPath: dst)
            } else {
                try FileManager.default.copyItem(atPath: src, toPath: dst)
            }
            return (src, dst)
        }
        return ToolResult(
            success: true,
            output: "\(move ? "Moved" : "Copied") \(resolved.src) → \(resolved.dst)",
            sideEffects: [move ? "path_moved" : "path_copied"],
            metadata: ["source": resolved.src, "destination": resolved.dst])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let dst = expected.metadata["destination"], let src = expected.metadata["source"] else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no paths recorded")
        }
        let destExists = FileManager.default.fileExists(atPath: dst)
        let sourceExists = FileManager.default.fileExists(atPath: src)
        return ObservationResult(observations: [
            "destinationExists": destExists ? "true" : "false",
            "sourceExists": sourceExists ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("filesystem did not answer") }
        guard observed.observations["destinationExists"] == "true" else {
            return .failed("destination was not created")
        }
        if move && observed.observations["sourceExists"] == "true" {
            return .failed("source still exists after move")
        }
        return .passed(reason: move ? "moved" : "copied")
    }
}

/// Exact, bounded text replacement inside a file.
///
/// Prefers an exact replacement over a blind global rewrite: by default only the
/// FIRST occurrence is replaced; `all` must be explicitly requested. The result
/// records before/after sizes and the number of replacements, and is verified by
/// reading the file back.
struct ReplaceInFileTool: JarvisTool {
    let name = "replace_in_file"
    let description = "Replaces an exact substring in a UTF-8 file. By default replaces only the first occurrence; set all=1 to replace every occurrence. Verified by read-back."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: true, description: "File to edit"),
        ToolParameterSpec(name: "find", kind: .string, required: true, description: "Exact text to find"),
        ToolParameterSpec(name: "replace", kind: .string, required: true, description: "Replacement text"),
        ToolParameterSpec(name: "all", kind: .int, required: false, description: "1 to replace every occurrence (default: first only)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty,
              let find = arguments["find"] as? String, !find.isEmpty,
              let replace = arguments["replace"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Requires non-empty 'path', 'find', and 'replace'")
        }
        let all = (arguments["all"] as? Int) == 1
        let operation = name
        let result = try await MainActor.run { () throws -> (resolved: String, before: String, after: String, count: Int) in
            let fm = FileManagerJarvis.shared
            let resolved = try fm.validatedWritablePath(path, operation: operation)
            let before = try fm.readFile(at: resolved)
            let occurrences = Self.countOccurrences(of: find, in: before)
            guard occurrences > 0 else {
                throw JarvisError.actionFailed(action: operation,
                                               reason: "'find' text was not present in the file")
            }
            let after = all
                ? before.replacingOccurrences(of: find, with: replace)
                : Self.replacingFirstOccurrence(of: find, with: replace, in: before)
            try fm.writeFile(at: resolved, content: after)
            let replaced = all ? occurrences : 1
            return (resolved, before, after, replaced)
        }
        return ToolResult(
            success: true,
            output: "Replaced \(result.count) occurrence(s) in \(result.resolved)",
            sideEffects: ["file_edited"],
            metadata: ["path": result.resolved,
                       "replacements": String(result.count),
                       "beforeLength": String(result.before.count),
                       "afterLength": String(result.after.count),
                       "expectedAfter": result.after])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let path = expected.metadata["path"], let expectedAfter = expected.metadata["expectedAfter"] else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no path recorded")
        }
        guard let actual = FileSystemObserver.shared.readText(path: path) else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "edited file could not be re-read")
        }
        return ObservationResult(observations: [
            "matches": actual == expectedAfter ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("filesystem did not answer") }
        guard observed.observations["matches"] == "true" else {
            return .failed("file content after edit does not match the expected replacement")
        }
        return .passed(reason: "edit verified by read-back")
    }

    static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    static func replacingFirstOccurrence(of needle: String, with replacement: String, in haystack: String) -> String {
        guard let range = haystack.range(of: needle) else { return haystack }
        return haystack.replacingCharacters(in: range, with: replacement)
    }
}

/// Deletes a file or directory. Irreversible: destructive impact (requires the
/// destructive/commit gate at the current autonomy level).
struct DeletePathTool: JarvisTool {
    let name = "delete_path"
    let description = "Deletes a file or directory. Irreversible; requires destructive-action authority."
    let impact: PermissionGate.ActionImpact = .destructive
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: true, description: "Path to delete")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'path'")
        }
        let resolved = try await MainActor.run {
            try FileManagerJarvis.shared.validatedWritablePath(path, operation: name)
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw JarvisError.actionFailed(action: name, reason: "No such path: \(path)")
        }
        try FileManager.default.removeItem(atPath: resolved)
        return ToolResult(success: true, output: "Deleted \(resolved)",
                          sideEffects: ["path_deleted"], metadata: ["path": resolved])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let path = expected.metadata["path"] else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no path recorded")
        }
        let exists = FileManager.default.fileExists(atPath: path)
        return ObservationResult(observations: ["exists": exists ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("filesystem did not answer") }
        guard observed.observations["exists"] == "false" else {
            return .failed("path still exists after delete")
        }
        return .passed(reason: "path removed")
    }
}
