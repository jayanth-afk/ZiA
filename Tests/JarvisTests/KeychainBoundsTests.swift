import Foundation
import Testing
@testable import Jarvis

/// In-memory backend: proves the manager's CRUD semantics without the real
/// keychain.
final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func get(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }
    func set(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
    }
    func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
    }
}

/// Backend that blocks far longer than any reasonable bound, simulating the
/// observed `securityd` stall.
final class SlowKeychainBackend: KeychainBackend, @unchecked Sendable {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func get(_ key: String) throws -> String? {
        Thread.sleep(forTimeInterval: delay)
        return "would-have-been-a-key"
    }
    func set(_ value: String, for key: String) throws {}
    func remove(_ key: String) throws {}
}

/// The keychain read path previously blocked indefinitely inside `securityd`,
/// freezing health checks and the self-test. These tests pin the bounded,
/// fail-closed behavior and the injectable backend.
@Suite struct KeychainBoundsTests {

    @Test func defaultReadTimeoutIsBounded() {
        #expect(KeychainManager.defaultReadTimeout == 2)
    }

    @Test func roundTripsAndReportsConfiguredServices() throws {
        let manager = KeychainManager(backend: InMemoryKeychainBackend(), readTimeout: 1)
        #expect(manager.getAPIKey(for: .groq) == nil)
        #expect(!manager.hasAPIKey(for: .groq))

        try manager.setAPIKey("secret-value", for: .groq)
        #expect(manager.getAPIKey(for: .groq) == "secret-value")
        #expect(manager.hasAPIKey(for: .groq))
        #expect(manager.availableServices().contains(.groq))
        #expect(!manager.missingServices().contains(.groq))

        try manager.removeAPIKey(for: .groq)
        #expect(manager.getAPIKey(for: .groq) == nil)
    }

    @Test func customKeysRoundTrip() throws {
        let backend = InMemoryKeychainBackend()
        let manager = KeychainManager(backend: backend, readTimeout: 1)
        try backend.set("custom-secret", for: "SEARCH_API_KEY")
        #expect(manager.getCustomKey("SEARCH_API_KEY") == "custom-secret")
    }

    @Test func slowReadTimesOutAndFailsClosed() {
        // A backend that never returns within the bound must yield nil fast.
        let manager = KeychainManager(backend: SlowKeychainBackend(delay: 3), readTimeout: 0.2)
        let start = Date()
        let value = manager.getAPIKey(for: .groq)
        let elapsed = Date().timeIntervalSince(start)
        #expect(value == nil)
        #expect(!manager.hasAPIKey(for: .groq))
        // Bounded: must return well before the backend's own delay.
        #expect(elapsed < 2.0)
    }

    @Test func zeroTimeoutReadsInline() throws {
        // readTimeout <= 0 chooses the synchronous path (used by callers that
        // explicitly opt out of the bound).
        let backend = InMemoryKeychainBackend()
        let manager = KeychainManager(backend: backend, readTimeout: 0)
        try manager.setAPIKey("inline", for: .openai)
        #expect(manager.getAPIKey(for: .openai) == "inline")
    }
}
