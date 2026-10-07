import Foundation
import Testing
@testable import Jarvis

/// C1 (Zia side): the ChatGPT brain requires the Agent Bridge control-plane key.
/// An absent key must FAIL CLOSED — no unauthenticated request is ever sent.
@Suite struct ChatGPTBrainKeyTests {

    @Test func agentBridgeKeychainServiceRoundTrips() throws {
        let backend = InMemoryKeychainBackend()
        let manager = KeychainManager(backend: backend, readTimeout: 1)
        try manager.setAPIKey("bridge-secret", for: .agentBridge)
        #expect(manager.getAPIKey(for: .agentBridge) == "bridge-secret")
        #expect(manager.hasAPIKey(for: .agentBridge))
        #expect(KeychainManager.APIService.agentBridge.rawValue == "jarvis.agentbridge.api_key")
        #expect(KeychainManager.APIService.agentBridge.displayName.contains("Agent Bridge"))
    }

    @Test func providerWithoutKeyIsUnavailableWithExactReason() async {
        let provider = ChatGPTDesktopProvider(apiKeyProvider: { nil }, isEnabledProvider: { true })
        let availability = await provider.verifiedAvailability(probe: false)
        #expect(!availability.isAvailable)
        #expect(!availability.isUsable)
        #expect(availability.reason?.contains("API key") == true)
    }

    @Test func providerWithoutKeyFailsClosedOnCompletion() async {
        let provider = ChatGPTDesktopProvider(apiKeyProvider: { nil }, isEnabledProvider: { true })
        let stream = await provider.complete(
            messages: [Message(role: .user, content: "hello")], tools: nil, stream: false)

        var errorMessage: String?
        do {
            for try await chunk in stream {
                if case .error(let message) = chunk { errorMessage = message }
            }
        } catch let caught {
            errorMessage = caught.localizedDescription
        }
        // Fails closed locally — the message names the missing key, and no
        // network request is made.
        #expect(errorMessage?.contains("API key") == true)
    }

    @Test func configuredKeyIsUnverifiedNotAvailable() async {
        // A key that is present but not probed must not read as available.
        let provider = ChatGPTDesktopProvider(apiKeyProvider: { "bridge-secret" }, isEnabledProvider: { true })
        let availability = await provider.verifiedAvailability(probe: false)
        #expect(!availability.isAvailable)
        if case .unverified = availability {} else {
            Issue.record("expected .unverified for an unprobed key, got \(availability)")
        }
    }
}
