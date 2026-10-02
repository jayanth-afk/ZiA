import Foundation

/// Safe, sandboxed file manager operations for JARVIS.
/// Enforces path boundary restrictions to prevent modifications to system directories.
@MainActor
final class FileManagerJarvis {
    static let shared = FileManagerJarvis()

    private let fileManager = FileManager.default

    // System directories that cannot be written or deleted
    private let blockedSystemPrefixes = [
        "/System",
        "/Library",
        "/usr",
        "/bin",
        "/sbin",
        "/private",
        "/etc",
        "/var"
    ]

    // Sensitive credential subpaths that cannot be read
    private let blockedReadSensitiveSubpaths = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".config/gcloud",
        ".env",
        ".netrc",
        ".zsh_history",
        ".bash_history"
    ]

    private init() {}

    // MARK: - Public API

    /// List directory contents at a path (or user home if empty).
    func listDirectory(at path: String = "~") throws -> [String] {
        let resolved = resolvePath(path)
        guard fileManager.fileExists(atPath: resolved) else {
            throw JarvisError.actionFailed(action: "listDirectory", reason: "Directory does not exist at: \(path)")
        }

        do {
            let items = try fileManager.contentsOfDirectory(atPath: resolved)
            return items.filter { !$0.hasPrefix(".") } // Skip hidden files by default
        } catch {
            throw JarvisError.actionFailed(action: "listDirectory", reason: error.localizedDescription)
        }
    }

    /// Read text content from a file.
    func readFile(at path: String) throws -> String {
        let resolved = resolvePath(path)
        let lower = resolved.lowercased()
        for subpath in blockedReadSensitiveSubpaths {
            if lower.contains(subpath) {
                JarvisLogger.security.fault("Blocked sensitive file read on \(resolved)")
                throw JarvisError.commandBlocked(
                    command: "readFile",
                    reason: "Reading sensitive credentials file '\(subpath)' is forbidden"
                )
            }
        }
        guard fileManager.fileExists(atPath: resolved) else {
            throw JarvisError.actionFailed(action: "readFile", reason: "File not found: \(path)")
        }

        do {
            return try String(contentsOfFile: resolved, encoding: .utf8)
        } catch {
            throw JarvisError.actionFailed(action: "readFile", reason: error.localizedDescription)
        }
    }

    /// Write content to a file with system safety checks.
    func writeFile(at path: String, content: String) throws -> String {
        let resolved = resolvePath(path)
        try validateSafePath(resolved, operation: "writeFile")

        do {
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            JarvisLogger.actions.info("File written: \(resolved)")
            return "File saved to \(path)"
        } catch {
            throw JarvisError.actionFailed(action: "writeFile", reason: error.localizedDescription)
        }
    }

    /// Delete a file safely.
    func deleteFile(at path: String) throws -> String {
        let resolved = resolvePath(path)
        try validateSafePath(resolved, operation: "deleteFile")

        guard fileManager.fileExists(atPath: resolved) else {
            return "File does not exist: \(path)"
        }

        do {
            try fileManager.removeItem(atPath: resolved)
            JarvisLogger.actions.info("File removed: \(resolved)")
            return "Deleted \(path)"
        } catch {
            throw JarvisError.actionFailed(action: "deleteFile", reason: error.localizedDescription)
        }
    }

    /// Get items on Desktop.
    func getDesktopFiles() throws -> [String] {
        return try listDirectory(at: "~/Desktop")
    }

    /// Get items in Downloads.
    func getDownloadsFiles() throws -> [String] {
        return try listDirectory(at: "~/Downloads")
    }

    // MARK: - Path Resolution & Safety

    func resolvePath(_ path: String) -> String {
        return (path as NSString).expandingTildeInPath
    }

    private func validateSafePath(_ resolvedPath: String, operation: String) throws {
        let standardized = URL(fileURLWithPath: resolvedPath).standardizedFileURL
        // Resolve the existing parent separately. Foundation does not reliably
        // resolve a symlink when the final destination leaf does not exist yet.
        let canonical: String
        if fileManager.fileExists(atPath: standardized.path) {
            canonical = standardized.resolvingSymlinksInPath().path
        } else {
            let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            canonical = parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL.path
        }
        // Sensitive credential locations must never be written or deleted, even
        // via a symlink that resolves into them. Plan-time validation already
        // forbids these paths; this is the execution-boundary parity check so a
        // directly-invoked caller cannot bypass it.
        let canonicalLower = canonical.lowercased()
        if let sensitive = blockedReadSensitiveSubpaths.first(where: { canonicalLower.contains("/" + $0) }) {
            JarvisLogger.security.fault("Blocked unsafe file operation \(operation) on sensitive path \(canonical)")
            throw JarvisError.commandBlocked(
                command: operation,
                reason: "Modifying sensitive path '\(sensitive)' is forbidden"
            )
        }

        guard let protectedRoot = blockedSystemPrefixes.first(where: { root in
            canonical == root || canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else { return }

        JarvisLogger.security.fault("Blocked unsafe file operation \(operation) on \(canonical)")
        throw JarvisError.commandBlocked(
            command: operation,
            reason: "Modifying protected system path '\(protectedRoot)' is forbidden"
        )
    }

    /// Used by deterministic tests and callers that need a normalized path
    /// after the same symlink-aware safety check as writes and deletes.
    func validatedWritablePath(_ path: String, operation: String = "writeFile") throws -> String {
        let resolved = resolvePath(path)
        try validateSafePath(resolved, operation: operation)
        return URL(fileURLWithPath: resolved).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
