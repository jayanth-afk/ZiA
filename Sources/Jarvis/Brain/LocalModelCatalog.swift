import Foundation

/// Single source of truth for which local (MLX) models ZiA may use.
///
/// ZiA **never downloads a model at runtime**. A local model is only
/// "available" when its weights already exist in the local Hugging Face snapshot
/// cache. When a configured model is not cached, ZiA degrades honestly — it
/// falls back to a cached model, or reports the local model as unavailable —
/// instead of silently fetching gigabytes over the network.
///
/// This type is deliberately pure and injectable (`hub:` parameter) so the
/// resolution rules are deterministic and unit-testable without touching the
/// user's real cache.
enum LocalModelCatalog {

    /// The model cached with a ZiA development install and the one the local
    /// planner actually runs on today.
    static let defaultModelID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    /// Default minimum resolved weight size (bytes) for a directory to count as a
    /// loadable model. HF caches store weights as symlinks into a blob store, so
    /// the size is read from the resolved target.
    static let defaultMinimumWeightBytes = 1_000_000

    /// Root of the Hugging Face hub cache.
    static func defaultHubDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// A directory is a usable model snapshot when it contains `config.json` and
    /// at least one safetensors weight file of at least `minimumWeightBytes`
    /// (symlinks resolved).
    static func isUsableModelDirectory(_ url: URL, minimumWeightBytes: Int = defaultMinimumWeightBytes) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path) else { return false }
        let contents = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.contains { file in
            guard file.pathExtension == "safetensors" else { return false }
            let size = (try? file.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size >= minimumWeightBytes
        }
    }

    /// The usable snapshot directory for a model id, if cached. Prefers the
    /// revision named by `refs/main`, then the most recently modified snapshot.
    static func snapshotDirectory(for modelID: String, hub: URL? = nil,
                                  minimumWeightBytes: Int = defaultMinimumWeightBytes) -> URL? {
        let hub = hub ?? defaultHubDirectory()
        let repoDir = hub.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"))
        let refsMain = repoDir.appendingPathComponent("refs/main")
        if let revision = try? String(contentsOf: refsMain, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !revision.isEmpty {
            let snapshot = repoDir.appendingPathComponent("snapshots/\(revision)")
            if isUsableModelDirectory(snapshot, minimumWeightBytes: minimumWeightBytes) {
                return snapshot
            }
        }
        let snapshots = repoDir.appendingPathComponent("snapshots")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return contents
            .filter { $0.hasDirectoryPath && isUsableModelDirectory($0, minimumWeightBytes: minimumWeightBytes) }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .first
    }

    /// Whether a model id has a usable cached snapshot.
    static func isCached(_ modelID: String, hub: URL? = nil,
                         minimumWeightBytes: Int = defaultMinimumWeightBytes) -> Bool {
        snapshotDirectory(for: modelID, hub: hub, minimumWeightBytes: minimumWeightBytes) != nil
    }

    /// Every model id with a usable cached snapshot, sorted lexicographically.
    /// `models--<org>--<name>` becomes `<org>/<name>` (only the first `--`
    /// separator is rewritten, so ids containing `--` survive intact).
    static func cachedModelIDs(hub: URL? = nil,
                               minimumWeightBytes: Int = defaultMinimumWeightBytes) -> [String] {
        let hub = hub ?? defaultHubDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: hub, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("models--") }
            .compactMap { url -> String? in
                let withoutPrefix = String(url.lastPathComponent.dropFirst("models--".count))
                let id: String
                if let sep = withoutPrefix.range(of: "--") {
                    id = withoutPrefix.replacingCharacters(in: sep, with: "/")
                } else {
                    id = withoutPrefix
                }
                return isCached(id, hub: hub, minimumWeightBytes: minimumWeightBytes) ? id : nil
            }
            .sorted()
    }

    /// The model id ZiA will actually use for a slot.
    ///
    /// Order: the configured model if it is cached → the first cached local
    /// model → [`defaultModelID`]. The last case means "nothing cached": callers
    /// must check `isCached` before loading and fail closed instead of
    /// downloading.
    static func resolveModelID(configured: String?, hub: URL? = nil,
                               minimumWeightBytes: Int = defaultMinimumWeightBytes) -> String {
        if let configured, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isCached(configured, hub: hub, minimumWeightBytes: minimumWeightBytes) {
            return configured
        }
        if let first = cachedModelIDs(hub: hub, minimumWeightBytes: minimumWeightBytes).first {
            return first
        }
        return defaultModelID
    }
}
