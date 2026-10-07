import SwiftUI
import AppKit

@MainActor
final class OverlayViewModel: ObservableObject {
    static let shared = OverlayViewModel()

    @Published var inputText: String = ""
    @Published var lastResponse: String = ""
    @Published var isStreaming: Bool = false
    @Published var latencyMs: Int = 0
    @Published var isSpeaking: Bool = false
    @Published private(set) var interactionPhase: InteractionPhase = InteractionPhaseCenter.backendPhase

    /// Real, user-facing failure for the last request (never a stack trace).
    @Published var failure: String?

    /// Live transcript while ZiA is hearing speech.
    @Published private(set) var liveTranscript: String = ""

    /// Set when the user explicitly stops; cleared on the next interaction.
    @Published var wasStopped: Bool = false

    /// The last request sent, so a retry repeats the real request.
    @Published private(set) var lastPrompt: String = ""

    /// Whether the transcript has settled (speech ended, no answer yet).
    @Published private(set) var transcriptSettled = false

    private var interactionSubscription: UUID?
    private var transcriptSubscription: UUID?
    private var finalSubscription: UUID?

    init() {
        interactionSubscription = EventBus.shared.subscribe(InteractionPhaseChangedEvent.self) { [weak self] event in
            guard let self else { return }
            self.interactionPhase = event.phase
            self.isSpeaking = event.phase == .speaking
            if event.phase != .stopped { self.wasStopped = false }
            if event.phase != .listening { self.transcriptSettled = true }
            if event.phase == .listening || event.phase == .idle {
                self.failure = nil
            }
        }
        transcriptSubscription = EventBus.shared.subscribe(TranscriptPartialEvent.self) { [weak self] event in
            self?.liveTranscript = event.text
            self?.transcriptSettled = false
        }
        finalSubscription = EventBus.shared.subscribe(TranscriptFinalEvent.self) { [weak self] event in
            self?.liveTranscript = event.text
            self?.transcriptSettled = true
        }
    }

    /// Send a typed request through the same authoritative production path the
    /// voice pipeline uses. Nothing is streamed that the pipeline did not return.
    func submit(_ raw: String, appState: AppState) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        inputText = ""
        failure = nil
        wasStopped = false
        lastResponse = ""
        isStreaming = true
        lastPrompt = query

        if appState.state == .off {
            appState.transition(to: .sleep)
        }
        appState.transition(to: .active)

        InteractionPhaseCenter.report(.thinking, taskID: "overlay")
        let started = Date()

        Task { @MainActor in
            do {
                let output = try await AgentLoop.shared.run(goal: query)
                isStreaming = false
                lastResponse = output
                latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                InteractionPhaseCenter.report(.success, taskID: "overlay")
            } catch {
                isStreaming = false
                latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                failure = Self.userFacingMessage(for: error)
                InteractionPhaseCenter.report(.error, taskID: "overlay")
            }
            appState.transition(to: .sleep)
            InteractionPhaseCenter.report(.idle)
            // Keep the conversation window in step with what just happened.
            ZiaConversationModel.shared.loadHistory()
        }
    }

    /// Render-only state driver used by `--render-ui` to capture every overlay
    /// state as a reference image. Never called from the running UI.
    func _applyForRendering(
        phase: InteractionPhase,
        response: String = "",
        transcript: String = "",
        failure: String? = nil,
        streaming: Bool = false,
        settled: Bool = false
    ) {
        interactionPhase = phase
        isSpeaking = phase == .speaking
        lastResponse = response
        liveTranscript = transcript
        transcriptSettled = settled
        self.failure = failure
        isStreaming = streaming
        if !response.isEmpty { lastPrompt = response }
    }

    /// Translate a typed error into something a person can act on.
    static func userFacingMessage(for error: any Error) -> String {
        if let jarvis = error as? JarvisError {
            switch jarvis {
            case .providerUnavailable, .providerTimeout, .providerRateLimited,
                 .providerError, .allProvidersFailed, .offline, .apiKeyMissing:
                return "ZiA couldn't reach its primary AI. Local fallback will be used where possible."
            case .microphoneAccessDenied, .speechRecognitionDenied,
                 .permissionDenied, .privacyPolicyViolation:
                return "A required permission is missing. Open Settings › Permissions to grant it."
            case .timeout:
                return "That took longer than expected and was stopped."
            case .insufficientMemory, .modelLoadFailed:
                return "ZiA is short on memory right now — the local model could not run."
            case .commandBlocked, .verificationFailed:
                return "ZiA stopped: the action did not pass its safety or verification check."
            default:
                break
            }
        }

        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("provider")
            || description.localizedCaseInsensitiveContains("unavailable")
            || description.localizedCaseInsensitiveContains("connect")
            || description.localizedCaseInsensitiveContains("offline") {
            return "ZiA couldn't reach its primary AI. Local fallback will be used where possible."
        }
        if description.localizedCaseInsensitiveContains("permission") {
            return "A required permission is missing. Open Settings › Permissions to grant it."
        }
        return "ZiA couldn't complete that request."
    }
}

// MARK: - HUD

/// The voice HUD. Deliberately not an application window:
///
/// - the presence is the surface; there is no header, badge, status table,
///   latency readout or provider name anywhere in it
/// - controls appear only when they can be used (voice input hides the composer;
///   Stop appears only while listening or working)
/// - the container is atmospheric depth, not a card
///
/// Everything it shows comes from authoritative state.
struct OverlayView: View {
    let appState: AppState
    @ObservedObject var viewModel: OverlayViewModel = .shared
    @ObservedObject private var appearance = ZiaAppearanceStore.shared
    @ObservedObject private var hud = ZiaHUDVisibility.shared

    @StateObject private var hovering = ZiaState(false)
    @StateObject private var composerRevealed = ZiaState(false)

    init(appState: AppState = .shared) {
        self.appState = appState
    }

    private var presence: ZiaPresenceState {
        ZiaPresenceState.resolve(
            phase: viewModel.interactionPhase,
            appEnabled: appState.state != .off,
            stopped: viewModel.wasStopped
        )
    }

    private var isListening: Bool { presence == .listening }
    private var isBusy: Bool { presence == .thinking || presence == .working || viewModel.isStreaming }

    /// The presence is the hero: it is the largest thing in every state and the
    /// only element that is always present.
    private var presenceSize: CGFloat {
        switch presence {
        case .listening: return 124
        case .speaking: return 128
        case .understanding, .thinking: return 116
        case .working: return 110
        case .done, .error, .stopped: return 92
        case .idle: return 88
        case .disabled: return 64
        }
    }

    /// Typing is offered only when typing is the useful thing to do: never while
    /// ZiA is hearing or working on something. Idle reveals it on hover or tap,
    /// so the resting HUD stays almost empty.
    private var composerVisible: Bool {
        !isListening && !isBusy
            && (hovering.value || composerRevealed.value || !viewModel.inputText.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZiaPresenceOrb(
                state: presence,
                size: presenceSize,
                animate: hud.isVisible
            )
            .padding(.top, ZiaSpace.md)

            stateText
                .padding(.top, ZiaSpace.md)

            if let failure = viewModel.failure {
                failureBlock(failure)
                    .padding(.top, ZiaSpace.lg)
            } else if !viewModel.lastResponse.isEmpty && !isBusy {
                responseBlock
                    .padding(.top, ZiaSpace.lg)
            }

            if composerVisible {
                ZiaComposer(
                    text: $viewModel.inputText,
                    isWorking: viewModel.isStreaming,
                    isListening: isListening,
                    onSubmit: { viewModel.submit($0, appState: appState) },
                    onMic: handleMic
                )
                .padding(.top, ZiaSpace.xl)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, ZiaSpace.xxl)
        .padding(.top, ZiaSpace.xl)
        .padding(.bottom, ZiaSpace.xxl)
        .frame(width: 400)
        .background(AtmosphericBackdrop(presence: presence))
        .overlay(alignment: .topTrailing) {
            // Contextual stop: only while ZiA is hearing or working on something.
            if isListening || isBusy {
                stopAffordance
                    .padding(.top, ZiaSpace.md)
                    .padding(.trailing, ZiaSpace.md)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: ZiaRadius.hud, style: .continuous))
        .onHover { isHovered in
            hovering.value = isHovered
            if isHovered {
                FloatingPanel.shared.cancelAutoDismiss()
            } else if viewModel.interactionPhase == .success {
                FloatingPanel.shared.scheduleAutoDismiss(after: 4.0)
            }
        }
        .onTapGesture {
            FloatingPanel.shared.cancelAutoDismiss()
            if !isListening && !isBusy { composerRevealed.value = true }
        }
        .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.stateChange), value: composerVisible)
        .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.stateChange), value: presence)
        .preferredColorScheme(appearance.appearance.colorScheme)
    }

    // MARK: Text

    @ViewBuilder
    private var stateText: some View {
        if isListening || (presence == .understanding && !viewModel.liveTranscript.isEmpty) {
            ZiaTranscript(
                text: viewModel.liveTranscript,
                isActive: isListening,
                isSettled: viewModel.transcriptSettled && !isListening
            )
            if isListening {
                ZiaEnergyField(isActive: true)
                    .padding(.top, ZiaSpace.sm)
            }
        } else if isBusy || presence == .stopped {
            // No spinner, no progress bar: one quiet word.
            Text(presence.label)
                .font(.system(size: 13, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.52))
                .transition(.opacity)
        } else if viewModel.lastResponse.isEmpty && viewModel.failure == nil {
            // Idle: a whisper of identity and one affordance.
            VStack(spacing: 6) {
                Text("ZiA")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(.white.opacity(0.78))
                if let hint = presence.hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.34))
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private var responseBlock: some View {
        VStack(spacing: ZiaSpace.md) {
            Text(displayedResponse)
                .font(.system(size: 14.5))
                .lineSpacing(3)
                .foregroundStyle(.white.opacity(0.90))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 320)

            ChatGPTProvenanceBadge()

            if isResponseTruncated {
                // Long answers belong in the conversation window, not in a HUD.
                Button {
                    ZiaWindowController.shared.show()
                } label: {
                    HStack(spacing: 4) {
                        Text("Read in ZiA")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var isResponseTruncated: Bool { viewModel.lastResponse.count > 320 }

    /// Small, honest indicator of which brain produced the answer just shown.
    /// Hidden unless the last answer actually came from ChatGPT.
    private struct ChatGPTProvenanceBadge: View {
        @ObservedObject private var provenance = ChatGPTBrainProvenance.shared

        var body: some View {
            if let answer = provenance.lastAnswer {
                Text("Answered by \(answer)")
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
    private var displayedResponse: String {
        guard isResponseTruncated else { return viewModel.lastResponse }
        return String(viewModel.lastResponse.prefix(320)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    @ViewBuilder
    private func failureBlock(_ message: String) -> some View {
        VStack(spacing: ZiaSpace.sm) {
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button {
                viewModel.submit(viewModel.lastPrompt, appState: appState)
            } label: {
                Text("Try again")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Contextual stop

    private var stopAffordance: some View {
        Button {
            if isListening { viewModel.wasStopped = true }
            VoicePipeline.shared.handleUserStopAction()
        } label: {
            Circle()
                .fill(Color.white.opacity(hovering.value ? 0.16 : 0.08))
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 8, height: 8)
                )
        }
        .buttonStyle(.plain)
        .help(isListening ? "Finish speaking" : "Stop")
        .accessibilityLabel(Text(isListening ? "Finish speaking" : "Stop"))
    }

    // MARK: Voice

    private func handleMic() {
        if isListening {
            VoicePipeline.shared.handleUserStopAction()
        } else {
            if appState.state == .off { appState.transition(to: .sleep) }
            appState.transition(to: .active)
        }
    }
}

// MARK: - Backdrop

/// Atmospheric depth rather than a card: a dark translucent glass wash tinted
/// by the presence, lifted by a subtle hairline rim.
struct AtmosphericBackdrop: View {
    let presence: ZiaPresenceState

    private var tintHue: Double { presence.hue }

    var body: some View {
        RoundedRectangle(cornerRadius: ZiaRadius.hud, style: .continuous)
            // Liquid spatial glass base: translucent enough for underlying vibrant
            // AppKit HUD material to provide physical presence over windows,
            // deep enough to maintain contrast.
            .fill(Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.46))
            .overlay(
                RoundedRectangle(cornerRadius: ZiaRadius.hud, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hue: tintHue, saturation: 0.65, brightness: 0.60, opacity: 0.22),
                                Color(hue: tintHue, saturation: 0.50, brightness: 0.30, opacity: 0.08),
                                Color.clear
                            ],
                            center: .init(x: 0.5, y: 0.26),
                            startRadius: 6,
                            endRadius: 280
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiaRadius.hud, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                Color.white.opacity(0.06),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .animation(ZiaMotion.easeOut, value: presence)
    }
}
