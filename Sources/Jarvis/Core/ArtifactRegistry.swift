import Foundation

/// What kind of thing a task produced.
enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case file
    case directory
    case report
    case codeChange
    case image
    case document
    case generatedOutput
    case other
}

/// A concrete thing a task created, tracked with provenance and verification
/// state so Zia can answer "what did you make, where, and is it verified?".
struct Artifact: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var path: String
    var kind: ArtifactKind
    var taskID: UUID?
    /// Who/what produced it (tool name, provider, user).
    var provenance: String
    var description: String
    let createdAt: Date
    /// Whether the artifact's existence was independently verified.
    var verified: Bool
    var verificationNote: String?
}

/// Thread-safe, bounded, durable registry of produced artifacts.
final class ArtifactRegistry: @unchecked Sendable {
    private final class Selection: @unchecked Sendable {
        let lock = NSLock()
        var testOverride: ArtifactRegistry?
    }
    private static let selection = Selection()
    private static let productionStore = ArtifactRegistry(storageURL: productionURL)

    static var shared: ArtifactRegistry {
        selection.lock.lock()
        defer { selection.lock.unlock() }
        return selection.testOverride ?? productionStore
    }

    @discardableResult
    static func beginIsolatedTesting() -> ArtifactRegistry? {
        let isolated = ArtifactRegistry(storageURL: nil)
        selection.lock.lock()
        defer { selection.lock.unlock() }
        let previous = selection.testOverride
        selection.testOverride = isolated
        return previous
    }

    static func endIsolatedTesting(restoring previous: ArtifactRegistry?) {
        selection.lock.lock()
        defer { selection.lock.unlock() }
        selection.testOverride = previous
    }

    private static var productionURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("artifacts.json", isDirectory: false)
    }

    static let maximumArtifacts = 1_000

    private let lock = NSLock()
    private var artifacts: [UUID: Artifact] = [:]
    private let storageURL: URL?
    private let persists: Bool

    init(storageURL: URL?) {
        self.storageURL = storageURL
        self.persists = storageURL != nil
        if let storageURL, let data = try? Data(contentsOf: storageURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            if let decoded = try? decoder.decode([Artifact].self, from: data) {
                for artifact in decoded { artifacts[artifact.id] = artifact }
            }
        }
    }

    @discardableResult
    func register(path: String, kind: ArtifactKind, provenance: String,
                  description: String, taskID: UUID? = nil, now: Date = .now) -> Artifact {
        let artifact = Artifact(
            id: UUID(), path: path, kind: kind, taskID: taskID,
            provenance: provenance, description: description,
            createdAt: now, verified: false, verificationNote: nil)
        lock.lock()
        artifacts[artifact.id] = artifact
        pruneLocked()
        lock.unlock()
        persist()
        return artifact
    }

    @discardableResult
    func markVerified(id: UUID, note: String?) -> Bool {
        lock.lock()
        guard var artifact = artifacts[id] else { lock.unlock(); return false }
        artifact.verified = true
        artifact.verificationNote = note
        artifacts[id] = artifact
        lock.unlock()
        persist()
        return true
    }

    func all() -> [Artifact] {
        lock.lock(); defer { lock.unlock() }
        return artifacts.values.sorted { $0.createdAt < $1.createdAt }
    }

    func artifacts(forTask taskID: UUID) -> [Artifact] {
        lock.lock(); defer { lock.unlock() }
        return artifacts.values.filter { $0.taskID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return artifacts.count
    }

    @discardableResult
    func forget(id: UUID) -> Bool {
        lock.lock()
        let removed = artifacts.removeValue(forKey: id) != nil
        lock.unlock()
        if removed { persist() }
        return removed
    }

    func clearAll() {
        lock.lock(); artifacts.removeAll(); lock.unlock()
        persist()
    }

    private func pruneLocked() {
        guard artifacts.count > Self.maximumArtifacts else { return }
        let ordered = artifacts.values.sorted { $0.createdAt < $1.createdAt }
        for artifact in ordered.prefix(artifacts.count - Self.maximumArtifacts) {
            artifacts.removeValue(forKey: artifact.id)
        }
    }

    private func persist() {
        guard persists, let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(all()) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}
