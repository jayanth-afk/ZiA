import Foundation

/// Master router connecting DeterministicRouter -> IntentClassifier -> Local / Cloud Providers.
/// Measures microsecond latency at every stage using PipelineTimer.
@MainActor
final class BrainRouter {
    static let shared = BrainRouter()

    private init() {}

    // MARK: - Public API

    /// Route a transcript through the JARVIS brain pipeline.
    func route(_ transcript: String) async throws -> String {
        let response = try await AgentLoop.shared.run(goal: transcript)
        JarvisLogger.brain.info("BrainRouter completed query through the authoritative AgentLoop")
        return response
    }
}
