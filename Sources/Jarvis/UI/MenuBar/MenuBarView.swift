import SwiftUI

/// The SwiftUI content shown in the menu bar dropdown popover.
///
/// Displays:
///   - JARVIS status (state, network, memory)
///   - Recent conversation transcript (bounded, via HistoryService)
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

            // Recent conversation transcript (HistoryService boundary — never
            // SQLite internals). Bounded window with older-page loading.
            MenuHistorySection()

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
        .onAppear {
            HistoryService.shared.loadRecent()
        }
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

/// Minimal transcript section (Phase 3 foundation): bounded recent history
/// through the HistoryService boundary, with one older-page affordance. Not
/// the final Zia conversation UI — this proves the data boundary end to end.
struct MenuHistorySection: View {
    @ObservedObject private var history = HistoryService.shared
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Recent conversation", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                Spacer()
                if showAll {
                    Button("Show less") {
                        showAll = false
                        history.loadRecent()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                } else if history.turns.count > 4 {
                    Button("Older") {
                        showAll = true
                        history.loadOlder()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                }
            }

            if history.turns.isEmpty {
                Text("No conversation yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach((showAll ? history.turns : Array(history.turns.suffix(4)))) { turn in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: turn.isFromUser ? "person.fill" : "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(turn.isFromUser ? Color.secondary : Color.blue)
                            .frame(width: 14)
                        Text(turn.text)
                            .font(.caption2)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}
