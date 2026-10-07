import Foundation
import Testing
@testable import Jarvis

/// A dedicated `URLProtocol` stub. It is deliberately a *different* class from
/// `MockURLProtocol` (in `GroqProviderTests`) so this suite can run concurrently
/// with others without sharing mutable handler state. No network is used.
final class AvailabilityMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = AvailabilityMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// N1: verified provider availability. A configured API key is NOT "usable";
/// verified availability is cached (~10 min) and probes are bounded.
@Suite(.serialized) struct ProviderAvailabilityTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvailabilityMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func isUnverified(_ availability: ProviderAvailability) -> Bool {
        if case .unverified = availability { return true }
        return false
    }

    // MARK: - Tri-state semantics

    @Test func availableIsTheOnlyGreenState() {
        #expect(ProviderAvailability.available.isAvailable)
        #expect(ProviderAvailability.available.isUsable)
        #expect(ProviderAvailability.available.reason == nil)
        #expect(ProviderAvailability.available.label == "available")

        let unverified = ProviderAvailability.unverified(reason: "key only")
        #expect(!unverified.isAvailable, "a configured key must never read as verified-available")
        #expect(unverified.isUsable, "configured-but-unprobed is still a routing candidate")
        #expect(unverified.reason == "key only")
        #expect(unverified.label == "unverified")

        let unavailable = ProviderAvailability.unavailable(reason: "offline")
        #expect(!unavailable.isAvailable)
        #expect(!unavailable.isUsable)
        #expect(unavailable.reason == "offline")
        #expect(unavailable.label == "unavailable")
    }

    @Test func probesAreBoundedToFiveSeconds() {
        #expect(ProviderAvailability.probeTimeout == 5)
    }

    // MARK: - Cache TTL

    @Test func cacheServesWithinTenMinuteTTLThenExpires() {
        var cache = ProviderAvailabilityCache(ttl: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        cache.store(.available, for: "groq", now: t0)
        #expect(cache.value(for: "groq", now: t0.addingTimeInterval(1)) == .available)
        #expect(cache.value(for: "groq", now: t0.addingTimeInterval(599)) == .available)
        #expect(cache.value(for: "groq", now: t0.addingTimeInterval(601)) == nil)
        #expect(ProviderAvailabilityCache.defaultTTL == 600)
    }

    @Test func cacheInvalidateDropsEntry() {
        var cache = ProviderAvailabilityCache()
        cache.store(.unavailable(reason: "x"), for: "openai")
        cache.invalidate("openai")
        #expect(cache.value(for: "openai") == nil)
    }

    // MARK: - Groq provider against a mock (no network)

    @Test func keyOnlyGroqIsUnverifiedNotAvailable() async {
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifiedAvailability(probe: false)
        #expect(!availability.isAvailable)
        #expect(isUnverified(availability))
        #expect(availability.reason?.contains("not verified") == true)
    }

    @Test func groqProbeConfirmsAvailableWhenModelListed() async {
        AvailabilityMockURLProtocol.handler = { request in
            (self.response(request.url!, 200), Data(#"{"data":[{"id":"openai/gpt-oss-120b"}]}"#.utf8))
        }
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifiedAvailability(probe: true)
        #expect(availability == .available)
    }

    @Test func groqProbeUnavailableCarriesExactReason() async {
        AvailabilityMockURLProtocol.handler = { request in
            (self.response(request.url!, 200), Data(#"{"data":[]}"#.utf8))
        }
        let provider = GroqProvider(model: "ghost-model", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifiedAvailability(probe: true)
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("not available to this account") == true)
    }

    @Test func groqWithoutKeyIsUnavailableOnBothPaths() async {
        let provider = GroqProvider(model: "m", session: mockSession(),
                                    apiKey: nil, usesKeychain: false)
        let declared = await provider.verifiedAvailability(probe: false)
        let probed = await provider.verifiedAvailability(probe: true)
        #expect(declared == .unavailable(reason: "no Groq API key configured"))
        #expect(probed == .unavailable(reason: "no Groq API key configured"))
    }

    // MARK: - Health snapshot truthfulness

    @Test @MainActor func healthSnapshotReportsTriStateConsistently() async {
        let summary = await ProviderManager.shared.healthSnapshot()
        #expect(summary.verifiedCount == summary.statuses.filter(\.isVerified).count)
        #expect(summary.verifiedCount <= summary.availableCount)
        #expect(summary.availableCount <= summary.totalCount)
        for status in summary.statuses {
            // The legacy boolean is exactly "usable", never "verified".
            #expect(status.isAvailable == status.availability.isUsable)
            #expect(status.isVerified == status.availability.isAvailable)
            if status.isVerified {
                #expect(status.availability == .available)
            }
        }
    }
}
