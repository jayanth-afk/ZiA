import Foundation
import Testing
@testable import Jarvis

/// A `URLProtocol` stub for the SambaNova provider (own class so it never shares
/// mutable handler state with other suites). No network is used.
final class SambaNovaMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = SambaNovaMockURLProtocol.handler else {
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

/// Code-level validation of the SambaNova provider against a mock transport.
/// SambaNova has no installed credential in this environment and is classified
/// as a paid worker, so this is CODE VERIFIED only.
@Suite(.serialized) struct SambaNovaProviderTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SambaNovaMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(_ url: URL, _ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

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

    @Test func nonStreamingCompletionParsesSingleBody() async {
        SambaNovaMockURLProtocol.handler = { request in
            let body = #"{"choices":[{"message":{"content":"samba says hi"}}],"usage":{"prompt_tokens":4,"completion_tokens":3}}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.text == "samba says hi")
        #expect(result.error == nil)
    }

    @Test func streamingCompletionParsesSSE() async {
        SambaNovaMockURLProtocol.handler = { request in
            let sse = """
            data: {"choices":[{"delta":{"content":"sam"}}]}

            data: {"choices":[{"delta":{"content":"ba"}}]}

            data: [DONE]

            """
            return (self.response(request.url!, 200), Data(sse.utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: true)
        let result = await collect(stream)
        #expect(result.text == "samba")
        #expect(result.error == nil)
    }

    @Test func verifyModelAvailabilityConfirmsListedModel() async {
        SambaNovaMockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"gpt-oss-120b"},{"id":"Meta-Llama-3.3-70B"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        #expect(await provider.verifyModelAvailability() == .available)
    }

    @Test func verifyModelAvailabilityReportsExactMissingModelReason() async {
        SambaNovaMockURLProtocol.handler = { request in
            let body = #"{"data":[{"id":"Meta-Llama-3.3-70B"}]}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let availability = await provider.verifyModelAvailability()
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("gpt-oss-120b") == true)
    }

    @Test func missingKeyFailsClosedWithExactReason() async {
        SambaNovaMockURLProtocol.handler = { request in
            (self.response(request.url!, 200), Data(#"{"data":[]}"#.utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(),
                                         apiKey: nil, usesKeychain: false)
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("missing from Keychain") == true)
        #expect(await provider.verifyModelAvailability() == .unavailable(reason: "no SambaNova API key configured"))
    }

    @Test func http429BecomesTypedRateLimit() async {
        SambaNovaMockURLProtocol.handler = { request in
            (self.response(request.url!, 429, headers: ["Retry-After": "13"]), Data("slow down".utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error == nil)
        #expect(result.retryAfter == 13)
    }

    @Test func nonStreamingHTTPErrorIsReported() async {
        SambaNovaMockURLProtocol.handler = { request in
            (self.response(request.url!, 402), Data("payment required".utf8))
        }
        let provider = SambaNovaProvider(model: "gpt-oss-120b", session: mockSession(), apiKey: "test-key")
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hi")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("402") == true)
    }
}
