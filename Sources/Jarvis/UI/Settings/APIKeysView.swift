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

/// Settings view for managing API credentials stored in macOS Keychain.
public struct APIKeysView: View {
    @ObservedObject private var inputStore = APIKeyInputStore.shared

    public init() {}

    public var body: some View {
        Form {
            Section(header: Text("Cloud Providers & External Services").font(.headline)) {
                ForEach(KeychainManager.APIService.allCases, id: \.self) { service in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(service.displayName)
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            if isConfigured(service) {
                                Label("Configured", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                Label("Not set", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }

                        HStack {
                            SecureField("Enter API key...", text: Binding(
                                get: { inputStore.getInput(for: service) },
                                set: { inputStore.setInput($0, for: service) }
                            ))
                            .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                saveKey(for: service)
                            }
                            .disabled(inputStore.getInput(for: service).isEmpty)

                            if isConfigured(service) {
                                Button("Delete") {
                                    deleteKey(for: service)
                                }
                                .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
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
        } catch {
            JarvisLogger.security.error("Failed to save key: \(error.localizedDescription)")
        }
    }

    private func deleteKey(for service: KeychainManager.APIService) {
        do {
            try KeychainManager.shared.removeAPIKey(for: service)
            inputStore.clearInput(for: service)
        } catch {
            JarvisLogger.security.error("Failed to remove key: \(error.localizedDescription)")
        }
    }
}
