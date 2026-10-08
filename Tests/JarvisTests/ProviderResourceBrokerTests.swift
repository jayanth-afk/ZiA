import Foundation
import Testing
@testable import Jarvis

/// Deterministic, network-free tests for the central provider resource broker.
///
/// These pin the concurrency, budget, quota-window, priority/fairness, and
/// cancellation guarantees the scheduler depends on. Every test installs a
/// private isolated broker (`beginIsolatedTesting`) so it never perturbs the
/// production singleton or another suite, and restores it on exit.
@MainActor
@Suite(.serialized) struct ProviderResourceBrokerTests {

    /// Bounded poll instead of a fixed sleep: proceed as soon as the actor
    /// reaches the expected state, and fail (not hang) if it never does.
    private func waitUntil(_ condition: @Sendable () async -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("waitUntil timed out after \(timeout)s")
    }

    private func request(_ id: String, priority: Int = TaskPriority.normal,
                         tokens: Int = 0, cost: Double = 0,
                         spent: Double? = nil, limit: Double? = nil) -> ProviderResourceRequest {
        ProviderResourceRequest(providerID: id, priority: priority, estimatedTokens: tokens,
                                estimatedCostUSD: cost, spentTodayUSD: spent, dailyLimitUSD: limit)
    }

    /// Run a body with a fresh, private broker. It never touches the production
    /// singleton, so parallel suites cannot interfere with these assertions.
    private func withIsolatedBroker(_ body: (ProviderResourceBroker) async throws -> Void) async rethrows {
        try await body(ProviderResourceBroker.makeIsolated())
    }

    // MARK: - 1. Concurrency admission

    @Test func capacityOneAdmitsOneAndQueuesTheSecond() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "cap-1")
            let first = try await broker.acquire(request("cap-1"))

            let second = LockedValue<ProviderReservation?>(nil)
            let waiter = Task { second.value = try? await broker.acquire(self.request("cap-1")) }
            await waitUntil { await broker.waitingCount(for: "cap-1") == 1 }

            #expect(await broker.inFlightCount(for: "cap-1") == 1)
            #expect(second.value == nil)

            await broker.release(first)
            await waitUntil { second.value != nil }
            #expect(second.value != nil)
            #expect(await broker.inFlightCount(for: "cap-1") == 1)

            if let s = second.value { await broker.release(s) }
            _ = await waiter.result
            #expect(await broker.inFlightCount(for: "cap-1") == 0)
            #expect(await broker.activeReservationCount() == 0)
        }
    }

    @Test func capacityTwoNeverExceedsTwoConcurrent() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 2), for: "cap-2")

            var held: [ProviderReservation] = []
            held.append(try await broker.acquire(request("cap-2")))
            held.append(try await broker.acquire(request("cap-2")))
            #expect(await broker.inFlightCount(for: "cap-2") == 2)

            let third = LockedValue<ProviderReservation?>(nil)
            let waiter = Task { third.value = try? await broker.acquire(self.request("cap-2")) }
            await waitUntil { await broker.waitingCount(for: "cap-2") == 1 }
            #expect(third.value == nil, "a third request must wait while two are in flight")

            await broker.release(held[0])
            await waitUntil { third.value != nil }
            #expect(await broker.inFlightCount(for: "cap-2") == 2)

            for reservation in held.dropFirst() { await broker.release(reservation) }
            if let t = third.value { await broker.release(t) }
            _ = await waiter.result
            #expect(await broker.activeReservationCount() == 0)
        }
    }

    // MARK: - 2. Budget reservation (paid providers)

    @Test func paidBudgetReservationNeverExceedsTheAuthorizedLimit() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 4, costClass: .paid), for: "paid-x")

            let first = try await broker.acquire(request("paid-x", cost: 0.6, spent: 0, limit: 1.0))
            #expect(await broker.reservedCost(for: "paid-x") == 0.6)

            await #expect(throws: ResourceBrokerError.self) {
                _ = try await broker.acquire(self.request("paid-x", cost: 0.6, spent: 0, limit: 1.0))
            }
            #expect(await broker.reservedCost(for: "paid-x") == 0.6,
                    "a denied reservation must never be counted as reserved")

            await broker.release(first)
            #expect(await broker.reservedCost(for: "paid-x") == 0)
            let again = try await broker.acquire(request("paid-x", cost: 0.6, spent: 0, limit: 1.0))
            await broker.release(again)
        }
    }

    @Test func paidProviderWithUnknownBudgetFailsClosed() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 4, costClass: .paid), for: "paid-unknown")
            await #expect(throws: ResourceBrokerError.self) {
                _ = try await broker.acquire(self.request("paid-unknown", cost: 0, spent: 0, limit: nil))
            }
            await #expect(throws: ResourceBrokerError.self) {
                _ = try await broker.acquire(self.request("paid-unknown", cost: 0, spent: nil, limit: 5))
            }
        }
    }

    @Test func trialReserveCannotBeDoubleSpent() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1, costClass: .trial), for: "reserve-x")
            let first = try await broker.acquire(request("reserve-x"))
            let second = LockedValue<ProviderReservation?>(nil)
            let waiter = Task { second.value = try? await broker.acquire(self.request("reserve-x")) }
            await waitUntil { await broker.waitingCount(for: "reserve-x") == 1 }
            #expect(second.value == nil)

            await broker.release(first)
            await waitUntil { second.value != nil }
            #expect(second.value != nil)
            if let s = second.value { await broker.release(s) }
            _ = await waiter.result
        }
    }

    // MARK: - 3. Quota windows (only when actually known)

    @Test func configuredRequestWindowAdmitsOnlyWithinLimit() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 8, requestsPerMinute: 1), for: "win-x")
            let first = try await broker.acquire(request("win-x"))
            await #expect(throws: ResourceBrokerError.self) {
                _ = try await broker.acquire(self.request("win-x"))
            }
            await broker.release(first)
            await #expect(throws: ResourceBrokerError.self) {
                _ = try await broker.acquire(self.request("win-x"))
            }
        }
    }

    @Test func unknownWindowIsNeverInvented() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 4), for: "no-window")
            var held: [ProviderReservation] = []
            for _ in 0..<4 { held.append(try await broker.acquire(request("no-window"))) }
            #expect(await broker.inFlightCount(for: "no-window") == 4)
            for reservation in held { await broker.release(reservation) }
        }
    }

    @Test func observedZeroQuotaBlocksUntilReset() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 4), for: "obs-x")
            let now = Date()
            await broker.observeQuota(
                ProviderQuota(requestsRemaining: .known(0), tokensRemaining: .unknown,
                              resetAt: now.addingTimeInterval(30)),
                for: "obs-x")
            await #expect(throws: ResourceBrokerError.self) {
                _ = try await broker.acquire(self.request("obs-x"))
            }
            await broker.observeQuota(
                ProviderQuota(requestsRemaining: .known(0), tokensRemaining: .unknown,
                              resetAt: now.addingTimeInterval(-1)),
                for: "obs-x")
            let reservation = try await broker.acquire(request("obs-x"))
            await broker.release(reservation)
        }
    }

    @Test func unknownQuotaSignalIsNotStored() async throws {
        try await withIsolatedBroker { broker in
            await broker.observeQuota(.unknown, for: "ghost-x")
            let snapshot = await broker.snapshot()
            #expect(snapshot.provider("ghost-x") == nil, "an all-unknown quota must not create state")
        }
    }

    // MARK: - 4. Priority + fairness

    @Test func highPriorityReceivesCapacityBeforeLowPriority() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "p1")
            let holder = try await broker.acquire(request("p1", priority: 0))

            let low = LockedValue<ProviderReservation?>(nil)
            let high = LockedValue<ProviderReservation?>(nil)
            let lowTask = Task { low.value = try? await broker.acquire(self.request("p1", priority: TaskPriority.backgroundMaintenance)) }
            await waitUntil { await broker.waitingCount(for: "p1") == 1 }
            let highTask = Task { high.value = try? await broker.acquire(self.request("p1", priority: TaskPriority.interactive)) }
            await waitUntil { await broker.waitingCount(for: "p1") == 2 }

            await broker.release(holder)
            await waitUntil { high.value != nil || low.value != nil }

            #expect(high.value != nil, "the interactive waiter must win the freed slot")
            #expect(low.value == nil, "the background waiter must still be queued")
            #expect(await broker.waitingCount(for: "p1") == 1)

            if let h = high.value { await broker.release(h) }
            await waitUntil { low.value != nil }
            if let l = low.value { await broker.release(l) }
            _ = await lowTask.result
            _ = await highTask.result
        }
    }

    @Test func equalPriorityIsStrictlyFIFO() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "fifo")
            let holder = try await broker.acquire(request("fifo"))
            let a = LockedValue<ProviderReservation?>(nil)
            let b = LockedValue<ProviderReservation?>(nil)
            let c = LockedValue<ProviderReservation?>(nil)
            let ta = Task { a.value = try? await broker.acquire(self.request("fifo")) }
            await waitUntil { await broker.waitingCount(for: "fifo") == 1 }
            let tb = Task { b.value = try? await broker.acquire(self.request("fifo")) }
            await waitUntil { await broker.waitingCount(for: "fifo") == 2 }
            let tc = Task { c.value = try? await broker.acquire(self.request("fifo")) }
            await waitUntil { await broker.waitingCount(for: "fifo") == 3 }

            await broker.release(holder)
            await waitUntil { a.value != nil }
            #expect(a.value != nil && b.value == nil && c.value == nil, "the earliest waiter goes first")

            if let ra = a.value { await broker.release(ra) }
            await waitUntil { b.value != nil }
            #expect(b.value != nil && c.value == nil)
            if let rb = b.value { await broker.release(rb) }
            await waitUntil { c.value != nil }
            if let rc = c.value { await broker.release(rc) }
            _ = await ta.result; _ = await tb.result; _ = await tc.result
        }
    }

    @Test func agingLetsAnOldWaiterEventuallyOutrankANewcomer() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "age")
            let now = LockedValue<Date>(Date(timeIntervalSince1970: 1_700_000_000))
            await broker.setClock { now.value }

            let holder = try await broker.acquire(request("age", priority: 0))
            let old = LockedValue<ProviderReservation?>(nil)
            let newcomer = LockedValue<ProviderReservation?>(nil)
            let oldTask = Task { old.value = try? await broker.acquire(self.request("age", priority: 10)) }
            await waitUntil { await broker.waitingCount(for: "age") == 1 }

            now.value = now.value.addingTimeInterval(100)

            let newcomerTask = Task { newcomer.value = try? await broker.acquire(self.request("age", priority: 20)) }
            await waitUntil { await broker.waitingCount(for: "age") == 2 }

            await broker.release(holder)
            await waitUntil { old.value != nil || newcomer.value != nil }
            #expect(old.value != nil, "aging must let a long-waiting waiter break starvation")

            if let r = old.value { await broker.release(r) }
            await waitUntil { newcomer.value != nil }
            if let r = newcomer.value { await broker.release(r) }
            _ = await oldTask.result; _ = await newcomerTask.result
        }
    }

    // MARK: - 5. Cancellation safety

    @Test func cancellationWhileWaitingRemovesTheWaiterCleanly() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "cancel-wait")
            let holder = try await broker.acquire(request("cancel-wait"))
            let waiter = Task { try await broker.acquire(self.request("cancel-wait")) }
            await waitUntil { await broker.waitingCount(for: "cancel-wait") == 1 }

            waiter.cancel()
            let result = await waiter.result
            #expect({
                if case .failure = result { return true }
                return false
            }(), "a cancelled waiter must fail, not receive a reservation")

            await waitUntil { await broker.waitingCount() == 0 }
            #expect(await broker.activeReservationCount() == 1, "only the holder's reservation remains")

            await broker.release(holder)
            #expect(await broker.activeReservationCount() == 0)
            #expect(await broker.inFlightCount(for: "cancel-wait") == 0, "no leaked slot")
        }
    }

    @Test func releaseIsIdempotentAndNeverInvertsCapacity() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "idem")
            let reservation = try await broker.acquire(request("idem"))
            await broker.release(reservation)
            await broker.release(reservation)
            #expect(await broker.inFlightCount(for: "idem") == 0)
            let again = try await broker.acquire(request("idem"))
            await broker.release(again)
        }
    }

    @Test func concurrentCancellationAndReleaseLeaveNoLeaks() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 2), for: "stress")
            var holders: [ProviderReservation] = []
            holders.append(try await broker.acquire(request("stress")))
            holders.append(try await broker.acquire(request("stress")))

            var waiters: [Task<Void, Never>] = []
            for _ in 0..<10 {
                let task = Task<Void, Never> {
                    if let reservation = try? await broker.acquire(self.request("stress")) {
                        await broker.release(reservation)
                    }
                }
                waiters.append(task)
            }
            await waitUntil { await broker.waitingCount() >= 8 }

            for (index, task) in waiters.enumerated() where index % 2 == 0 { task.cancel() }
            for reservation in holders { await broker.release(reservation) }
            for task in waiters { _ = await task.result }

            await waitUntil { await broker.waitingCount() == 0 }
            #expect(await broker.activeReservationCount() == 0, "no reservation may leak")
            #expect(await broker.inFlightCount(for: "stress") == 0, "no slot may leak")
        }
    }

    // MARK: - 6. Diagnostics

    @Test func snapshotExplainsStateTruthfully() async throws {
        try await withIsolatedBroker { broker in
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1, requestsPerMinute: 5, costClass: .paid), for: "diag")
            let reservation = try await broker.acquire(request("diag", cost: 0.1, spent: 0, limit: 5))

            let snapshot = await broker.snapshot()
            let provider = snapshot.provider("diag")
            #expect(provider?.inFlight == 1)
            #expect(provider?.maxConcurrent == 1)
            #expect(provider?.requestsPerMinute == 5)
            #expect(provider?.requestsInWindow == 1)
            #expect(provider?.reservedCostUSD == 0.1)
            #expect(!snapshot.recentDecisions.isEmpty)

            await broker.release(reservation)
        }
    }

    // MARK: - 7. Integration: the broker is on the real dispatch path

    /// A provider whose stream records how many calls overlap.
    actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var maxActive = 0
        func enter() { active += 1; maxActive = max(maxActive, active) }
        func exit() { active -= 1 }
    }

    actor GatedProvider: LLMProvider {
        nonisolated let id: String
        nonisolated let capabilities: Set<Capability> = [.textGeneration]
        nonisolated let currentLatencyMs = 1
        private let probe: ConcurrencyProbe

        init(id: String, probe: ConcurrencyProbe) { self.id = id; self.probe = probe }

        var isAvailable: Bool { get async { true } }
        func verifiedAvailability(probe: Bool) async -> ProviderAvailability { .available }

        func complete(messages: [Message], tools: [ToolDefinition]?, stream: Bool)
            -> AsyncThrowingStream<StreamChunk, any Error> {
            let probe = self.probe
            return AsyncThrowingStream { continuation in
                let task = Task {
                    await probe.enter()
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    await probe.exit()
                    continuation.yield(.text("ok"))
                    continuation.yield(.done(usage: .zero))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// A provider that never emits; it only ends when its stream is cancelled.
    actor HangingProvider: LLMProvider {
        nonisolated let id: String
        nonisolated let capabilities: Set<Capability> = [.textGeneration]
        nonisolated let currentLatencyMs = 1
        init(id: String) { self.id = id }

        var isAvailable: Bool { get async { true } }
        func verifiedAvailability(probe: Bool) async -> ProviderAvailability { .available }

        func complete(messages: [Message], tools: [ToolDefinition]?, stream: Bool)
            -> AsyncThrowingStream<StreamChunk, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    continuation.finish(throwing: CancellationError())
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    @Test func cancellationDuringDispatchDoesNotFallBackOrLeak() async throws {
        try await withIsolatedBroker { broker in
            let hanging = HangingProvider(id: "hang-1")
            let fallbackProbe = ConcurrencyProbe()
            let fallback = GatedProvider(id: "fb-1", probe: fallbackProbe)
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "hang-1")

            let task = Task {
                try await ProviderManager.shared.executeFallbackChain(
                    [hanging, fallback],
                    messages: [Message(role: .user, content: "x")], broker: broker)
            }
            await waitUntil { await broker.inFlightCount(for: "hang-1") == 1 }

            task.cancel()
            let result = await task.result
            if case .failure(let error) = result {
                #expect(error is CancellationError, "a cancelled turn must surface cancellation")
            } else {
                Issue.record("a cancelled dispatch must fail, not return a fallback answer")
            }
            // The fallback worker must never have been reached, and no slot leaked.
            #expect(await fallbackProbe.maxActive == 0)
            #expect(await broker.activeReservationCount() == 0)
            #expect(await broker.inFlightCount(for: "hang-1") == 0)
        }
    }

    @Test func concurrentExecutionsRespectTheBrokerSlotLimit() async throws {
        try await withIsolatedBroker { broker in
            let probe = ConcurrencyProbe()
            let provider = GatedProvider(id: "gated-1", probe: probe)
            await broker.configure(ProviderCapacityPolicy(maxConcurrent: 1), for: "gated-1")

            async let first = ProviderManager.shared.executeFallbackChain(
                [provider], messages: [Message(role: .user, content: "a")], broker: broker)
            async let second = ProviderManager.shared.executeFallbackChain(
                [provider], messages: [Message(role: .user, content: "b")], broker: broker)
            async let third = ProviderManager.shared.executeFallbackChain(
                [provider], messages: [Message(role: .user, content: "c")], broker: broker)

            _ = try await (first, second, third)

            #expect(await probe.maxActive == 1,
                    "a single-slot provider must never serve two requests at once")
            #expect(await broker.activeReservationCount() == 0,
                    "every reservation must be released after dispatch")
        }
    }
}
