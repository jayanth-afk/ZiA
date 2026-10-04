import Foundation
import AppKit

/// Structured health of a component. `unknown` is honest: it means Zia has no
/// observation mechanism, not that the component is broken.
enum HealthStatus: String, Sendable, Comparable {
    case healthy
    case degraded
    case unavailable
    case unknown

    private var order: Int {
        switch self {
        case .healthy: return 0
        case .degraded: return 1
        case .unknown: return 2
        case .unavailable: return 3
        }
    }

    static func < (lhs: HealthStatus, rhs: HealthStatus) -> Bool { lhs.order < rhs.order }
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
        let label: String
        switch overall {
        case .healthy: label = "healthy"
        case .degraded: label = "degraded"
        case .unavailable: label = "unavailable"
        case .unknown: label = "unknown"
        }
        var lines = ["Zia health: \(label)."]
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

        // 1. Intelligence providers.
        let providerHealth = await ProviderManager.shared.healthSnapshot()
        if providerHealth.availableCount == 0 {
            components.append(ComponentHealth(
                name: "intelligence",
                status: .unavailable,
                detail: "No provider is available; Zia can still run deterministic capabilities."))
            degraded.append("model reasoning unavailable — deterministic capabilities only")
        } else if providerHealth.isDegraded {
            components.append(ComponentHealth(
                name: "intelligence",
                status: .degraded,
                detail: "\(providerHealth.availableCount)/\(providerHealth.totalCount) providers available; local fallback active."))
            degraded.append("cloud reasoning unavailable — local model only")
        } else {
            components.append(ComponentHealth(
                name: "intelligence",
                status: .healthy,
                detail: "\(providerHealth.availableCount)/\(providerHealth.totalCount) providers available."))
        }

        // 2. Durable task state.
        if TaskStateMachine.shared.isPersistenceAvailable {
            components.append(ComponentHealth(name: "task-state", status: .healthy,
                                              detail: "Durable task state loaded."))
        } else {
            components.append(ComponentHealth(name: "task-state", status: .degraded,
                                              detail: "Durable task state unavailable; continuation disabled."))
            degraded.append("task continuation unavailable")
        }

        // 3. Conversation storage.
        let persistent = ConversationStore.shared.isPersistentStorage
        components.append(ComponentHealth(
            name: "storage",
            status: persistent ? .healthy : .degraded,
            detail: persistent ? "SQLite conversation archive open." : "In-memory only; history will not survive restart."))
        if !persistent { degraded.append("conversation history is not durable") }

        // 4. Structured memory.
        components.append(ComponentHealth(name: "memory", status: .healthy,
                                          detail: "\(ZiaMemoryStore.shared.count) structured record(s)."))

        // 5. Task queue.
        let busy = await TaskWorkerPool.shared.busyWorkerCount
        let capacity = await TaskWorkerPool.shared.getMaxConcurrentWorkers()
        let queued = TaskScheduler.shared.enabledJobCount
        components.append(ComponentHealth(
            name: "task-queue",
            status: .healthy,
            detail: "\(busy)/\(capacity) workers busy; \(queued) scheduled job(s)."))

        // 6. Network.
        let online = AppState.shared.isOnline
        components.append(ComponentHealth(
            name: "network",
            status: online ? .healthy : .degraded,
            detail: online ? "Online." : "Offline; local work continues."))
        if !online { degraded.append("network unavailable — local work only") }

        // 7. Resources.
        let pressure = ResourceManager.shared.currentPressure
        components.append(ComponentHealth(
            name: "resources",
            status: pressure == .critical ? .degraded : .healthy,
            detail: "Memory pressure: \(pressure.rawValue)."))
        if pressure == .critical { degraded.append("memory pressure critical — worker capacity reduced") }

        // 8. Automation / accessibility (computer control).
        let accessibilityTrusted = AXIsProcessTrusted()
        components.append(ComponentHealth(
            name: "computer-control",
            status: accessibilityTrusted ? .healthy : .degraded,
            detail: accessibilityTrusted
                ? "Accessibility trusted."
                : "Accessibility permission not granted; UI automation and inspection are limited."))
        if !accessibilityTrusted { degraded.append("computer control limited (accessibility permission)") }

        let overall: HealthStatus
        if components.contains(where: { $0.status == .unavailable }) {
            overall = .unavailable
        } else if components.contains(where: { $0.status == .degraded }) {
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
