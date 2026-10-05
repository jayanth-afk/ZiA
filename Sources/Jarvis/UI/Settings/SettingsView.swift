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

            // Preferences Tab
            UserPreferencesSettingsView()
                .tabItem {
                    Label("Preferences", systemImage: "slider.horizontal.3")
                }

            // Memory & Privacy Tab
            MemoryPrivacySettingsView()
                .tabItem {
                    Label("Memory", systemImage: "brain")
                }

            // System Health & Diagnostics Tab
            HealthDiagnosticsSettingsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "cross.case")
                }
        }
        .frame(width: 580, height: 440)
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

struct UserPreferencesSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("Assistant Tone & Verbosity").font(.headline)) {
                Picker("Verbosity", selection: Binding(
                    get: { PreferenceStore.shared.current.verbosity },
                    set: { val in PreferenceStore.shared.updateExplicit { $0.verbosity = val } }
                )) {
                    Text("Concise").tag(ResponseVerbosity.concise)
                    Text("Normal").tag(ResponseVerbosity.normal)
                    Text("Detailed").tag(ResponseVerbosity.detailed)
                }

                Picker("Style", selection: Binding(
                    get: { PreferenceStore.shared.current.style },
                    set: { val in PreferenceStore.shared.updateExplicit { $0.style = val } }
                )) {
                    Text("Direct").tag(ResponseStyle.direct)
                    Text("Friendly").tag(ResponseStyle.friendly)
                    Text("Technical").tag(ResponseStyle.technical)
                }
            }

            Section(header: Text("Safety & Confirmation").font(.headline)) {
                Picker("Confirmation Mode", selection: Binding(
                    get: { PreferenceStore.shared.current.confirmation },
                    set: { val in PreferenceStore.shared.updateExplicit { $0.confirmation = val } }
                )) {
                    Text("Ask for Destructive Actions").tag(ConfirmationPreference.askForDestructive)
                    Text("Ask for All External Actions").tag(ConfirmationPreference.askForExternal)
                    Text("Minimal / Strict Gate Only").tag(ConfirmationPreference.minimal)
                }

                Toggle("Local-Only Mode (Block all cloud egress)", isOn: Binding(
                    get: { PreferenceStore.shared.current.localOnly },
                    set: { val in PreferenceStore.shared.updateExplicit { $0.localOnly = val } }
                ))
            }

            Section(header: Text("Notifications & Autonomy").font(.headline)) {
                Toggle("Notify on Task Completion", isOn: Binding(
                    get: { PreferenceStore.shared.current.notifyOnCompletion },
                    set: { val in PreferenceStore.shared.updateExplicit { $0.notifyOnCompletion = val } }
                ))

                Toggle("Notify on Task Failure", isOn: Binding(
                    get: { PreferenceStore.shared.current.notifyOnFailure },
                    set: { val in PreferenceStore.shared.updateExplicit { $0.notifyOnFailure = val } }
                ))
            }
        }
        .padding()
    }
}

struct HealthDiagnosticsSettingsView: View {
    private var topCapabilities: [CapabilityDescriptor] {
        Array(CapabilityRegistry.descriptors().prefix(8))
    }

    private var activeTaskCount: Int {
        let all = TaskStateMachine.shared.allTasks
        var active = 0
        for t in all {
            if t.state == TaskState.running || t.state == TaskState.planning {
                active += 1
            }
        }
        return active
    }

    var body: some View {
        Form {
            Section(header: Text("System Status").font(.headline)) {
                HStack {
                    Text("Overall Status:")
                    Spacer()
                    Text("Operational")
                        .bold()
                        .foregroundColor(.green)
                }

                HStack {
                    Text("Active Tasks:")
                    Spacer()
                    Text(String(activeTaskCount))
                }
            }

            Section(header: Text("Subsystems & Capabilities").font(.headline)) {
                ForEach(topCapabilities, id: \CapabilityDescriptor.name) { (cap: CapabilityDescriptor) in
                    HStack {
                        Text(cap.name)
                        Spacer()
                        Text(cap.availability.capitalized)
                            .font(.caption)
                            .foregroundColor(cap.availability == "available" ? .green : .secondary)
                    }
                }
            }
        }
        .padding()
    }
}
