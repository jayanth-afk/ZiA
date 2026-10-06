import SwiftUI
import AppKit

// MARK: - Conversation model

/// The live conversation surface. History comes from the read-only
/// `HistoryService` boundary; new turns come from the authoritative
/// `AgentLoop.run(goal:)` path — the same path the voice pipeline uses.
///
/// Nothing here reports progress it did not observe: a turn is "waiting" until
/// the pipeline returns, and the presence reports the real backend phase.
@MainActor
public final class ZiaConversationModel: ObservableObject {
    public static let shared = ZiaConversationModel()

    public struct Turn: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case user
            case assistant
            case failure
        }

        public let id: String
        public let kind: Kind
        public var text: String
        public let timestamp: Date
        public var isWaiting: Bool
    }

    @Published public private(set) var turns: [Turn] = []
    @Published public var draft: String = ""
    @Published public private(set) var isWorking = false
    @Published public private(set) var statusNote: String?

    /// The authoritative backend phase. Published so the window's presence shows
    /// real state instead of guessing from a local flag. Internal because
    /// `InteractionPhase` is an internal engine type.
    @Published private(set) var phase: InteractionPhase = InteractionPhaseCenter.backendPhase

    private var phaseSubscription: UUID?

    private init() {
        phaseSubscription = EventBus.shared.subscribe(InteractionPhaseChangedEvent.self) { [weak self] event in
            guard let self else { return }
            self.phase = event.phase
            guard self.isWorking else { return }
            switch event.phase {
            case .thinking: self.statusNote = "Thinking…"
            case .executing: self.statusNote = "Working…"
            case .understanding: self.statusNote = "Understanding…"
            case .speaking: self.statusNote = nil
            case .success: self.statusNote = nil
            case .error: self.statusNote = nil
            case .stopped: self.statusNote = "Stopped."
            case .listening, .idle: break
            }
        }
    }

    public func loadHistory() {
        HistoryService.shared.loadRecent()
        let restored = HistoryService.shared.turns.map { turn in
            Turn(
                id: turn.id,
                kind: turn.isFromUser ? .user : .assistant,
                text: turn.text,
                timestamp: turn.timestamp,
                isWaiting: false
            )
        }
        // Keep any turns created in this session that are not yet persisted.
        let inFlight = turns.filter { $0.isWaiting }
        turns = restored + inFlight
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// Send a request through the production pipeline.
    public func send(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isWorking else { return }

        draft = ""
        turns.append(Turn(id: UUID().uuidString, kind: .user, text: query, timestamp: .now, isWaiting: false))

        let pendingID = UUID().uuidString
        turns.append(Turn(id: pendingID, kind: .assistant, text: "", timestamp: .now, isWaiting: true))

        isWorking = true
        statusNote = "Thinking…"
        InteractionPhaseCenter.report(.thinking, taskID: "window")

        Task { @MainActor in
            do {
                let response = try await AgentLoop.shared.run(goal: query)
                self.resolve(pendingID, text: response, kind: .assistant)
                InteractionPhaseCenter.report(.success, taskID: "window")
            } catch {
                let message = OverlayViewModel.userFacingMessage(for: error)
                self.resolve(pendingID, text: message, kind: .failure)
                InteractionPhaseCenter.report(.error, taskID: "window")
            }
            self.isWorking = false
            self.statusNote = nil
            InteractionPhaseCenter.report(.idle)
            // Persisted turns now include this exchange.
            self.loadHistory()
        }
    }

    public func stop() {
        VoicePipeline.shared.handleUserStopAction()
        statusNote = "Stopped."
    }

    private func resolve(_ id: String, text: String, kind: Turn.Kind) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].text = text
        turns[index].isWaiting = false
        if kind == .failure {
            turns[index] = Turn(id: turns[index].id, kind: .failure, text: text,
                                 timestamp: turns[index].timestamp, isWaiting: false)
        }
    }
}

// MARK: - Window view

/// The ZiA conversation window.
///
/// Composed like a workspace rather than an application chrome: no header bar,
/// no dividers, no status column. ZiA's presence sits quietly in the corner, the
/// conversation is a centred reading column with real whitespace, and the only
/// persistent controls are the composer and one truthful health word.
struct ZiaWindowView: View {
    @ObservedObject private var model = ZiaConversationModel.shared
    @ObservedObject private var appearance = ZiaAppearanceStore.shared
    @ObservedObject private var activity = ZiaActivityModel.shared
    @ObservedObject private var providers = ZiaProviderModel.shared
    @ObservedObject private var onboarding = ZiaOnboardingStore.shared
    let appState: AppState

    init(appState: AppState = .shared) {
        self.appState = appState
    }

    var body: some View {
        Group {
            if onboarding.isComplete {
                surface
            } else {
                OnboardingView { onboarding.complete() }
            }
        }
        .background(atmosphere)
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(appearance.appearance.colorScheme)
        .onAppear {
            model.loadHistory()
            activity.refresh()
            Task { await providers.refresh() }
        }
    }

    // MARK: Presence

    private var presence: ZiaPresenceState {
        ZiaPresenceState.resolve(phase: model.phase, appEnabled: appState.state != .off)
    }

    /// Deep atmospheric material: the window is never a flat fill. The wash is
    /// tinted by the presence and is otherwise almost invisible.
    private var atmosphere: some View {
        ZStack {
            ZiaColors.background
            RadialGradient(
                colors: [
                    Color(hue: presenceHue, saturation: 0.55, brightness: 0.55, opacity: 0.16),
                    Color.clear
                ],
                center: .init(x: 0.5, y: -0.05),
                startRadius: 8,
                endRadius: 560
            )
            .animation(ZiaMotion.easeOut, value: presence)
        }
    }

    private var presenceHue: Double { presence.hue }

    // MARK: Surface

    private var surface: some View {
        VStack(spacing: 0) {
            identityBar
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if activity.hasActiveWork {
                activeWork
                    .transition(.opacity)
            }
            composerBar
        }
    }

    /// A whisper of identity and one truthful health word. No badges, no
    /// subtitle, no online/offline chip, no window-level buttons beyond Settings.
    private var identityBar: some View {
        HStack(spacing: ZiaSpace.sm) {
            ZiaPresenceOrb(state: presence, size: 20)

            Text("ZiA")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(2.0)
                .foregroundStyle(ZiaColors.textSecondary)

            Spacer(minLength: ZiaSpace.md)

            healthAffordance

            ZiaIconButton(symbol: "gearshape", help: "ZiA Settings", tint: ZiaColors.textTertiary) {
                openSettings()
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    /// One word for the truth. The full detail lives in the tooltip and in
    /// Settings, not permanently on screen.
    private var healthAffordance: some View {
        HStack(spacing: 6) {
            ZiaStatusDot(color: healthColor, diameter: 6)
            Text(healthLabel)
                .font(ZiaType.caption)
                .foregroundStyle(ZiaColors.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openSettings() }
        .help(healthDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ZiA status: \(healthLabel). \(healthDetail)"))
    }

    private var healthLabel: String {
        if providers.totalCount > 0 && providers.availableCount == 0 { return "No model available" }
        if !appState.isOnline { return "Offline" }
        if providers.isDegraded { return "Limited" }
        return "Ready"
    }

    private var healthColor: Color {
        if providers.totalCount > 0 && providers.availableCount == 0 { return ZiaColors.error }
        if !appState.isOnline || providers.isDegraded { return ZiaColors.warning }
        return ZiaColors.success
    }

    private var healthDetail: String {
        let providersLine = providers.totalCount == 0
            ? "Checking providers…"
            : "\(providers.availableCount) of \(providers.totalCount) providers responding."
        let primary = providers.primaryAvailable?.name
        let brain = primary.map { "Primary brain: \($0)." } ?? (providers.localFallback.map { "Primary brain unavailable — using \($0.name)." } ?? "")
        return [providersLine, brain].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Transcript

    private var transcript: some View {
        Group {
            if model.isEmpty {
                ZiaEmptyState(
                    symbol: "sparkles",
                    title: "Ask ZiA anything",
                    message: "Type here, or hold the shortcut from any app. ZiA answers, and acts on your Mac only when you ask."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(model.turns) { turn in
                                ZiaMessageRow(turn: turn, statusNote: model.statusNote)
                                    .id(turn.id)
                            }
                        }
                        .frame(maxWidth: ZiaSpace.readableWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 34)
                        .padding(.top, 46)
                        .padding(.bottom, 30)
                    }
                    .onChange(of: model.turns.count) { _, _ in
                        guard let last = model.turns.last else { return }
                        withAnimation(ZiaMotion.respectingReduceMotion(ZiaMotion.entrance)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Active work

    /// Real tasks, from the authoritative state machine — and only while they
    /// exist. Nothing is reserved on screen for work that is not happening.
    private var activeWork: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.sm) {
            ForEach(activity.tasks) { task in
                ZiaTaskCard(task: task)
            }
        }
        .frame(maxWidth: ZiaSpace.readableWidth)
        .padding(.horizontal, 34)
        .padding(.bottom, ZiaSpace.md)
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composerBar: some View {
        ZiaComposer(
            text: $model.draft,
            isWorking: model.isWorking,
            isListening: presence == .listening,
            placeholder: "Ask ZiA…",
            tone: .surface,
            onSubmit: { model.send($0) },
            onMic: handleMic
        )
        .frame(maxWidth: ZiaSpace.readableWidth)
        .padding(.horizontal, 34)
        .padding(.top, ZiaSpace.md)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.entrance), value: activity.hasActiveWork)
    }

    // MARK: Actions

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The composer's mic is the same control as the HUD's: it drives the real
    /// voice pipeline, and brings the HUD up so the presence is visible while
    /// listening.
    private func handleMic() {
        if VoicePipeline.shared.isRunning {
            VoicePipeline.shared.handleUserStopAction()
        } else {
            if appState.state == .off { appState.transition(to: .sleep) }
            appState.transition(to: .active)
            FloatingPanel.shared.show()
        }
    }
}

// MARK: - Message row

/// One conversation turn. Assistant prose is a reading column that emerges from
/// ZiA's presence — never a chat bubble. User turns are quiet right-aligned
/// typography, so the eye finds them by alignment instead of by container.
struct ZiaMessageRow: View {
    let turn: ZiaConversationModel.Turn
    let statusNote: String?

    @StateObject private var copied = ZiaState(false)
    @StateObject private var hovering = ZiaState(false)

    init(turn: ZiaConversationModel.Turn, statusNote: String? = nil) {
        self.turn = turn
        self.statusNote = statusNote
    }

    var body: some View {
        switch turn.kind {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 80)
                Text(turn.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ZiaColors.textPrimary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .assistant:
            HStack(alignment: .top, spacing: 14) {
                // Only a turn in flight animates; settled turns draw a still
                // frame, so a long conversation costs nothing.
                ZiaPresenceOrb(
                    state: turn.isWaiting ? .thinking : .idle,
                    size: 20,
                    animate: turn.isWaiting
                )

                VStack(alignment: .leading, spacing: 10) {
                    if turn.isWaiting {
                        // No spinner, no bars: one quiet word beside a presence
                        // that is visibly alive.
                        Text(statusNote ?? "Thinking…")
                            .font(.system(size: 14))
                            .foregroundStyle(ZiaColors.textSecondary)
                    } else {
                        Text(turn.text)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .foregroundStyle(ZiaColors.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        copyAffordance
                            .opacity(hovering.value || copied.value ? 1 : 0)
                    }
                }

                Spacer(minLength: 24)
            }
            .onHover { hovering.value = $0 }
            .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.easeOut), value: hovering.value)

        case .failure:
            ZiaErrorView(
                title: "That didn't work",
                message: turn.text,
                recovery: []
            )
        }
    }

    private var copyAffordance: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(turn.text, forType: .string)
            copied.value = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied.value = false
            }
        } label: {
            Label(copied.value ? "Copied" : "Copy", systemImage: copied.value ? "checkmark" : "doc.on.doc")
                .font(ZiaType.caption)
                .foregroundStyle(copied.value ? ZiaColors.success : ZiaColors.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Copy this answer")
        .accessibilityLabel(Text(copied.value ? "Copied" : "Copy this answer"))
    }
}
