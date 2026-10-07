import Foundation
import Testing
@testable import Jarvis

/// A `URLProtocol` stub for the Cerebras provider. Deliberately its own class so
/// this suite can run alongside the Groq/availability suites without sharing
/// mutable handler state. No network is used.
final class CerebrasMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = CerebrasMockURLProtocol.handler else {
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

/// Code-level validation of the Cerebras inference provider against a mock
/// transport: request construction, response decoding, model discovery,
/// streaming, and typed rate-limit signalling. Cerebras has no installed
/// credential in this environment, so this suite is CODE VERIFIED only — it
/// exercises the real request/response path without live API access.
@Suite(.serialized) struct CerebrasProviderTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CerebrasMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(_ url: URL, _ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    /// Collects text plus any terminal error / rate-limit signal.
    private func collect(_ stream: AsyncThrowingStream<StreamChunk, any Error>)
        async -> (text: String, error: String?, retryAfter: TimeInterval?) {
        var text = ""
        do {
            for try await chunk in stream {
                switch chunk {
                case .text(let t): text += t
                case .error(let e): return (text, e, nil)
                case .rateLimited(let r): return (text, nil, r)
                case .done, .toolCall: break
                }
            }
        } catch {
            return (text, error.localizedDescription, nil)
        }
        return (text, nil, nil)
    }

    // MARK: - Completion

    @Test func nonStreamingCompletionParsesSingleBody() async {
        CerebrasMockURLProtocol.handler = { request in
            let body = #"{"choices":[{"message":{"content":"cerebras says hi"}}],"usage":{"prompt_tokens":4,"completion_tokens":3}}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.text == "cerebras says hi")
        #expect(result.error == nil)
    }

    @Test func streamingCompletionParsesSSE() async {
        CerebrasMockURLProtocol.handler = { request in
            let sse = """
            data: {"choices":[{"delta":{"content":"gpt-"}}]}

            data: {"choices":[{"delta":{"content":"oss"}}],"usage":{"prompt_tokens":2,"completion_tokens":2}}

            data: [DONE]

            """
            return (self.response(request.url!, 200), Data(sse.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: true)
        let result = await collect(stream)
        #expect(result.text == "gpt-oss")
        #expect(result.error == nil)
    }

    @Test func requestBodyCarriesModelMessagesAndStreamFlag() async {
        // Proves the provider actually builds a well-formed OpenAI-compatible
        // request (not just that it returns something).
        nonisolated(unsafe) var seenBody: [String: Any]?
        CerebrasMockURLProtocol.handler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                seenBody = json
            }
            let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "ping")], tools: nil, stream: false)
        _ = await collect(stream)
        #expect(seenBody?["model"] as? String == "gpt-oss-120b")
        #expect(seenBody?["stream"] as? Bool == false)
        let messages = seenBody?["messages"] as? [[String: String]]
        #expect(messages?.first?["content"] == "ping")
    }

    // MARK: - Model discovery

    @Test func verifyModelAvailabilityConfirmsListedModel() async {
        CerebrasMockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"gpt-oss-120b"},{"id":"llama-3.1-8b"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        #expect(await provider.verifyModelAvailability() == .available)
    }

    @Test func verifyModelAvailabilityReportsExactMissingModelReason() async {
        CerebrasMockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"llama-3.1-8b"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifyModelAvailability()
        #expect(!availability.isAvailable)
        guard case .unavailable(let reason) = availability else {
            Issue.record("expected .unavailable"); return
        }
        #expect(reason.contains("gpt-oss-120b"))
    }

    @Test func verifyModelAvailabilityReportsHTTPError() async {
        CerebrasMockURLProtocol.handler = { request in
            (self.response(request.url!, 503), Data("upstream down".utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifyModelAvailability()
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("HTTP 503") == true)
    }

    @Test func healthCheckIsTruthfulWhenModelConfirmed() async {
        CerebrasMockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"gpt-oss-120b"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let health = await provider.healthCheck()
        #expect(health.isHealthy)
    }

    // MARK: - Failure handling

    @Test func missingKeyFailsClosedWithExactReason() async {
        CerebrasMockURLProtocol.handler = { request in
            (self.response(request.url!, 200), Data(#"{"data":[]}"#.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(),
                                        apiKey: nil, usesKeychain: false)
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("missing from Keychain") == true)
        #expect(await provider.verifyModelAvailability() == .unavailable(reason: "no Cerebras API key configured"))
    }

    @Test func nonStreamingHTTPErrorIsReported() async {
        CerebrasMockURLProtocol.handler = { request in
            (self.response(request.url!, 401), Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "bad")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("401") == true)
    }

    // MARK: - Rate limiting (typed signal, not a generic error)

    @Test func http429NonStreamingBecomesTypedRateLimit() async {
        CerebrasMockURLProtocol.handler = { request in
            (self.response(request.url!, 429, headers: ["Retry-After": "42"]), Data("slow down".utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error == nil, "429 must not surface as a generic error")
        #expect(result.retryAfter == 42)
    }

    @Test func http429StreamingBecomesTypedRateLimit() async {
        CerebrasMockURLProtocol.handler = { request in
            (self.response(request.url!, 429, headers: ["Retry-After": "7"]), Data("slow down".utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: true)
        let result = await collect(stream)
        #expect(result.error == nil)
        #expect(result.retryAfter == 7)
    }

    @Test func http429WithoutRetryAfterYieldsNilHint() async {
        CerebrasMockURLProtocol.handler = { request in
            (self.response(request.url!, 429), Data("slow down".utf8))
        }
        let provider = CerebrasProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error == nil)
        #expect(result.retryAfter == nil)
    }
}

/// The rate-limit parser is the shared contract every provider depends on, so it
/// is pinned directly (clamping, defaults, and malformed headers).
@Suite struct ProviderRateLimitTests {
    private func resp(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429,
                        httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func parsesDeltaSeconds() {
        #expect(ProviderRateLimit.retryAfter(from: resp(["Retry-After": "12"])) == 12)
        #expect(ProviderRateLimit.retryAfter(from: resp(["Retry-After": "12.5"])) == 12.5)
    }

    @Test func absentOrMalformedHeaderIsNil() {
        #expect(ProviderRateLimit.retryAfter(from: resp([:])) == nil)
        #expect(ProviderRateLimit.retryAfter(from: resp(["Retry-After": ""])) == nil)
        // HTTP-date form is intentionally not parsed; falls back to the default.
        #expect(ProviderRateLimit.retryAfter(from: resp(["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])) == nil)
        #expect(ProviderRateLimit.retryAfter(from: nil) == nil)
    }

    @Test func clampsToSaneRange() {
        #expect(ProviderRateLimit.clamp(0) == 1)
        #expect(ProviderRateLimit.clamp(-5) == 1)
        #expect(ProviderRateLimit.clamp(100_000) == ProviderRateLimit.maxCooldown)
        #expect(ProviderRateLimit.maxCooldown == 900)
    }

    @Test func cooldownUsesHintOrDefault() {
        #expect(ProviderRateLimit.cooldown(for: nil) == ProviderRateLimit.defaultCooldown)
        #expect(ProviderRateLimit.defaultCooldown == 30)
        #expect(ProviderRateLimit.cooldown(for: 45) == 45)
        #expect(ProviderRateLimit.cooldown(for: 100_000) == ProviderRateLimit.maxCooldown)
    }
}
