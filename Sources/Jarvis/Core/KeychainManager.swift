import Foundation
import KeychainAccess

/// Backend abstraction for secure storage. The production implementation is the
/// macOS Keychain (via `KeychainAccess`); tests inject in-memory or deliberately
/// slow backends so the bounded-read behavior is observable without touching the
/// real keychain.
protocol KeychainBackend: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func remove(_ key: String) throws
}

/// Production backend: macOS Keychain with `.afterFirstUnlock` accessibility —
/// available after first device unlock and persistent across reboots. Storage
/// security is unchanged; only the READ path is time-bounded by the manager.
final class KeychainAccessBackend: KeychainBackend, @unchecked Sendable {
    private let keychain = Keychain(service: "com.jarvis.app")
        .accessibility(.afterFirstUnlock)

    func get(_ key: String) throws -> String? { try keychain.get(key) }
    func set(_ value: String, for key: String) throws { try keychain.set(value, key: key) }
    func remove(_ key: String) throws { try keychain.remove(key) }
}

/// Secure API key storage using macOS Keychain.
///
/// Keys are stored with `.afterFirstUnlock` accessibility — available after
/// first device unlock, persists across reboots. Never stored in config files,
/// UserDefaults, or plaintext.
///
/// **Bounded reads.** `SecItemCopyMatching` can block inside `securityd`
/// indefinitely (observed freezing health checks and the self-test). Every read
/// therefore runs off the caller's thread and waits at most `readTimeout`
/// seconds; on timeout it FAILS CLOSED to `nil` ("no key"), never hanging.
/// Writes/removes remain synchronous (rare, user-initiated).
final class KeychainManager: @unchecked Sendable {
    static let shared = KeychainManager()

    /// Default bound for a single keychain read.
    static let defaultReadTimeout: TimeInterval = 2

    private let backend: any KeychainBackend
    private let readTimeout: TimeInterval
    private let readQueue = DispatchQueue(label: "jarvis.keychain.read", qos: .userInitiated)

    init(backend: any KeychainBackend = KeychainAccessBackend(),
         readTimeout: TimeInterval = KeychainManager.defaultReadTimeout) {
        self.backend = backend
        self.readTimeout = readTimeout
    }

    // MARK: - API Service Registry

    enum APIService: String, CaseIterable, Sendable {
        case anthropic = "jarvis.anthropic.api_key"
        case openai = "jarvis.openai.api_key"
        case google = "jarvis.google.api_key"
        case groq = "jarvis.groq.api_key"
        case elevenlabs = "jarvis.elevenlabs.api_key"
        case tavily = "jarvis.tavily.api_key"
        case openrouter = "jarvis.openrouter.api_key"
        /// Control-plane key for the local Agent Bridge. The bridge's ChatGPT
        /// brain endpoints (`/api/chatgpt/*`) require it; absent ⇒ the brain is
        /// unavailable rather than open to any local caller.
        case agentBridge = "jarvis.agentbridge.api_key"

        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .openai: return "OpenAI"
            case .google: return "Google AI (Gemini)"
            case .groq: return "Groq"
            case .elevenlabs: return "ElevenLabs"
            case .tavily: return "Tavily Search"
            case .openrouter: return "OpenRouter"
            case .agentBridge: return "Agent Bridge (ChatGPT brain)"
            }
        }
    }

    // MARK: - CRUD

    func getAPIKey(for service: APIService) -> String? {
        if backend is KeychainAccessBackend {
            if let env = environmentKey(for: service), !env.isEmpty {
                return env
            }
        }

        if let key = boundedRead(service.rawValue), !key.isEmpty {
            return key
        }

        if backend is KeychainAccessBackend {
            if service == .agentBridge {
                if let bridgeKey = try? Keychain(service: "agent-bridge").get("control_plane_api_key"),
                   !bridgeKey.isEmpty {
                    return bridgeKey
                }
                if let cliBridgeKey = readViaSecurityCLI(service: "agent-bridge", account: "control_plane_api_key"),
                   !cliBridgeKey.isEmpty {
                    return cliBridgeKey
                }
            } else {
                if let cliKey = readViaSecurityCLI(service: "com.jarvis.app", account: service.rawValue),
                   !cliKey.isEmpty {
                    return cliKey
                }
            }
        }
        return nil
    }

    private func environmentKey(for service: APIService) -> String? {
        if service == .agentBridge {
            return ProcessInfo.processInfo.environment["AGENT_BRIDGE_API_KEY"]
                ?? ProcessInfo.processInfo.environment["CONTROL_PLANE_API_KEY"]
        }
        switch service {
        case .anthropic:
            return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        case .openai:
            return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        case .google:
            return ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
        case .groq:
            return ProcessInfo.processInfo.environment["GROQ_API_KEY"]
        case .elevenlabs:
            return ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
        case .tavily:
            return ProcessInfo.processInfo.environment["TAVILY_API_KEY"]
        case .openrouter:
            return ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
        case .agentBridge:
            return nil
        }
    }

    private func readViaSecurityCLI(service: String, account: String) -> String? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                    return str
                }
            }
        } catch {
            return nil
        }
        #endif
        return nil
    }

    func getCustomKey(_ keyName: String) -> String? {
        boundedRead(keyName)
    }

    func setAPIKey(_ key: String, for service: APIService) throws {
        try backend.set(key, for: service.rawValue)
        JarvisLogger.security.info("API key stored for \(service.displayName)")
    }

    func removeAPIKey(for service: APIService) throws {
        try backend.remove(service.rawValue)
        JarvisLogger.security.info("API key removed for \(service.displayName)")
    }

    func hasAPIKey(for service: APIService) -> Bool {
        getAPIKey(for: service) != nil
    }

    /// Returns all services that have API keys configured.
    func availableServices() -> [APIService] {
        APIService.allCases.filter { hasAPIKey(for: $0) }
    }

    /// Returns services that are missing API keys.
    func missingServices() -> [APIService] {
        APIService.allCases.filter { !hasAPIKey(for: $0) }
    }

    // MARK: - Bounded read

    /// Run a keychain read off-thread with a hard upper bound. On timeout the
    /// result is `nil` (fail closed) and the timeout is logged; the abandoned
    /// read may still complete in the background, which is harmless.
    private func boundedRead(_ key: String) -> String? {
        if readTimeout <= 0 { return (try? backend.get(key)) ?? nil }

        let result = LockedValue<String?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let backend = self.backend
        readQueue.async {
            result.value = (try? backend.get(key)) ?? nil
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + readTimeout) == .timedOut {
            JarvisLogger.security.error(
                "Keychain read timed out after \(self.readTimeout)s; failing closed to 'no value' for key '\(key)'")
            return nil
        }
        return result.value
    }
}
