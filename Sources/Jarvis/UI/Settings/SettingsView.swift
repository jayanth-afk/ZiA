import SwiftUI

/// Full Preferences / Settings window for JARVIS.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            // General Tab
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            // Models Tab
            ModelSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            // API Keys Tab
            APIKeysView()
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }

            // Memory & Privacy Tab
            MemoryPrivacySettingsView()
                .tabItem {
                    Label("Memory", systemImage: "brain")
                }
        }
        .frame(width: 540, height: 400)
    }
}

// MARK: - Subviews

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("Voice & Interaction").font(.headline)) {
                Toggle("Enable Apple Speech Voice Pipeline", isOn: Binding(
                    get: { Config.shared.voiceEnabled },
                    set: { Config.shared.voiceEnabled = $0 }
                ))

                Picker("Autonomy Level", selection: Binding(
                    get: { PermissionGate.shared.currentLevel },
                    set: { Config.shared.autonomyLevel = $0.rawValue }
                )) {
                    Text("L0: Read-Only (Observe only)").tag(PermissionGate.AutonomyLevel.l0ReadOnly)
                    Text("L1: Supervised (Safe mutations allowed)").tag(PermissionGate.AutonomyLevel.l1Supervised)
                    Text("L2: Autonomous (Destructive confirmed)").tag(PermissionGate.AutonomyLevel.l2Autonomous)
                    Text("L3: Full (Autonomous execution)").tag(PermissionGate.AutonomyLevel.l3Full)
                }
            }

            Section(header: Text("Hardware Target").font(.headline)) {
                Text("MacBook Pro 14\" (Apple M4, 16 GB Unified Memory)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("Local Intelligence (Apple Silicon MLX)").font(.headline)) {
                TextField("Reflex Model (3-4B):", text: Binding(
                    get: { Config.shared.localReflexModel },
                    set: { Config.shared.localReflexModel = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Normal Intelligence Model (7-9B):", text: Binding(
                    get: { Config.shared.localNormalModel },
                    set: { Config.shared.localNormalModel = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Section(header: Text("Capability Routing").font(.headline)) {
                Text("Deterministic router executes first. Reflex handles local intents in <200ms. Cloud providers (Claude, Gemini, Groq, OpenAI) are selected based on task capability and data sensitivity.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct MemoryPrivacySettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("User Knowledge & Recall").font(.headline)) {
                Text("Stored Facts: \(UserProfile.shared.allFacts.count)")

                Button("Purge Session Memories") {
                    UserProfile.shared.purgeTemporaryFacts()
                }

                Button("Forget All Memories") {
                    UserProfile.shared.clearAll()
                    MemoryManager.shared.clearAll()
                }
                .foregroundColor(.red)
            }
        }
        .padding()
    }
}
