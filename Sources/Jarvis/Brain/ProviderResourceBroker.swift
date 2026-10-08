import Foundation

// MARK: - Capacity policy

/// Configured, finite capacity for one provider.
///
/// Two kinds of limit are deliberately kept apart:
///   • **Concurrency** (`maxConcurrent`) is ZiA's *own* arbitration knob. It is
///     always finite and never claims to be a number the provider told us.
///   • **Windows** (`requestsPerMinute`, `tokensPerMinute`) are only enforced
///     when a value is actually known — configured, or observed from a
///     provider response. An unknown window stays `nil` and is never invented
///     (§5: a fabricated quota is worse than no quota).
struct ProviderCapacityPolicy: Sendable, Equatable {
    /// Maximum simultaneous in-flight requests to this provider.
    let maxConcurrent: Int
    /// Observed/configured requests-per-minute ceiling. nil = UNKNOWN.
    let requestsPerMinute: Int?
    /// Observed/configured tokens-per-minute ceiling. nil = UNKNOWN.
    let tokensPerMinute: Int?
    /// Cost class drives whether a budget reservation is required.
    let costClass: ProviderCostClass

    init(maxConcurrent: Int = ProviderCapacityPolicy.defaultMaxConcurrent,
         requestsPerMinute: Int? = nil,
         tokensPerMinute: Int? = nil,
         costClass: ProviderCostClass = .free) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.requestsPerMinute = requestsPerMinute.map { max(1, $0) }
        self.tokensPerMinute = tokensPerMinute.map { max(1, $0) }
        self.costClass = costClass
    }

    /// Default concurrency when nothing more specific is configured. Chosen so
    /// the broker is *on* by default (bounded, explainable) without pretending
    /// to know a provider's real server limit.
    static let defaultMaxConcurrent = 4

    /// Conservative per-provider default derived from the cost classification.
    /// Local models are single-process, so they admit one request at a time.
    static func `default`(for providerID: String) -> ProviderCapacityPolicy {
        let costClass = BudgetPolicy.costClass(for: providerID)
        let concurrency: Int
        if providerID.hasPrefix("mlx") {
            concurrency = 1
        } else {
            switch costClass {
            case .paid, .trial: concurrency = 2
            case .free, .local: concurrency = defaultMaxConcurrent
            }
        }
        return ProviderCapacityPolicy(maxConcurrent: concurrency, costClass: costClass)
    }
}

// MARK: - Request / reservation

/// A request for exclusive provider capacity. Budget facts are supplied by the
/// caller (it owns the authoritative spend and limit); the broker never invents
/// a dollar figure.
struct ProviderResourceRequest: Sendable {
    let providerID: String
    var priority: Int = TaskPriority.normal
    /// Estimated request size, used only for a configured/observed TPM window.
    var estimatedTokens: Int = 0
    /// Estimated spend, used only for a `paid` provider's budget reservation.
    var estimatedCostUSD: Double = 0
    /// Today's observed spend, as reported by the authoritative UsageManager.
    var spentTodayUSD: Double? = nil
    /// The authorised daily ceiling. nil = UNKNOWN (paid admission fails closed).
    var dailyLimitUSD: Double? = nil
    /// Provenance for diagnostics only.
    var taskID: UUID? = nil

    init(providerID: String, priority: Int = TaskPriority.normal,
         estimatedTokens: Int = 0, estimatedCostUSD: Double = 0,
         spentTodayUSD: Double? = nil, dailyLimitUSD: Double? = nil,
         taskID: UUID? = nil) {
        self.providerID = providerID
        self.priority = priority
        self.estimatedTokens = max(0, estimatedTokens)
        self.estimatedCostUSD = max(0, estimatedCostUSD)
        self.spentTodayUSD = spentTodayUSD
        self.dailyLimitUSD = dailyLimitUSD
        self.taskID = taskID
    }
}

/// A granted, exclusive claim on a provider slot. Release is idempotent and
/// double-release is rejected, so a scheduler bug can never silently corrupt
/// capacity accounting.
struct ProviderReservation: Sendable, Equatable, Identifiable {
    let id: UUID
    let providerID: String
    let priority: Int
    let estimatedCostUSD: Double
    let grantedAt: Date
}

// MARK: - Errors

/// Distinct, machine-classifiable admission failures (§24). Each maps to a
/// different scheduler response: reroute, defer, or reject.
enum ResourceBrokerError: LocalizedError, Equatable {
    /// The provider's budget is exhausted / not authorised. Reroute.
    case budgetDenied(reason: String)
    /// A configured/observed window is full. Reroute or defer.
    case quotaWindowExhausted(reason: String)
    /// The admission queue is full — bounded, never unbounded. Reject.
    case queueFull(capacity: Int)
    /// The waiter was cancelled before a slot was granted.
    case cancelledWhileWaiting
    /// A reservation id was not active (already released or never granted).
    case reservationNotActive(UUID)

    var errorDescription: String? {
        switch self {
        case .budgetDenied(let reason): return "budget denied: \(reason)"
        case .quotaWindowExhausted(let reason): return "quota window exhausted: \(reason)"
        case .queueFull(let capacity): return "admission queue full (capacity \(capacity))"
        case .cancelledWhileWaiting: return "cancelled while waiting for provider capacity"
        case .reservationNotActive(let id): return "reservation \(id.uuidString.prefix(8)) is not active"
        }
    }
}

// MARK: - Snapshot (diagnostics, §23)

/// Point-in-time, read-only view of the broker for logs and debug tooling.
/// Never rendered in the normal user UI.
struct ProviderResourceSnapshot: Sendable, Equatable {
    struct Provider: Sendable, Equatable {
        let providerID: String
        let inFlight: Int
        let maxConcurrent: Int
        let waiting: Int
        let requestsInWindow: Int
        let tokensInWindow: Int
        let requestsPerMinute: Int?
        let tokensPerMinute: Int?
        let reservedCostUSD: Double
        let observedRequestsRemaining: Double?
        let observedTokensRemaining: Double?
    }

    let providers: [Provider]
    let totalWaiting: Int
    let recentDecisions: [String]

    var providerIDs: [String] { providers.map(\.providerID) }
    func provider(_ id: String) -> Provider? { providers.first { $0.providerID == id } }
}

// MARK: - Broker

/// Central authority for every finite provider resource.
///
/// The broker owns exactly three things the rest of ZiA must not duplicate:
///   1. **Concurrency admission** — how many requests a provider may serve at
///      once, with a bounded, priority-aware, aging-fair wait queue.
///   2. **Budget reservation** — a `paid` provider may only run if the
///      estimated cost fits inside the authorised remaining budget. Reservations
///      are held for the in-flight duration, so two concurrent paid calls can
///      never both believe they fit.
///   3. **Window accounting** — requests/tokens per minute, enforced only when
///      a value is actually known.
///
/// It deliberately does NOT own health, quarantine, rate-limit cooldown, or the
/// fallback ordering — those stay with `ProviderManager`, the single source of
/// truth. The broker answers one question: "may this request run right now?"
actor ProviderResourceBroker {
    static let shared = ProviderResourceBroker()

    // MARK: Types

    private struct Waiter {
        let id: UUID
        let request: ProviderResourceRequest
        let sequence: Int
        let enqueuedAt: Date
        let continuation: CheckedContinuation<ProviderReservation, any Error>
    }

    private struct WindowEntry {
        let at: Date
        let tokens: Int
    }

    // MARK: Bounds (nothing here is unbounded — §29)

    /// Hard cap on queued admissions. A queue that can grow without limit is a
    /// resource leak with extra steps.
    static let maximumQueueDepth = 256
    /// Rolling window for RPM/TPM accounting.
    static let windowSeconds: TimeInterval = 60
    /// A waiter gains effective priority every this many seconds (aging), so a
    /// stream of higher-priority work cannot starve lower-priority work forever.
    static let agingIntervalSeconds: TimeInterval = 5
    /// Cap on the aging bonus, so it never overrides a genuinely urgent request.
    static let agingBonusCap = 20
    /// Bounded decision log kept for diagnostics.
    static let maximumDecisionLog = 64

    // MARK: State (actor-isolated)

    private var policies: [String: ProviderCapacityPolicy] = [:]
    private var inFlight: [String: Int] = [:]
    private var waiting: [Waiter] = []
    private var enqueueCounter = 0
    private var windows: [String: [WindowEntry]] = [:]
    /// Paid budget currently reserved by un-released reservations.
    private var reservedUSD: [String: Double] = [:]
    /// Observed quota (only ever populated from real provider signals).
    private var observedQuota: [String: ProviderQuota] = [:]
    /// Active reservation ids, so double-release and leaks are both detectable.
    private var activeReservations: [UUID: ProviderReservation] = [:]
    private var decisions: [String] = []
    private var clock: @Sendable () -> Date = { Date() }

    private init() {}

    // MARK: - Configuration

    /// Install a capacity policy for a provider. Unknown providers fall back to
    /// `ProviderCapacityPolicy.default(for:)`.
    func configure(_ policy: ProviderCapacityPolicy, for providerID: String) {
        policies[providerID] = policy
    }

    func policy(for providerID: String) -> ProviderCapacityPolicy {
        policies[providerID] ?? ProviderCapacityPolicy.default(for: providerID)
    }

    /// Override the clock so aging/window behaviour is deterministic in tests.
    func setClock(_ clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    /// Clear all broker state. Used by tests to guarantee isolation; production
    /// never needs it (the broker's state is self-healing on release).
    func resetForTesting() {
        policies.removeAll()
        inFlight.removeAll()
        for waiter in waiting {
            waiter.continuation.resume(throwing: ResourceBrokerError.cancelledWhileWaiting)
        }
        waiting.removeAll()
        enqueueCounter = 0
        windows.removeAll()
        reservedUSD.removeAll()
        observedQuota.removeAll()
        activeReservations.removeAll()
        decisions.removeAll()
        clock = { Date() }
    }

    // MARK: - Admission

    /// Atomically admit or defer a request. Throws a typed `ResourceBrokerError`
    /// when the request can never proceed under current policy (budget/window),
    /// and suspends (bounded, cancel-safe) when it must wait for a slot.
    func acquire(_ request: ProviderResourceRequest) async throws -> ProviderReservation {
        let now = clock()
        pruneWindows(now: now)

        let policy = policy(for: request.providerID)

        if let denial = budgetDenial(request, policy: policy) {
            recordDecision("DENY \(request.providerID) p\(request.priority): \(denial)")
            throw ResourceBrokerError.budgetDenied(reason: denial)
        }
        if let denial = windowDenial(request, policy: policy, now: now) {
            recordDecision("DENY \(request.providerID) p\(request.priority): \(denial)")
            throw ResourceBrokerError.quotaWindowExhausted(reason: denial)
        }

        if inFlight[request.providerID, default: 0] < policy.maxConcurrent {
            return grant(request, policy: policy, now: now)
        }

        guard waiting.count < Self.maximumQueueDepth else {
            recordDecision("REJECT \(request.providerID): admission queue full (\(Self.maximumQueueDepth))")
            throw ResourceBrokerError.queueFull(capacity: Self.maximumQueueDepth)
        }

        let waiterID = UUID()
        let sequence = nextSequence()
        recordDecision("QUEUE \(request.providerID) p\(request.priority) depth=\(waiting.count + 1)")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProviderReservation, any Error>) in
                // A task cancelled before we even parked must not leave a waiter.
                if Task.isCancelled {
                    continuation.resume(throwing: ResourceBrokerError.cancelledWhileWaiting)
                    return
                }
                waiting.append(Waiter(id: waiterID, request: request, sequence: sequence,
                                      enqueuedAt: clock(), continuation: continuation))
                // Capacity may have freed while this call was suspending.
                pump(now: clock())
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Release an exclusive slot. Idempotency is enforced (an inactive
    /// reservation is ignored with a diagnostic) so a double-release from a
    /// racing caller can never inflate capacity.
    func release(_ reservation: ProviderReservation) {
        guard activeReservations.removeValue(forKey: reservation.id) != nil else {
            recordDecision("RELEASE ignored \(reservation.providerID): reservation \(reservation.id.uuidString.prefix(8)) not active")
            return
        }
        let id = reservation.providerID
        inFlight[id] = max(0, inFlight[id, default: 1] - 1)
        if reservation.estimatedCostUSD > 0 {
            reservedUSD[id] = max(0, reservedUSD[id, default: 0] - reservation.estimatedCostUSD)
        }
        recordDecision("RELEASE \(id) inflight=\(inFlight[id, default: 0])")
        pump(now: clock())
    }

    /// Cancel every waiter queued for a provider (used when a provider is
    /// quarantined or the whole session is cancelled).
    func cancelWaiters(for providerID: String) {
        let doomed = waiting.filter { $0.request.providerID == providerID }
        guard !doomed.isEmpty else { return }
        waiting.removeAll { $0.request.providerID == providerID }
        for waiter in doomed {
            waiter.continuation.resume(throwing: ResourceBrokerError.cancelledWhileWaiting)
        }
        recordDecision("CANCEL \(doomed.count) waiter(s) for \(providerID)")
    }

    // MARK: - Observed quota

    /// Record a provider-reported quota signal. Absent/unknown signals must not
    /// be stored — an unknown stays unknown.
    func observeQuota(_ quota: ProviderQuota, for providerID: String) {
        guard quota.requestsRemaining.isKnown || quota.tokensRemaining.isKnown
                || quota.creditRemainingUSD.isKnown || quota.resetAt != nil else { return }
        observedQuota[providerID] = quota
        if quota.requestsRemaining.value == 0 || quota.tokensRemaining.value == 0 {
            recordDecision("OBSERVED \(providerID): quota exhausted (remaining requests=\(quota.requestsRemaining.value.map { String(Int($0)) } ?? "unknown"))")
        }
    }

    // MARK: - Diagnostics

    func snapshot() -> ProviderResourceSnapshot {
        let now = clock()
        pruneWindows(now: now)
        var ids = Set(policies.keys)
        ids.formUnion(inFlight.keys)
        ids.formUnion(windows.keys)
        ids.formUnion(waiting.map { $0.request.providerID })
        ids.formUnion(observedQuota.keys)
        let providers = ids.sorted().map { id -> ProviderResourceSnapshot.Provider in
            let policy = self.policy(for: id)
            let window = windows[id] ?? []
            let quota = observedQuota[id]
            return ProviderResourceSnapshot.Provider(
                providerID: id,
                inFlight: inFlight[id, default: 0],
                maxConcurrent: policy.maxConcurrent,
                waiting: waiting.filter { $0.request.providerID == id }.count,
                requestsInWindow: window.count,
                tokensInWindow: window.reduce(0) { $0 + $1.tokens },
                requestsPerMinute: policy.requestsPerMinute,
                tokensPerMinute: policy.tokensPerMinute,
                reservedCostUSD: reservedUSD[id, default: 0],
                observedRequestsRemaining: quota?.requestsRemaining.value,
                observedTokensRemaining: quota?.tokensRemaining.value)
        }
        return ProviderResourceSnapshot(providers: providers, totalWaiting: waiting.count,
                                        recentDecisions: decisions)
    }

    /// Convenience accessors used by tests and targeted assertions.
    func inFlightCount(for providerID: String) -> Int { inFlight[providerID, default: 0] }
    func waitingCount() -> Int { waiting.count }
    func waitingCount(for providerID: String) -> Int { waiting.filter { $0.request.providerID == providerID }.count }
    func reservedCost(for providerID: String) -> Double { reservedUSD[providerID, default: 0] }
    func activeReservationCount() -> Int { activeReservations.count }

    // MARK: - Private

    private func nextSequence() -> Int {
        enqueueCounter += 1
        return enqueueCounter
    }

    private func grant(_ request: ProviderResourceRequest, policy: ProviderCapacityPolicy,
                       now: Date) -> ProviderReservation {
        inFlight[request.providerID, default: 0] += 1
        windows[request.providerID, default: []].append(WindowEntry(at: now, tokens: request.estimatedTokens))
        let cost = policy.costClass == .paid ? max(0, request.estimatedCostUSD) : 0
        if cost > 0 { reservedUSD[request.providerID, default: 0] += cost }
        let reservation = ProviderReservation(id: UUID(), providerID: request.providerID,
                                              priority: request.priority, estimatedCostUSD: cost,
                                              grantedAt: now)
        activeReservations[reservation.id] = reservation
        recordDecision("GRANT \(request.providerID) p\(request.priority) inflight=\(inFlight[request.providerID, default: 0])/\(policy.maxConcurrent)")
        return reservation
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.continuation.resume(throwing: ResourceBrokerError.cancelledWhileWaiting)
        recordDecision("CANCEL waiter for \(waiter.request.providerID)")
        pump(now: clock())
    }

    /// Grant as many waiting requests as capacity allows, highest effective
    /// priority first (priority + bounded aging), FIFO within equal priority.
    private func pump(now: Date) {
        guard !waiting.isEmpty else { return }
        var progressed = true
        while progressed {
            progressed = false
            let ordered = waiting.indices.sorted { lhs, rhs in
                let lp = effectivePriority(waiting[lhs], now: now)
                let rp = effectivePriority(waiting[rhs], now: now)
                if lp != rp { return lp > rp }
                return waiting[lhs].sequence < waiting[rhs].sequence
            }
            for index in ordered {
                let waiter = waiting[index]
                let policy = policy(for: waiter.request.providerID)
                guard inFlight[waiter.request.providerID, default: 0] < policy.maxConcurrent else { continue }
                // Re-check budget at grant time: spend and/or reservations may
                // have changed while this waiter was queued.
                if let denial = budgetDenial(waiter.request, policy: policy) {
                    waiting.remove(at: index)
                    waiter.continuation.resume(throwing: ResourceBrokerError.budgetDenied(reason: denial))
                    recordDecision("DENY queued \(waiter.request.providerID): \(denial)")
                    progressed = true
                    break
                }
                if let denial = windowDenial(waiter.request, policy: policy, now: now) {
                    recordDecision("HOLD queued \(waiter.request.providerID): \(denial)")
                    continue
                }
                waiting.remove(at: index)
                let reservation = grant(waiter.request, policy: policy, now: now)
                waiter.continuation.resume(returning: reservation)
                progressed = true
                break
            }
        }
    }

    private func effectivePriority(_ waiter: Waiter, now: Date) -> Int {
        let waited = max(0, now.timeIntervalSince(waiter.enqueuedAt))
        let bonus = min(Int(waited / Self.agingIntervalSeconds), Self.agingBonusCap)
        return waiter.request.priority + bonus
    }

    private func budgetDenial(_ request: ProviderResourceRequest, policy: ProviderCapacityPolicy) -> String? {
        guard policy.costClass == .paid else { return nil }
        // Fail closed: a paid provider with an unknown spend or limit must not run.
        guard let limit = request.dailyLimitUSD else {
            return "paid provider has no known daily limit"
        }
        guard let spent = request.spentTodayUSD else {
            return "paid provider has no known observed spend"
        }
        let alreadyReserved = reservedUSD[request.providerID, default: 0]
        let projected = spent + alreadyReserved + request.estimatedCostUSD
        if projected > limit {
            return String(format: "estimated $%.4f would exceed daily limit $%.4f (spent $%.4f, reserved $%.4f)",
                          request.estimatedCostUSD, limit, spent, alreadyReserved)
        }
        return nil
    }

    private func windowDenial(_ request: ProviderResourceRequest, policy: ProviderCapacityPolicy,
                              now: Date) -> String? {
        let window = windows[request.providerID] ?? []
        if let rpm = policy.requestsPerMinute, window.count >= rpm {
            return "requests/minute ceiling reached (\(window.count)/\(rpm))"
        }
        if let tpm = policy.tokensPerMinute {
            let used = window.reduce(0) { $0 + $1.tokens }
            if used + request.estimatedTokens > tpm {
                return "tokens/minute ceiling reached (\(used)+\(request.estimatedTokens)/\(tpm))"
            }
        }
        if let quota = observedQuota[request.providerID], requestedWindowBlocked(quota, now: now) {
            return "provider reported quota exhausted"
        }
        return nil
    }

    /// Only a *server-observed* zero remaining, with a reset still in the
    /// future, blocks admission. An unknown quota never blocks.
    private func requestedWindowBlocked(_ quota: ProviderQuota, now: Date) -> Bool {
        if let reset = quota.resetAt, reset <= now { return false }
        if quota.requestsRemaining.value == 0 { return true }
        if quota.tokensRemaining.value == 0 { return true }
        return false
    }

    private func pruneWindows(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        for (id, entries) in windows {
            let kept = entries.filter { $0.at > cutoff }
            windows[id] = kept.isEmpty ? nil : kept
        }
    }

    private func recordDecision(_ text: String) {
        decisions.append(text)
        if decisions.count > Self.maximumDecisionLog {
            decisions.removeFirst(decisions.count - Self.maximumDecisionLog)
        }
    }
}
