import SwiftUI

/// Observable store holding temporary input state for API key entry.
@MainActor
final class APIKeyInputStore: ObservableObject {
    static let shared = APIKeyInputStore()

    @Published var inputs: [String: String] = [:]

    init() {}

    func getInput(for service: KeychainManager.APIService) -> String {
        inputs[service.rawValue] ?? ""
    }

    func setInput(_ text: String, for service: KeychainManager.APIService) {
        inputs[service.rawValue] = text
    }

    func clearInput(for service: KeychainManager.APIService) {
        inputs.removeValue(forKey: service.rawValue)
    }
}

/// Settings view for managing API credentials stored in the macOS Keychain.
public struct APIKeysView: View {
    @ObservedObject private var inputStore = APIKeyInputStore.shared

    /// When embedded in a larger settings page, the view renders as sections
    /// rather than a standalone form.
    private let embedded: Bool

    public init(embedded: Bool = false) {
        self.embedded = embedded
    }

    public var body: some View {
        ZiaSection(
            embedded ? "Credentials" : "Cloud provider credentials",
            footnote: "Keys are stored in the macOS Keychain. ZiA never logs or displays them after saving."
        ) {
            ForEach(Array(KeychainManager.APIService.allCases.enumerated()), id: \.element) { index, service in
                if index > 0 { ZiaDivider() }
                row(for: service)
            }
        }
    }

    @ViewBuilder
    private func row(for service: KeychainManager.APIService) -> some View {
        let configured = isConfigured(service)
        let input = inputStore.getInput(for: service)

        VStack(alignment: .leading, spacing: ZiaSpace.sm) {
            HStack(spacing: ZiaSpace.sm) {
                Text(service.displayName)
                    .font(ZiaType.body)
                    .foregroundStyle(ZiaColors.textPrimary)
                Spacer(minLength: ZiaSpace.sm)
                ZiaBadge(
                    configured ? "Configured" : "Not set",
                    symbol: configured ? "checkmark" : "exclamationmark",
                    tint: configured ? ZiaColors.success : ZiaColors.textTertiary
                )
            }

            HStack(spacing: ZiaSpace.sm) {
                SecureField(configured ? "Replace key…" : "Paste API key…", text: Binding(
                    get: { inputStore.getInput(for: service) },
                    set: { inputStore.setInput($0, for: service) }
                ))
                .textFieldStyle(.plain)
                .font(ZiaType.code)
                .padding(.horizontal, ZiaSpace.sm)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                        .fill(ZiaColors.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                        .strokeBorder(ZiaColors.border, lineWidth: 1)
                )

                ZiaButton("Save", variant: .secondary, size: .small, isEnabled: !input.isEmpty) {
                    saveKey(for: service)
                }

                if configured {
                    ZiaButton("Remove", variant: .destructive, size: .small) {
                        deleteKey(for: service)
                    }
                }
            }
        }
        .padding(.horizontal, ZiaSpace.lg)
        .padding(.vertical, ZiaSpace.md)
    }

    private func isConfigured(_ service: KeychainManager.APIService) -> Bool {
        KeychainManager.shared.hasAPIKey(for: service)
    }

    private func saveKey(for service: KeychainManager.APIService) {
        let key = inputStore.getInput(for: service)
        guard !key.isEmpty else { return }
        do {
            try KeychainManager.shared.setAPIKey(key, for: service)
            inputStore.clearInput(for: service)
            ProviderManager.shared.invalidateAvailability(for: service.providerID)
        } catch {
            JarvisLogger.security.error("Failed to save key: \(error.localizedDescription)")
        }
    }

    private func deleteKey(for service: KeychainManager.APIService) {
        do {
            try KeychainManager.shared.removeAPIKey(for: service)
            inputStore.clearInput(for: service)
            ProviderManager.shared.invalidateAvailability(for: service.providerID)
        } catch {
            JarvisLogger.security.error("Failed to remove key: \(error.localizedDescription)")
        }
    }
}

private extension KeychainManager.APIService {
    /// The provider id this credential unlocks, so availability is re-probed
    /// immediately after a key is added or removed.
    var providerID: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .google: return "google"
        case .groq: return "groq"
        case .openrouter: return "openrouter"
        case .agentBridge: return "chatgpt-desktop"
        case .elevenlabs, .tavily: return rawValue
        }
    }
}
