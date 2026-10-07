import Foundation

/// Verified availability of an AI provider (N1).
///
/// The core rule this type enforces: **a configured API key is NOT "usable".**
/// A provider may only be reported `.available` once something has actually
/// confirmed it. A provider that is merely configured (a key exists, or the
/// network is up) is `.unverified` — never `.available`.
///
/// The states are deliberately distinct so every consumer can be truthful:
///   • `.available`   — confirmed usable right now.
///   • `.unverified`  — configured, but usability was not confirmed this cycle.
///                      Callers must never present this as verified-available.
///   • `.unavailable` — proven unusable, with the exact reason.
public enum ProviderAvailability: Sendable, Equatable {
    case available
    case unverified(reason: String)
    case unavailable(reason: String)

    /// Upper bound for any single network availability probe. A probe must never
    /// stall a health check or a UI refresh.
    public static let probeTimeout: TimeInterval = 5

    /// Verified usable — the only truthful green state.
    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Usable-enough to remain a routing candidate: verified, or configured but
    /// not yet probed. Never true once a probe proved the provider unusable.
    public var isUsable: Bool {
        switch self {
        case .available, .unverified: return true
        case .unavailable: return false
        }
    }

    /// Exact reason when the provider is not verified-available.
    public var reason: String? {
        switch self {
        case .available: return nil
        case .unverified(let reason), .unavailable(let reason): return reason
        }
    }

    /// Stable machine label for logs, decision records, and settings.
    public var label: String {
        switch self {
        case .available: return "available"
        case .unverified: return "unverified"
        case .unavailable: return "unavailable"
        }
    }
}

/// Bounded, injectable cache for verified availability.
///
/// Availability probes touch the network, so their result is cached with a TTL
/// (default ~10 minutes, per N1) and served from here on the hot path. The clock
/// is a parameter so expiry is unit-testable without a real timer.
struct ProviderAvailabilityCache: Sendable {
    struct Entry: Sendable {
        let availability: ProviderAvailability
        let checkedAt: Date
    }

    /// N1: verified availability is cached for ~10 minutes.
    static let defaultTTL: TimeInterval = 600

    private(set) var entries: [String: Entry] = [:]
    let ttl: TimeInterval

    init(ttl: TimeInterval = ProviderAvailabilityCache.defaultTTL) {
        self.ttl = ttl
    }

    /// The fresh cached value, or nil when absent/expired.
    func value(for providerID: String, now: Date = .now) -> ProviderAvailability? {
        guard let entry = entries[providerID] else { return nil }
        guard now.timeIntervalSince(entry.checkedAt) < ttl else { return nil }
        return entry.availability
    }

    mutating func store(_ availability: ProviderAvailability, for providerID: String, now: Date = .now) {
        entries[providerID] = Entry(availability: availability, checkedAt: now)
    }

    mutating func invalidate(_ providerID: String) { entries[providerID] = nil }

    mutating func invalidateAll() { entries.removeAll() }
}
