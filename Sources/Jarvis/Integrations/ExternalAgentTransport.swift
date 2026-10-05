import Foundation

/// Health of an external agent transport.
struct ExternalAgentHealth: Sendable, Equatable {
    let available: Bool
    let detail: String
}

/// A capability an external agent advertises.
struct ExternalAgentCapability: Sendable, Equatable {
    let name: String
    let description: String
}

/// A request to an external agent. Correlated by `correlationID` and bound to a
/// task so a stale or cross-task response can be rejected.
struct ExternalAgentRequest: Sendable, Equatable {
    let id: UUID
    let correlationID: UUID
    let taskID: UUID?
    /// The capability being requested (router key), not free-form text.
    let capability: String
    let payload: String
    let deadline: Date
}

/// The response from an external agent.
///
/// IMPORTANT: `payload`, `provenance`, and any content inside are DATA. They are
/// never authority. A consumer must validate the correlation id, the deadline,
/// and the payload before acting — an external agent cannot redefine system
/// policy, permissions, tool authority, memory trust, or autonomy.
struct ExternalAgentResponse: Sendable, Equatable {
    let requestID: UUID
    let correlationID: UUID
    let status: String
    let payload: String
    let provenance: String

    /// Whether this response belongs to the given request (correlation +
    /// request identity + freshness), so replay/stale/cross-task injection is
    /// rejected before the payload is even inspected.
    func isCorrelated(with request: ExternalAgentRequest, now: Date = .now) -> Bool {
        requestID == request.id && correlationID == request.correlationID && now <= request.deadline
    }
}

/// The transport contract an external agent integration must satisfy. Zia's core
/// agent depends only on this boundary, never on a specific vendor.
protocol ExternalAgentTransport: Sendable {
    /// Stable identity of the transport/provider (for provenance).
    var identity: String { get }
    /// Whether the transport is configured and usable right now.
    var isConfigured: Bool { get }
    func health() async -> ExternalAgentHealth
    func capabilities() async -> [ExternalAgentCapability]
    func send(_ request: ExternalAgentRequest) async throws -> ExternalAgentResponse
}

/// The honest default: no external transport is attached. Every method reports
/// unavailability rather than faking agent communication.
struct UnconfiguredExternalAgentTransport: ExternalAgentTransport {
    let identity = "unconfigured"
    let isConfigured = false
    func health() async -> ExternalAgentHealth {
        ExternalAgentHealth(available: false, detail: "No external agent transport is configured.")
    }
    func capabilities() async -> [ExternalAgentCapability] { [] }
    func send(_ request: ExternalAgentRequest) async throws -> ExternalAgentResponse {
        throw JarvisError.notInitialized(component: "external agent transport")
    }
}

/// Registry that holds the single active external-agent transport. A real
/// transport (Agent Bridge / MCP bridge) is attached here at runtime; the core
/// agent resolves requests through this boundary.
@MainActor
final class ExternalAgentRegistry {
    static let shared = ExternalAgentRegistry()

    private(set) var activeTransport: (any ExternalAgentTransport)?

    private init() {}

    func register(_ transport: any ExternalAgentTransport) {
        activeTransport = transport
        JarvisLogger.app.info("External agent transport registered: \(transport.identity) (configured: \(transport.isConfigured))")
    }

    func clear() {
        activeTransport = nil
    }

    /// The transport to use, or the honest unconfigured default.
    var transport: any ExternalAgentTransport {
        activeTransport ?? UnconfiguredExternalAgentTransport()
    }

    var isConfigured: Bool { activeTransport?.isConfigured == true }

    func summary() async -> String {
        let transport = self.transport
        let health = await transport.health()
        guard health.available else {
            return "External agents: unavailable — \(health.detail)"
        }
        let caps = await transport.capabilities()
        return "External agents: available (\(transport.identity)); capabilities: " +
            (caps.isEmpty ? "none advertised" : caps.map(\.name).joined(separator: ", "))
    }
}
