import Foundation
import Testing
@testable import Jarvis

/// Retry/fallback policy must follow the failure CLASS, not a raw string.
/// Cancellation is terminal; auth/request errors are permanent for the worker;
/// rate limits and timeouts are transient.
@Suite struct ProviderFailureClassTests {

    @Test func cancellationIsTerminal() {
        #expect(ProviderFailureClassifier.classify(CancellationError()) == .cancellation)
        #expect(ProviderFailureClassifier.classify(URLError(.cancelled)) == .cancellation)
        #expect(ProviderFailureClassifier.classify(NSError(domain: "x", code: 1), isCancelled: true) == .cancellation)
        #expect(ProviderFailureClass.cancellation.allowsFallback == false)
        #expect(ProviderFailureClass.cancellation.isRetryableSameProvider == false)
        #expect(ProviderFailureClass.cancellation.countsAsProviderFailure == false)
    }

    @Test func rateLimitIsTransientAndTyepd() {
        let error = JarvisError.providerRateLimited(provider: "groq", retryAfter: 30)
        #expect(ProviderFailureClassifier.classify(error) == .rateLimited)
        #expect(ProviderFailureClass.rateLimited.isRetryableSameProvider)
        #expect(ProviderFailureClass.rateLimited.allowsFallback)
    }

    @Test func authFailureIsPermanentForWorker() {
        let error = JarvisError.providerError(provider: "groq", message: "Groq API error: HTTP 401 unauthorized")
        #expect(ProviderFailureClassifier.classify(error) == .authentication)
        #expect(ProviderFailureClass.authentication.isRetryableSameProvider == false)
        #expect(ProviderFailureClass.authentication.countsAsProviderFailure)
    }

    @Test func timeoutAndNetworkAreRetryable() {
        #expect(ProviderFailureClassifier.classify(URLError(.timedOut)) == .timeout)
        #expect(ProviderFailureClassifier.classify(URLError(.notConnectedToInternet)) == .network)
        #expect(ProviderFailureClass.timeout.isRetryableSameProvider)
        #expect(ProviderFailureClass.network.isRetryableSameProvider)
    }

    @Test func invalidRequestIsOursNotTheProviders() {
        let error = JarvisError.providerError(provider: "groq", message: "HTTP 400 invalid request body")
        #expect(ProviderFailureClassifier.classify(error) == .invalidRequest)
        #expect(ProviderFailureClass.invalidRequest.countsAsProviderFailure == false)
        #expect(ProviderFailureClass.invalidRequest.allowsFallback)
    }

    @Test func quotaExhaustionDoesNotAllowSameWorkerRetry() {
        #expect(ProviderFailureClassifier.classify(message: "insufficient_quota: credit exhausted") == .quotaExhausted)
        #expect(ProviderFailureClass.quotaExhausted.isRetryableSameProvider == false)
        #expect(ProviderFailureClass.quotaExhausted.countsAsProviderFailure)
    }

    @Test func malformedResponseIsClassified() {
        #expect(ProviderFailureClassifier.classify(message: "provider returned an empty response") == .malformedResponse)
        #expect(ProviderFailureClassifier.classify(message: "returned an unparseable response body") == .malformedResponse)
    }

    @Test func unknownFallsBackButIsNotSameWorkerRetryable() {
        #expect(ProviderFailureClassifier.classify(message: "mysterious gremlins") == .unknown)
        #expect(ProviderFailureClass.unknown.allowsFallback)
        #expect(ProviderFailureClass.unknown.isRetryableSameProvider == false)
    }
}
