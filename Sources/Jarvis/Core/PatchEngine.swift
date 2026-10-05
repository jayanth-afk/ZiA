import Foundation
import CryptoKit

/// How a patch selects the text it edits.
enum PatchScope: String, Sendable, Codable, CaseIterable {
    /// Replace the first exact occurrence of `find`.
    case firstOccurrence
    /// Replace every exact occurrence of `find`.
    case allOccurrences
    /// Replace the entire file content.
    case wholeFile
}

/// A first-class, auditable description of a single file edit.
///
/// The patch carries the intent (reason, author, task) and the expected prior
/// state (`expectedOldSHA256`), so a stale file is detected rather than
/// silently overwritten.
struct FilePatch: Sendable, Equatable {
    let target: String
    let find: String?
    let replacement: String
    let scope: PatchScope
    let reason: String
    let taskID: UUID?
    let author: String
    let createdAt: Date
    /// Optional SHA-256 of the file content the patch was authored against. When
    /// present, the patch refuses to apply if the file has changed.
    let expectedOldSHA256: String?

    init(
        target: String,
        find: String? = nil,
        replacement: String,
        scope: PatchScope = .firstOccurrence,
        reason: String,
        taskID: UUID? = nil,
        author: String = "zia",
        createdAt: Date = .now,
        expectedOldSHA256: String? = nil
    ) {
        self.target = target
        self.find = find
        self.replacement = replacement
        self.scope = scope
        self.reason = reason
        self.taskID = taskID
        self.author = author
        self.createdAt = createdAt
        self.expectedOldSHA256 = expectedOldSHA256
    }
}

enum PatchError: LocalizedError, Equatable {
    case unsafePath(String)
    case targetMissing(String)
    case noMatch(String)
    case staleFile(expected: String, actual: String)
    case conflict(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let p): return "Patch refused: path is not writable or is sensitive: \(p)"
        case .targetMissing(let p): return "Patch target does not exist: \(p)"
        case .noMatch(let f): return "Patch did not find the expected text: \(f)"
        case .staleFile(let e, let a): return "Patch refused: file changed since it was prepared (expected \(e), found \(a))"
        case .conflict(let r): return "Patch conflict: \(r)"
        case .ioFailure(let r): return "Patch I/O failure: \(r)"
        }
    }
}

/// A dry-run description of what a patch would do.
struct PatchPreview: Sendable, Equatable {
    let target: String
    let changed: Bool
    let replacements: Int
    let beforeLength: Int
    let afterLength: Int
    let beforeSHA256: String
    let summary: String
}

/// The outcome of applying a patch, including the backup needed to roll back.
struct PatchResult: Sendable, Equatable {
    let preview: PatchPreview
    let backupPath: String?
}

/// Deterministic, evidence-backed file editing.
///
/// Guarantees:
/// - Never silently overwrites changed content: an `expectedOldSHA256` mismatch
///   is a hard failure (stale detection).
/// - Never blind-replaces: the default scope is `.firstOccurrence`.
/// - Always writes atomically and keeps a backup so the edit can be rolled back.
/// - Never writes through the filesystem boundary: paths pass
///   `FileManagerJarvis.validatedWritablePath`.
@MainActor
enum PatchEngine {
    static let backupDirectoryName = "patch-backups"

    static func preview(_ patch: FilePatch) throws -> PatchPreview {
        let resolved = try resolveTarget(patch.target)
        guard let before = FileSystemObserver.shared.readText(path: resolved) else {
            throw PatchError.targetMissing(resolved)
        }
        try assertNotStale(patch, resolved: resolved, currentContent: before)
        let after = try applyScope(patch, to: before)
        let beforeHash = sha256(before)
        let changed = before != after
        let summary = "\(changed ? "changes" : "no change to") \(resolved): \(before.count) → \(after.count) chars"
        return PatchPreview(
            target: resolved, changed: changed,
            replacements: countReplacements(patch, in: before),
            beforeLength: before.count, afterLength: after.count,
            beforeSHA256: beforeHash, summary: summary)
    }

    static func apply(_ patch: FilePatch, now: Date = .now) throws -> PatchResult {
        let resolved = try resolveTarget(patch.target)
        guard let before = FileSystemObserver.shared.readText(path: resolved) else {
            throw PatchError.targetMissing(resolved)
        }
        try assertNotStale(patch, resolved: resolved, currentContent: before)
        let after = try applyScope(patch, to: before)
        let preview = PatchPreview(
            target: resolved, changed: before != after,
            replacements: countReplacements(patch, in: before),
            beforeLength: before.count, afterLength: after.count,
            beforeSHA256: sha256(before),
            summary: "\(resolved): \(before.count) → \(after.count) chars")

        guard preview.changed else {
            // No-op patch: nothing to write, no backup needed.
            return PatchResult(preview: preview, backupPath: nil)
        }

        let backupPath = try writeBackup(content: before, target: resolved, now: now)
        do {
            try FileManagerJarvis.shared.writeFile(at: resolved, content: after)
        } catch {
            throw PatchError.ioFailure(error.localizedDescription)
        }
        JarvisLogger.actions.info("Patch applied to \(resolved) by \(patch.author): \(patch.reason)")
        return PatchResult(preview: preview, backupPath: backupPath)
    }

    static func rollback(backupPath: String, target: String) throws {
        let resolved = try resolveTarget(target)
        guard let backup = FileSystemObserver.shared.readText(path: backupPath) else {
            throw PatchError.ioFailure("backup not found: \(backupPath)")
        }
        try FileManagerJarvis.shared.writeFile(at: resolved, content: backup)
    }

    // MARK: - Internals

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func resolveTarget(_ target: String) throws -> String {
        do {
            if FileManagerJarvis.shared.isSensitivePath(target) {
                throw PatchError.unsafePath(target)
            }
            return try FileManagerJarvis.shared.validatedWritablePath(target, operation: "patch")
        } catch let patchError as PatchError {
            throw patchError
        } catch {
            throw PatchError.unsafePath(target)
        }
    }

    private static func assertNotStale(_ patch: FilePatch, resolved: String, currentContent: String) throws {
        guard let expected = patch.expectedOldSHA256 else { return }
        let actual = sha256(currentContent)
        guard expected == actual else {
            throw PatchError.staleFile(expected: expected, actual: actual)
        }
    }

    private static func applyScope(_ patch: FilePatch, to content: String) throws -> String {
        switch patch.scope {
        case .wholeFile:
            return patch.replacement
        case .firstOccurrence, .allOccurrences:
            guard let find = patch.find, !find.isEmpty else {
                throw PatchError.noMatch("<empty find>")
            }
            guard content.range(of: find) != nil else {
                throw PatchError.noMatch(find)
            }
            if patch.scope == .allOccurrences {
                return content.replacingOccurrences(of: find, with: patch.replacement)
            }
            guard let range = content.range(of: find) else { throw PatchError.noMatch(find) }
            return content.replacingCharacters(in: range, with: patch.replacement)
        }
    }

    private static func countReplacements(_ patch: FilePatch, in content: String) -> Int {
        switch patch.scope {
        case .wholeFile:
            return 1
        case .allOccurrences, .firstOccurrence:
            guard let find = patch.find, !find.isEmpty else { return 0 }
            var count = 0
            var start = content.startIndex
            while let found = content.range(of: find, range: start..<content.endIndex) {
                count += 1
                start = found.upperBound
                if patch.scope == .firstOccurrence { break }
            }
            return count
        }
    }

    private static func writeBackup(content: String, target: String, now: Date) throws -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (target as NSString).lastPathComponent
        let backup = dir.appendingPathComponent("\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))-\(name)")
        do {
            try content.write(to: backup, atomically: true, encoding: .utf8)
            return backup.path
        } catch {
            throw PatchError.ioFailure("could not write backup: \(error.localizedDescription)")
        }
    }
}
