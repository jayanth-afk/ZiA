import Foundation
import KeychainAccess

/// Secure API key storage using macOS Keychain.
///
/// Keys are stored with `.afterFirstUnlock` accessibility —
/// available after first device unlock, persists across reboots.
/// Never stored in config files, UserDefaults, or plaintext.
@MainActor
final class KeychainManager {
    static let shared = KeychainManager()

    private let keychain = Keychain(service: "com.jarvis.app")
        .accessibility(.afterFirstUnlock)

    private init() {}

    // MARK: - API Service Registry

    enum APIService: String, CaseIterable, Sendable {
        case anthropic = "jarvis.anthropic.api_key"
        case openai = "jarvis.openai.api_key"
        case google = "jarvis.google.api_key"
        case groq = "jarvis.groq.api_key"
        case elevenlabs = "jarvis.elevenlabs.api_key"

        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .openai: return "OpenAI"
            case .google: return "Google AI (Gemini)"
            case .groq: return "Groq"
            case .elevenlabs: return "ElevenLabs"
            }
        }
    }

    // MARK: - CRUD

    func getAPIKey(for service: APIService) -> String? {
        try? keychain.get(service.rawValue)
    }

    func setAPIKey(_ key: String, for service: APIService) throws {
        try keychain.set(key, key: service.rawValue)
        JarvisLogger.security.info("API key stored for \(service.displayName)")
    }

    func removeAPIKey(for service: APIService) throws {
        try keychain.remove(service.rawValue)
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
}
