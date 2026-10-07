import Foundation
import Testing
@testable import Jarvis

/// A dedicated `URLProtocol` stub so this suite can run concurrently with the
/// others without sharing mutable handler state. No network is used.
final class BrainMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = BrainMockURLProtocol.handler else {
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

/// C3: the ChatGPT brain is opt-in (default OFF), gated by the API key, the
/// DataClassifier, and ContextSanitizer; it reports the transport it used and
/// counts human-scale requests. Exercised against a URLProtocol stub bridge.
@Suite(.serialized) struct ChatGPTBrainSettingsTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BrainMockURLProtocol.self]
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
                case .rateLimited: return (text, "rate limited")
                case .done, .toolCall: break
                }
            }
        } catch {
            return (text, error.localizedDescription)
        }
        return (text, nil)
    }

    @Test func dailyCounterIncrementsAndResetsAcrossDays() {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        ChatGPTBrain.recordRequest(now: day, calendar: calendar)
        ChatGPTBrain.recordRequest(now: day, calendar: calendar)
        #expect(ChatGPTBrain.requestsToday(now: day, calendar: calendar) == 2)
        let nextDay = day.addingTimeInterval(2 * 24 * 3600)
        #expect(ChatGPTBrain.requestsToday(now: nextDay, calendar: calendar) == 0)
    }

    @Test func brainDefaultsOffWhenUnset() {
        let defaults = UserDefaults.standard
        let key = "jarvis.chatgpt.allowBrain"
        let existing = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer { if let existing { defaults.set(existing, forKey: key) } }
        #expect(ChatGPTBrain.isEnabled == false, "the brain is opt-in and off by default")
    }

    @Test func disabledBrainMakesNoRequest() async {
        let calls = LockedValue<Int>(0)
        BrainMockURLProtocol.handler = { request in
            calls.value += 1
            return (self.response(request.url!, 200), Data(#"{"ok":true}"#.utf8))
        }
        let provider = ChatGPTDesktopProvider(session: mockSession(), apiKeyProvider: { "test-key" }, isEnabledProvider: { false })

        let availability = await provider.verifiedAvailability(probe: false)
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("off") == true)
        #expect(await provider.isAvailable == false)

        let stream = await provider.complete(messages: [Message(role: .user, content: "hello")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("off") == true)
        #expect(calls.value == 0, "the brain is off, so nothing was sent")
    }

    @Test func enabledWithKeyAndHealthyBridgeIsAvailable() async {
        BrainMockURLProtocol.handler = { request in
            let body = #"{"ok":true,"status":"READY"}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = ChatGPTDesktopProvider(session: mockSession(), apiKeyProvider: { "test-key" }, isEnabledProvider: { true })
        let availability = await provider.verifiedAvailability(probe: true)
        #expect(availability == .available)
    }

    @Test func enabledWithoutKeyIsUnavailable() async {
        let provider = ChatGPTDesktopProvider(session: mockSession(), apiKeyProvider: { nil }, isEnabledProvider: { true })
        let availability = await provider.verifiedAvailability(probe: false)
        #expect(!availability.isAvailable)
        #expect(availability.reason?.contains("API key") == true)
    }

    @Test func sensitiveRequestNeverLeavesTheMachine() async {
        let calls = LockedValue<Int>(0)
        BrainMockURLProtocol.handler = { request in
            calls.value += 1
            return (self.response(request.url!, 200), Data(#"{"ok":true,"modelTurnConfirmed":true,"response":"leaked"}"#.utf8))
        }
        let provider = ChatGPTDesktopProvider(session: mockSession(), apiKeyProvider: { "test-key" }, isEnabledProvider: { true })
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "my password is hunter2")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.error?.contains("HIGHLY_SENSITIVE") == true)
        #expect(calls.value == 0, "a highly-sensitive request must fail closed to local")
    }

    @Test func successfulTurnReportsTransportAndRecordsUsage() async {
        let before = ChatGPTBrain.requestsToday()
        BrainMockURLProtocol.handler = { request in
            let body = #"{"ok":true,"modelTurnConfirmed":true,"response":"hi from chatgpt","transport":"engine"}"#
            return (self.response(request.url!, 200), Data(body.utf8))
        }
        let provider = ChatGPTDesktopProvider(session: mockSession(), apiKeyProvider: { "test-key" }, isEnabledProvider: { true })
        let stream = await provider.complete(messages: [Message(role: .user, content: "hello")], tools: nil, stream: false)
        let result = await collect(stream)
        #expect(result.text == "hi from chatgpt")
        #expect(result.error == nil)
        #expect(await provider.lastTransport() == "engine")
        #expect(ChatGPTBrain.requestsToday() == before + 1)
    }
}
