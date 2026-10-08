import Foundation
import Testing
@testable import Jarvis

/// The quota parser is a truthfulness boundary: a value is only ever `.known`
/// when the provider actually reported it. Absent or unparseable signals must
/// stay `.unknown` — never inferred, never fabricated (§5).
@Suite struct ProviderQuotaSignalTests {

    @Test func parsesOpenAICompatibleHeaders() {
        let quota = ProviderQuotaSignal.parse(headers: [
            "x-ratelimit-remaining-requests": "42",
            "x-ratelimit-remaining-tokens": "8192",
            "x-ratelimit-reset-requests": "1.2s"
        ], now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(quota.requestsRemaining == .known(42))
        #expect(quota.tokensRemaining == .known(8192))
        #expect(quota.hasKnownValue)
        #expect(quota.resetAt == Date(timeIntervalSince1970: 1_700_000_001.2))
    }

    @Test func headerKeysAreCaseInsensitive() {
        let quota = ProviderQuotaSignal.parse(headers: ["X-RateLimit-Remaining-Tokens": "100"])
        #expect(quota.tokensRemaining == .known(100))
    }

    @Test func absentHeadersStayUnknown() {
        let quota = ProviderQuotaSignal.parse(headers: [:])
        #expect(quota.requestsRemaining == .unknown)
        #expect(quota.tokensRemaining == .unknown)
        #expect(quota.creditRemainingUSD == .unknown)
        #expect(quota.resetAt == nil)
        #expect(!quota.hasKnownValue)
    }

    @Test func unparseableValuesStayUnknown() {
        let quota = ProviderQuotaSignal.parse(headers: [
            "x-ratelimit-remaining-requests": "soon",
            "x-ratelimit-reset-requests": "later"
        ])
        #expect(quota.requestsRemaining == .unknown)
        #expect(quota.resetAt == nil)
        #expect(!quota.hasKnownValue)
    }

    @Test func durationParsingHandlesUnitsAndRejectsJunk() {
        #expect(ProviderQuotaSignal.duration(from: "30") == 30)
        #expect(ProviderQuotaSignal.duration(from: "1.2s") == 1.2)
        #expect(ProviderQuotaSignal.duration(from: "500ms") == 0.5)
        #expect(ProviderQuotaSignal.duration(from: "6m") == 360)
        #expect(ProviderQuotaSignal.duration(from: "6m0s") == 360)
        #expect(ProviderQuotaSignal.duration(from: "1h2m3s") == 3723)
        #expect(ProviderQuotaSignal.duration(from: "abc") == nil)
        #expect(ProviderQuotaSignal.duration(from: "12 parsecs") == nil)
        #expect(ProviderQuotaSignal.duration(from: "") == nil)
        #expect(ProviderQuotaSignal.duration(from: nil) == nil)
    }

    @Test func responseParsingUsesHTTPHeaders() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["x-ratelimit-remaining-requests": "0"])!
        let quota = ProviderQuotaSignal.parse(response: response)
        #expect(quota.requestsRemaining == .known(0))
        #expect(quota.hasKnownValue)
    }
}
