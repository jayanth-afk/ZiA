import Foundation
import Testing
@testable import Jarvis

/// A `URLProtocol` stub so the Groq provider's real request/response path can be
/// exercised with NO network access.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
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

/// The Groq provider previously advertised streaming but could not parse its own
/// SSE reply, assumed the configured model existed, and reported "healthy"
/// whenever a key was present. These tests pin the fixed behavior against a
/// mock transport.
@Suite(.serialized) struct GroqProviderTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func collect(_ stream: AsyncThrowingStream<StreamChunk, any Error>) async -> (text: String, error: String?) {
        var text = ""
        do {
            for try await chunk in stream {
                switch chunk {
                case .text(let t): text += t
                case .error(let e): return (text, e)
                case .done, .toolCall: break
                }
            }
        } catch {
            return (text, error.localizedDescription)
        }
        return (text, nil)
    }

    @Test func nonStreamingCompletionParsesSingleBody() async {
        MockURLProtocol.handler = { request in
            let body = #"{"choices":[{"message":{"content":"hello world"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.text == "hello world")
        #expect(result.error == nil)
    }

    @Test func streamingCompletionParsesSSE() async {
        // The SSE branch is only taken when `stream: true` is requested, so a
        // successful parse proves the streaming path is real (not the single-
        // body path that previously swallowed the SSE reply).
        MockURLProtocol.handler = { request in
            let sse = """
            data: {"choices":[{"delta":{"content":"hel"}}]}

            data: {"choices":[{"delta":{"content":"lo"}}],"usage":{"prompt_tokens":2,"completion_tokens":2}}

            data: [DONE]

            """
            return (self.response(request.url!, 200), Data(sse.utf8))
        }
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: true)
        let result = await collect(stream)
        #expect(result.text == "hello")
        #expect(result.error == nil)
    }

    @Test func verifyModelAvailabilityConfirmsListedModel() async {
        MockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"openai/gpt-oss-120b"},{"id":"llama-3.1-8b-instant"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifyModelAvailability()
        #expect(availability == .available)
    }

    @Test func verifyModelAvailabilityReportsExactMissingModelReason() async {
        MockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"llama-3.1-8b-instant"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = GroqProvider(model: "llama-3.3-70b-versatile", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifyModelAvailability()
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("not available to this account") == true)
        #expect(availability.reason?.contains("llama-3.3-70b-versatile") == true)
    }

    @Test func verifyModelAvailabilityReportsHTTPError() async {
        MockURLProtocol.handler = { request in
            (self.response(request.url!, 404), Data("model not found".utf8))
        }
        let provider = GroqProvider(model: "ghost", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifyModelAvailability()
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("HTTP 404") == true)
        #expect(availability.reason?.contains("model not found") == true)
    }

    @Test func verifyModelAvailabilityFailsClosedWithoutKey() async {
        // No injected key and no keychain fixture: must report the exact reason.
        MockURLProtocol.handler = { request in
            (self.response(request.url!, 200), Data(#"{"data":[]}"#.utf8))
        }
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(),
                                    apiKey: nil, usesKeychain: false)
        let availability = await provider.verifyModelAvailability()
        #expect(!availability.isAvailable)
        #expect(availability.reason == "no Groq API key configured")
    }

    @Test func nonStreamingHTTPErrorIsReported() async {
        MockURLProtocol.handler = { request in
            (self.response(request.url!, 401), Data(#"{"error":{"message":"invalid api key"}}"#.utf8))
        }
        let provider = GroqProvider(model: "openai/gpt-oss-120b", session: mockSession(), apiKey: "bad-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("401") == true)
        #expect(result.error?.contains("invalid api key") == true)
    }
}
