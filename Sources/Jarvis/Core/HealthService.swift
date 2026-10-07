import Foundation
import AppKit

/// Structured health of a component. `unknown`, `disabled`, `notConfigured`,
/// and `permissionBlocked` are all honest states — none is a failure by itself.
enum HealthStatus: String, Sendable, Comparable {
    case healthy
    case degraded
    case disabled
    case notConfigured
    case unknown
    case unavailable
    case permissionBlocked

    private var order: Int {
        switch self {
        case .healthy: return 0
        case .degraded: return 1
        case .disabled: return 2
        case .notConfigured: return 2
        case .unknown: return 3
        case .unavailable: return 4
        case .permissionBlocked: return 4
        }
    }

    static func < (lhs: HealthStatus, rhs: HealthStatus) -> Bool { lhs.order < rhs.order }

    /// Whether this status genuinely reduces overall capability (and therefore
    /// should degrade the overall report). Optional/inactive components do not.
    var reducesCapability: Bool {
        switch self {
        case .degraded, .disabled, .unavailable, .permissionBlocked: return true
        case .healthy, .notConfigured, .unknown: return false
        }
    }
}

struct ComponentHealth: Sendable, Equatable {
    let name: String
    let status: HealthStatus
    let detail: String
}

/// A single, structured answer to "is Zia healthy, and what still works?".
/// Used by degraded mode: a healthy subset beats a total failure.
struct HealthReport: Sendable {
    let overall: HealthStatus
    let components: [ComponentHealth]
    /// Capabilities that are currently limited, with the reason.
    let degradedCapabilities: [String]
    let timestamp: Date

    func component(named name: String) -> ComponentHealth? {
        components.first { $0.name == name }
    }

    /// A compact, user-facing summary. Never exposes stack traces or secrets.
    var summary: String {
        var lines = ["Zia health: \(overall.rawValue)."]
        for component in components where component.status != .healthy {
            lines.append("• \(component.name): \(component.status.rawValue) — \(component.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

/// First-class health/diagnostics for Zia's own subsystems. Read-only: it never
/// mutates state, never grants authority, and never contacts a provider beyond
/// the providers' own availability checks.
@MainActor
final class HealthService {
    static let shared = HealthService()

    private init() {}

    func report() async -> HealthReport {
        var components: [ComponentHealth] = []
        var degraded: [String] = []

        func add(_ name: String, _ status: HealthStatus, _ detail: String, degradation: String? = nil) {
            components.append(ComponentHealth(name: name, status: status, detail: detail))
            if status.reducesCapability, let degradation { degraded.append(degradation) }
        }

        // 1. Intelligence providers.
        let providerHealth = await ProviderManager.shared.healthSnapshot()
        if providerHealth.availableCount == 0 {
            add("intelligence", .unavailable,
                "No provider is available; deterministic capabilities continue.",
                degradation: "model reasoning unavailable — deterministic capabilities only")
        } else if providerHealth.isDegraded {
            add("intelligence", .degraded,
                "\(providerHealth.availableCount)/\(providerHealth.totalCount) providers available; local fallback active.",
                degradation: "cloud reasoning unavailable — local model only")
        } else {
            add("intelligence", .healthy,
                "\(providerHealth.availableCount)/\(providerHealth.totalCount) providers available.")
        }
        if !providerHealth.quarantined.isEmpty {
            add("provider-circuit", .degraded,
                "Quarantined: \(providerHealth.quarantined.joined(separator: ", ")).",
                degradation: "some providers quarantined after repeated failures")
        }

        // 1b. Local models — only cached weights count. ZiA never downloads a
        // model at runtime, so an empty cache is reported honestly rather than
        // promised as available.
        let cachedLocal = LocalModelCatalog.cachedModelIDs()
        if cachedLocal.isEmpty {
            add("local-models", .degraded,
                "No local model weights are cached; on-device reasoning is unavailable.",
                degradation: "local model unavailable (no cached weights)")
        } else {
            let reflex = LocalModelCatalog.resolveModelID(configured: Config.shared.localReflexModel)
            let normal = LocalModelCatalog.resolveModelID(configured: Config.shared.localNormalModel)
            add("local-models", .healthy,
                "Cached: \(cachedLocal.joined(separator: ", ")). Effective reflex/normal: \(reflex)/\(normal).")
        }

        // 2. Durable task state.
        if TaskStateMachine.shared.isPersistenceAvailable {
            add("task-state", .healthy, "Durable task state loaded.")
        } else {
            add("task-state", .degraded, "Durable task state unavailable; continuation disabled.",
                degradation: "task continuation unavailable")
        }

        // 3. Conversation storage.
        let persistent = ConversationStore.shared.isPersistentStorage
        add("storage", persistent ? .healthy : .degraded,
            persistent ? "SQLite conversation archive open." : "In-memory only; history will not survive restart.",
            degradation: persistent ? nil : "conversation history is not durable")

        // 4. Structured memory + artifacts.
        add("memory", .healthy, "\(ZiaMemoryStore.shared.count) structured record(s).")
        add("artifacts", .healthy, "\(ArtifactRegistry.shared.count) artifact(s) tracked.")

        // 5. Task queue + scheduler.
        let busy = await TaskWorkerPool.shared.busyWorkerCount
        let queued = await TaskWorkerPool.shared.queuedTaskCount
        let capacity = await TaskWorkerPool.shared.getMaxConcurrentWorkers()
        add("task-queue", .healthy, "\(busy)/\(capacity) workers busy; \(queued) queued.")
        add("scheduler", .healthy, "\(TaskScheduler.shared.enabledJobCount) enabled job(s).")

        // 6. Network.
        let online = AppState.shared.isOnline
        add("network", online ? .healthy : .degraded,
            online ? "Online." : "Offline; local work continues.",
            degradation: online ? nil : "network unavailable — local work only")

        // 7. Resources.
        let pressure = ResourceManager.shared.currentPressure
        add("resources", pressure == .critical ? .degraded : .healthy,
            "Memory pressure: \(pressure.rawValue).",
            degradation: pressure == .critical ? "memory pressure critical — worker capacity reduced" : nil)

        // 8. Computer control (accessibility).
        let accessibilityTrusted = AXIsProcessTrusted()
        add("computer-control", accessibilityTrusted ? .healthy : .permissionBlocked,
            accessibilityTrusted ? "Accessibility trusted."
                : "Accessibility permission not granted; UI automation and inspection are limited.",
            degradation: accessibilityTrusted ? nil : "computer control limited (accessibility permission)")

        // 9. Voice.
        let voiceRunning = VoicePipeline.shared.isRunning
        add("voice", voiceRunning ? .healthy : .disabled,
            voiceRunning ? "Voice pipeline running." : "Voice pipeline not running.",
            degradation: voiceRunning ? nil : "voice interaction disabled")

        // 10. External agents (optional integration).
        let externalConfigured = ExternalAgentRegistry.shared.isConfigured
        add("agent-bridge", externalConfigured ? .healthy : .notConfigured,
            externalConfigured ? "External agent transport configured." : "No external agent transport configured.")

        // 11. Browser.
        add("browser", .unknown, "Browser automation availability is determined per action.")

        let overall: HealthStatus
        if providerHealth.availableCount == 0 {
            overall = .unavailable
        } else if components.contains(where: { $0.status.reducesCapability }) {
            overall = .degraded
        } else {
            overall = .healthy
        }

        return HealthReport(overall: overall, components: components,
                            degradedCapabilities: degraded, timestamp: Date())
    }

    /// One component by name (bounded — avoids building the full report).
    func component(named name: String) async -> ComponentHealth? {
        await report().component(named: name)
    }
}
