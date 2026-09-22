import SwiftUI

/// The SwiftUI content shown in the menu bar dropdown popover.
///
/// Displays:
///   - JARVIS status (state, network, memory)
///   - Enable/disable toggle
///   - Quit button
struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // System info
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(appState.isOnline ? "Online" : "Offline")
                        .font(.caption)
                } icon: {
                    Image(systemName: appState.isOnline ? "wifi" : "wifi.slash")
                        .foregroundStyle(appState.isOnline ? .green : .red)
                }

                Label {
                    Text("Memory: \(appState.memoryPressure.rawValue)")
                        .font(.caption)
                } icon: {
                    Image(systemName: "memorychip")
                        .foregroundStyle(memoryColor)
                }

                Label {
                    Text("Keys: \(KeychainManager.shared.availableServices().count)/\(KeychainManager.APIService.allCases.count)")
                        .font(.caption)
                } icon: {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Controls
            Button(action: {
                FloatingPanel.shared.toggle()
            }) {
                Label("Toggle Overlay", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.plain)

            Button(action: toggleState) {
                Label(toggleLabel, systemImage: toggleIcon)
            }
            .buttonStyle(.plain)

            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit JARVIS", systemImage: "power")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 260)
    }

    // MARK: - Computed Properties

    private var statusText: String {
        switch appState.state {
        case .off: return "Disabled"
        case .sleep: return "Listening for wake word…"
        case .active: return "Processing…"
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .off: return .gray
        case .sleep: return .orange
        case .active: return .green
        }
    }

    private var memoryColor: Color {
        switch appState.memoryPressure {
        case .nominal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var toggleLabel: String {
        appState.state == .off ? "Enable JARVIS" : "Disable JARVIS"
    }

    private var toggleIcon: String {
        appState.state == .off ? "play.fill" : "stop.fill"
    }

    private func toggleState() {
        switch appState.state {
        case .off:
            appState.transition(to: .sleep)
        case .sleep, .active:
            appState.transition(to: .off)
        }
    }
}
