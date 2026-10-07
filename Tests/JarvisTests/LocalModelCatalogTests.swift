import Foundation
import Testing
@testable import Jarvis

/// The local model catalog is the single source of truth for which MLX models
/// ZiA may load. These tests prove that (a) resolution never selects an uncached
/// model, (b) the config defaults name the cached model, and (c) the cache scan
/// is honest about what is actually on disk.
@Suite struct LocalModelCatalogTests {

    // MARK: - Helpers

    /// Build a synthetic Hugging Face hub cache in a temporary directory.
    /// `repos` maps a model id (e.g. `org/name`) to whether it should contain a
    /// usable snapshot.
    private func makeHub(_ repos: [String: Bool]) throws -> URL {
        let fm = FileManager.default
        let hub = fm.temporaryDirectory.appendingPathComponent("zia-hub-\(UUID().uuidString)")
        try fm.createDirectory(at: hub, withIntermediateDirectories: true)
        for (id, usable) in repos {
            let repoDir = hub.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"))
            let snapshot = repoDir.appendingPathComponent("snapshots/rev1")
            try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try fm.createDirectory(at: repoDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try "rev1".write(to: repoDir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
            if usable {
                try "{}".write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
                try Data(count: 8).write(to: snapshot.appendingPathComponent("model.safetensors"))
            }
        }
        return hub
    }

    // MARK: - Defaults

    @Test func defaultModelIsTheCachedPlannerModel() {
        #expect(LocalModelCatalog.defaultModelID == "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    }

    @Test @MainActor
    func configDefaultsUseTheCachedModelConstant() {
        // The stored defaults must never name an uncached model. When nothing is
        // explicitly configured, both slots resolve to the catalog default.
        if Config.shared.modelName(for: "reflex") == nil {
            #expect(Config.shared.localReflexModel == LocalModelCatalog.defaultModelID)
        }
        if Config.shared.modelName(for: "normal") == nil {
            #expect(Config.shared.localNormalModel == LocalModelCatalog.defaultModelID)
        }
        #expect(!Config.shared.localReflexModel.isEmpty)
        #expect(!Config.shared.localNormalModel.isEmpty)
    }

    // MARK: - Cache detection

    @Test func detectsUsableCachedSnapshot() throws {
        let hub = try makeHub(["org/name": true])
        defer { try? FileManager.default.removeItem(at: hub) }
        #expect(LocalModelCatalog.isCached("org/name", hub: hub, minimumWeightBytes: 4))
        #expect(LocalModelCatalog.snapshotDirectory(for: "org/name", hub: hub, minimumWeightBytes: 4) != nil)
    }

    @Test func rejectsMissingWeightsAndMissingRepo() throws {
        let hub = try makeHub(["org/empty": false])
        defer { try? FileManager.default.removeItem(at: hub) }
        // A repo directory without a real weight file is not usable...
        #expect(!LocalModelCatalog.isCached("org/empty", hub: hub, minimumWeightBytes: 4))
        // ...and a model that is not present at all is not usable either.
        #expect(!LocalModelCatalog.isCached("org/absent", hub: hub, minimumWeightBytes: 4))
    }

    @Test func cachedModelIDsRewritesOnlyTheFirstSeparator() throws {
        let hub = try makeHub(["org/name--suffix": true, "other/x": true])
        defer { try? FileManager.default.removeItem(at: hub) }
        let ids = LocalModelCatalog.cachedModelIDs(hub: hub, minimumWeightBytes: 4)
        #expect(ids == ["org/name--suffix", "other/x"])
    }

    @Test func emptyCacheReportsNoModels() throws {
        let hub = try makeHub([:])
        defer { try? FileManager.default.removeItem(at: hub) }
        #expect(LocalModelCatalog.cachedModelIDs(hub: hub, minimumWeightBytes: 4).isEmpty)
    }

    // MARK: - Resolution (never downloads)

    @Test func resolvesConfiguredModelWhenCached() throws {
        let hub = try makeHub(["org/big": true, "org/small": true])
        defer { try? FileManager.default.removeItem(at: hub) }
        #expect(LocalModelCatalog.resolveModelID(configured: "org/big", hub: hub, minimumWeightBytes: 4) == "org/big")
    }

    @Test func fallsBackToCachedModelWhenConfiguredIsNotCached() throws {
        let hub = try makeHub(["org/cached": true])
        defer { try? FileManager.default.removeItem(at: hub) }
        // A configured, uncached model (e.g. qwen2.5-7b) must never be selected.
        #expect(LocalModelCatalog.resolveModelID(configured: "qwen2.5-7b", hub: hub, minimumWeightBytes: 4) == "org/cached")
        #expect(LocalModelCatalog.resolveModelID(configured: "", hub: hub, minimumWeightBytes: 4) == "org/cached")
    }

    @Test func emptyCacheResolvesToDefaultWhichIsNotCached() throws {
        let hub = try makeHub([:])
        defer { try? FileManager.default.removeItem(at: hub) }
        let resolved = LocalModelCatalog.resolveModelID(configured: "qwen2.5-7b", hub: hub, minimumWeightBytes: 4)
        #expect(resolved == LocalModelCatalog.defaultModelID)
        // The guard MLXProvider relies on: nothing cached means the load fails
        // closed rather than downloading.
        #expect(!LocalModelCatalog.isCached(resolved, hub: hub, minimumWeightBytes: 4))
    }
}
