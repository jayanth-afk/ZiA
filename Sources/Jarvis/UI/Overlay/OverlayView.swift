import SwiftUI

@MainActor
final class OverlayViewModel: ObservableObject {
    static let shared = OverlayViewModel()
    @Published var inputText: String = ""
    @Published var lastResponse: String = ""
    @Published var isStreaming: Bool = false
    @Published var latencyMs: Int = 140
    @Published var isSpeaking: Bool = false
    @Published private(set) var interactionPhase: InteractionPhase = InteractionPhaseCenter.backendPhase

    private var interactionSubscription: UUID?

    init() {
        interactionSubscription = EventBus.shared.subscribe(InteractionPhaseChangedEvent.self) { [weak self] event in
            self?.interactionPhase = event.phase
            self?.isSpeaking = event.phase == .speaking
        }
    }
}

/// Main floating HUD view displayed by FloatingPanel.
struct OverlayView: View {
    let appState: AppState
    @ObservedObject var viewModel: OverlayViewModel = .shared

    init(appState: AppState = .shared) {
        self.appState = appState
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            // Header Bar
            HStack {
                // Status pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DesignTokens.Colors.backgroundSecondary)
                .clipShape(Capsule())

                Spacer()

                // Context-aware STOP button: finalizes input if user speaking; cancels if assistant responding
                Button(action: {
                    VoicePipeline.shared.handleUserStopAction()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(DesignTokens.Colors.error)
                        Text("STOP")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(DesignTokens.Colors.error)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(DesignTokens.Colors.error.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            // Audio Waveform Visualizer
            WaveformView(
                isActive: waveformIsActive,
                amplitude: waveformAmplitude
            )
            .padding(.horizontal, DesignTokens.Spacing.sm)

            // Assistant Response Area
            if !viewModel.lastResponse.isEmpty {
                ResponseBubble(
                    text: viewModel.lastResponse,
                    isStreaming: viewModel.isStreaming,
                    providerName: "JARVIS",
                    latencyMs: viewModel.latencyMs
                )
            }

            // Input Bar
            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField("Ask JARVIS or type a command...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .onSubmit {
                        guard !viewModel.inputText.isEmpty else { return }
                        let query = viewModel.inputText
                        viewModel.inputText = ""
                        Task {
                            await MainActor.run {
                                if appState.state == .off {
                                    appState.transition(to: .sleep)
                                }
                                appState.transition(to: .active)
                                viewModel.isStreaming = true
                                viewModel.lastResponse = ""
                            }
                            do {
                                let output = try await AgentLoop.shared.run(goal: query)
                                await MainActor.run {
                                    viewModel.isStreaming = false
                                    viewModel.lastResponse = output
                                    appState.transition(to: .sleep)
                                }
                            } catch {
                                await MainActor.run {
                                    viewModel.isStreaming = false
                                    viewModel.lastResponse = "I couldn't complete that request. Please try again."
                                    appState.transition(to: .sleep)
                                }
                            }
                        }
                    }

                if !viewModel.inputText.isEmpty {
                    Button(action: {
                        viewModel.inputText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(DesignTokens.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.Colors.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignTokens.Colors.border, lineWidth: 1)
            )
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 440)
        .background(
            ZStack {
                DesignTokens.Colors.background
                DesignTokens.Gradients.glassSurface
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Spacing.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.panelCornerRadius)
                .stroke(DesignTokens.Colors.borderHighlight, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
    }

    private var statusColor: Color {
        switch viewModel.interactionPhase {
        case .listening: return DesignTokens.Colors.warning
        case .understanding, .thinking: return DesignTokens.Colors.primaryAccent
        case .executing, .speaking: return DesignTokens.Colors.success
        case .success: return DesignTokens.Colors.success
        case .error, .stopped: return DesignTokens.Colors.error
        case .idle: break
        }
        switch appState.state {
        case .off: return DesignTokens.Colors.textTertiary
        case .sleep: return DesignTokens.Colors.warning
        case .active: return DesignTokens.Colors.success
        }
    }

    private var statusText: String {
        switch viewModel.interactionPhase {
        case .listening: return "Listening"
        case .understanding: return "Understanding"
        case .thinking: return "Thinking"
        case .executing: return "Working"
        case .speaking: return "Speaking"
        case .success: return "Done"
        case .error: return "Couldn't complete"
        case .stopped: return "Stopped"
        case .idle: break
        }
        switch appState.state {
        case .off: return "Disabled"
        case .sleep: return "Ready"
        case .active: return "Working"
        }
    }

    private var waveformIsActive: Bool {
        switch viewModel.interactionPhase {
        case .listening, .understanding, .thinking, .executing, .speaking: return true
        case .idle, .success, .error, .stopped: return viewModel.isSpeaking
        }
    }

    private var waveformAmplitude: CGFloat {
        switch viewModel.interactionPhase {
        case .speaking: return 0.75
        case .listening: return 0.35
        case .understanding, .thinking, .executing: return 0.5
        case .idle, .success, .error, .stopped: return viewModel.isSpeaking ? 0.75 : 0
        }
    }
}
