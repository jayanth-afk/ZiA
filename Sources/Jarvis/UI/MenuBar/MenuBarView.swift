import SwiftUI
import AppKit

/// The menu bar dropdown.
///
/// Compact by design: identity and status, then only the actions that can
/// actually be taken. Health details are surfaced as a single line and only when
/// something is actually wrong — the popover is not a dashboard.
struct MenuBarView: View {
    let appState: AppState
    @ObservedObject private var activity = ZiaActivityModel.shared
    @ObservedObject private var providerModel = ZiaProviderModel.shared
    @ObservedObject private var history = HistoryService.shared
    @ObservedObject private var permissionModel = ZiaPermissionModel.shared
    @StateObject private var status = MenuBarStatusModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            actions
            if !history.turns.isEmpty {
                divider
                MenuHistorySection()
                    .padding(.horizontal, ZiaSpace.lg)
                    .padding(.vertical, ZiaSpace.md)
            }
            if activity.hasActiveWork {
                divider
                activeTask
            }
            if let warning = systemWarning {
                divider
                warningRow(warning)
            }
            divider
            footer
        }
        .background(ZiaColors.background)
        .onAppear {
            activity.refresh()
            permissionModel.refresh()
            status.start()
            Task { await providerModel.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ZiaSpace.sm) {
            ZiaPresenceOrb(state: presence, size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("ZiA")
                    .font(ZiaType.identity)
                    .foregroundStyle(ZiaColors.textPrimary)
                Text(presence.hint ?? presence.label)
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZiaSpace.lg)
        .padding(.vertical, ZiaSpace.md)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuButton("Ask ZiA", symbol: "sparkles", shortcut: "⌥Space") {
                ZiaWindowController.shared.show()
            }

            if appState.state == .active {
                menuButton("Stop listening", symbol: "stop.circle") {
                    VoicePipeline.shared.handleUserStopAction()
                }
            } else {
                menuButton("Start listening", symbol: "waveform") {
                    if appState.state == .off { appState.transition(to: .sleep) }
                    appState.transition(to: .active)
                    FloatingPanel.shared.show()
                }
            }

            menuButton("Open ZiA", symbol: "macwindow.on.rectangle") {
                FloatingPanel.shared.toggle()
            }

            menuButton(appState.state == .off ? "Enable ZiA" : "Disable ZiA",
                       symbol: appState.state == .off ? "play.fill" : "pause.fill") {
                appState.transition(to: appState.state == .off ? .sleep : .off)
            }

            menuButton("Settings…", symbol: "gearshape") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(.horizontal, ZiaSpace.sm)
        .padding(.vertical, ZiaSpace.sm)
    }

    // MARK: - Active task (only when one exists)

    @ViewBuilder
    private var activeTask: some View {
        if let task = activity.tasks.first {
            VStack(alignment: .leading, spacing: ZiaSpace.sm) {
                HStack {
                    Text("CURRENT TASK")
                        .font(ZiaType.metadata)
                        .tracking(0.6)
                        .foregroundStyle(ZiaColors.textTertiary)
                    Spacer(minLength: 0)
                    ZiaButton("View", variant: .ghost, size: .small) {
                        ZiaWindowController.shared.show()
                    }
                }
                Text(task.title)
                    .font(ZiaType.body)
                    .foregroundStyle(ZiaColors.textPrimary)
                    .lineLimit(2)
                if let step = task.steps.first(where: { $0.state != .completed }) {
                    Text(step.description)
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, ZiaSpace.lg)
            .padding(.vertical, ZiaSpace.md)
        }
    }

    // MARK: - Truthful warning (only when something is actually wrong)

    private struct SystemWarning {
        let symbol: String
        let text: String
        let tint: Color
    }

    private var systemWarning: SystemWarning? {
        if providerModel.totalCount > 0 && providerModel.availableCount == 0 {
            return SystemWarning(symbol: "exclamationmark.triangle.fill",
                                 text: "No model available — open Settings › AI Providers.",
                                 tint: ZiaColors.error)
        }
        if !appState.isOnline {
            return SystemWarning(symbol: "wifi.slash",
                                 text: "Offline — local work continues.",
                                 tint: ZiaColors.warning)
        }
        if appState.memoryPressure == .critical {
            return SystemWarning(symbol: "memorychip",
                                 text: "Memory pressure critical — local models may be paused.",
                                 tint: ZiaColors.warning)
        }
        if !permissionModel.allGranted {
            let missing = permissionModel.items.filter { !$0.enabled }.count
            return SystemWarning(symbol: "lock.fill",
                                 text: "\(missing) permission\(missing == 1 ? "" : "s") not granted — voice or computer control is limited.",
                                 tint: ZiaColors.warning)
        }
        return nil
    }

    private func warningRow(_ warning: SystemWarning) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZiaSpace.sm) {
            Image(systemName: warning.symbol)
                .font(.system(size: ZiaMetric.iconSm))
                .foregroundStyle(warning.tint)
                .frame(width: 14)
            Text(warning.text)
                .font(ZiaType.caption)
                .foregroundStyle(ZiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ZiaSpace.lg)
        .padding(.vertical, ZiaSpace.md)
    }

    private var footer: some View {
        HStack {
            ZiaButton("Quit ZiA", symbol: "power", variant: .ghost, size: .small) {
                NSApp.terminate(nil)
            }
            Spacer(minLength: 0)
            Text(ZiaBuildInfo.shortVersion)
                .font(ZiaType.metadata)
                .foregroundStyle(ZiaColors.textTertiary)
        }
        .padding(.horizontal, ZiaSpace.lg)
        .padding(.vertical, ZiaSpace.sm)
    }

    private var divider: some View {
        Rectangle().fill(ZiaColors.separator).frame(height: 1)
    }

    // MARK: - Helpers

    private func menuButton(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        MenuRowButton(title: title, symbol: symbol, shortcut: shortcut, action: action)
    }

    private var presence: ZiaPresenceState {
        ZiaPresenceState.resolve(phase: status.phase, appEnabled: appState.state != .off)
    }
}

/// Observes the real interaction phase so the popover header is never stale.
@MainActor
private final class MenuBarStatusModel: ObservableObject {
    @Published var phase: InteractionPhase = InteractionPhaseCenter.backendPhase
    private var subscription: UUID?

    func start() {
        guard subscription == nil else { return }
        phase = InteractionPhaseCenter.backendPhase
        subscription = EventBus.shared.subscribe(InteractionPhaseChangedEvent.self) { [weak self] event in
            Task { @MainActor in self?.phase = event.phase }
        }
    }
}

/// A menu row with hover feedback and an optional shortcut hint.
private struct MenuRowButton: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void

    @StateObject private var hovering = ZiaState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZiaSpace.sm) {
                Image(systemName: symbol)
                    .font(.system(size: ZiaMetric.iconMd))
                    .foregroundStyle(ZiaColors.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(ZiaType.body)
                    .foregroundStyle(ZiaColors.textPrimary)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(ZiaType.metadata)
                        .foregroundStyle(ZiaColors.textTertiary)
                }
            }
            .padding(.horizontal, ZiaSpace.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                    .fill(hovering.value ? ZiaColors.surfaceHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

/// Bounded recent transcript through the HistoryService boundary — never SQLite
/// internals. Only what has really been said appears here.
struct MenuHistorySection: View {
    @ObservedObject private var history = HistoryService.shared
    @StateObject private var showAll = ZiaState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.sm) {
            HStack {
                Text("RECENT")
                    .font(ZiaType.metadata)
                    .tracking(0.6)
                    .foregroundStyle(ZiaColors.textTertiary)
                Spacer(minLength: 0)
                if showAll.value {
                    Button("Show less") {
                        showAll.value = false
                        history.loadRecent()
                    }
                    .buttonStyle(.plain)
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
                } else if history.turns.count > 3 {
                    Button("Older") {
                        showAll.value = true
                        _ = history.loadOlder()
                    }
                    .buttonStyle(.plain)
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
                }
            }

            if history.turns.isEmpty {
                Text("No conversation yet. Ask ZiA anything to get started.")
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: ZiaSpace.sm) {
                    ForEach((showAll.value ? history.turns : Array(history.turns.suffix(3)))) { turn in
                        HStack(alignment: .top, spacing: ZiaSpace.sm) {
                            Image(systemName: turn.isFromUser ? "person.fill" : "sparkle")
                                .font(.system(size: ZiaMetric.iconSm))
                                .foregroundStyle(turn.isFromUser ? ZiaColors.textTertiary : ZiaColors.presence)
                                .frame(width: 14)
                            Text(turn.text)
                                .font(ZiaType.caption)
                                .lineLimit(2)
                                .foregroundStyle(ZiaColors.textSecondary)
                        }
                    }
                }
            }
        }
        .onAppear { history.loadRecent() }
    }
}
