import SwiftUI
import AppKit

// MARK: - Settings root

/// ZiA Settings — a native macOS sidebar layout.
///
/// Every control here writes to a real, persisted value that something in the
/// running system actually reads. Where a behaviour is automatic by design
/// (automatic endpointing, wake aliases, barge-in) it is explained rather than
/// exposed as a meaningless slider.
public struct SettingsView: View {
    public init() {}

    @ObservedObject private var appearance = ZiaAppearanceStore.shared
    @StateObject private var selection = ZiaState(SettingsSection.general)

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(ZiaColors.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
                    Text(selection.value.title)
                        .font(ZiaType.largeTitle)
                        .foregroundStyle(ZiaColors.textPrimary)
                        .padding(.bottom, ZiaSpace.xs)

                    sectionContent
                }
                .frame(maxWidth: ZiaSpace.readableWidth + 160, alignment: .leading)
                .padding(.horizontal, ZiaSpace.xxl + 4)
                .padding(.vertical, ZiaSpace.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ZiaColors.background)
        }
        .frame(width: 820, height: 580)
        .preferredColorScheme(appearance.appearance.colorScheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ZiaSpace.sm) {
                ZiaPresenceOrb(state: .idle, size: 24)
                Text("ZiA")
                    .font(ZiaType.identity)
                    .foregroundStyle(ZiaColors.textPrimary)
            }
            .padding(.horizontal, ZiaSpace.md)
            .padding(.top, ZiaSpace.xl)
            .padding(.bottom, ZiaSpace.md)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    SettingsSidebarRow(
                        item: item,
                        isSelected: selection.value == item,
                        action: { selection.value = item }
                    )
                }
            }
            .padding(.horizontal, ZiaSpace.sm)

            Spacer(minLength: 0)
        }
        .frame(width: 208)
        .background(ZiaColors.backgroundSecondary)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection.value {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .voice: VoiceSettingsView()
        case .intelligence: ModelSettingsView()
        case .providers: ProviderSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .permissions: PermissionSettingsView()
        case .notifications: NotificationSettingsView()
        case .privacy: MemoryPrivacySettingsView()
        case .advanced: HealthDiagnosticsSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, voice, intelligence, providers, shortcuts, permissions, notifications, privacy, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .voice: return "Voice"
        case .intelligence: return "Intelligence"
        case .providers: return "AI Providers"
        case .shortcuts: return "Shortcuts"
        case .permissions: return "Permissions"
        case .notifications: return "Notifications"
        case .privacy: return "Privacy & Memory"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .voice: return "waveform"
        case .intelligence: return "cpu"
        case .providers: return "sparkles"
        case .shortcuts: return "keyboard"
        case .permissions: return "lock.shield"
        case .notifications: return "bell"
        case .privacy: return "hand.raised"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsSidebarRow: View {
    let item: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @StateObject private var hovering = ZiaState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZiaSpace.sm) {
                Image(systemName: item.symbol)
                    .font(.system(size: ZiaMetric.iconMd))
                    .foregroundStyle(isSelected ? Color.white : ZiaColors.textSecondary)
                    .frame(width: 16)
                Text(item.title)
                    .font(ZiaType.body)
                    .foregroundStyle(isSelected ? Color.white : ZiaColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZiaSpace.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ZiaRadius.sm, style: .continuous)
                    .fill(isSelected ? ZiaColors.accent : (hovering.value ? ZiaColors.surfaceHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - General

/// Owns General-pane values so they survive view re-creation without `@State`.
@MainActor
final class GeneralSettingsModel: ObservableObject {
    @Published var voiceEnabled = Config.shared.voiceEnabled
    @Published var autonomy = Config.shared.autonomyLevel

    func setVoiceEnabled(_ enabled: Bool) {
        voiceEnabled = enabled
        Config.shared.voiceEnabled = enabled
        // The pipeline reacts to the real app state, so toggling this must move
        // the state machine rather than just flipping a flag.
        AppState.shared.transition(to: enabled ? .sleep : .off)
    }

    func setAutonomy(_ level: Int) {
        autonomy = level
        Config.shared.autonomyLevel = level
    }
}

struct GeneralSettingsView: View {
    @StateObject private var model = GeneralSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaSection(
                "Assistant",
                footnote: "Disabling ZiA keeps it resident but silent — it stops listening and will not act."
            ) {
                ZiaToggleRow(
                    "Voice pipeline",
                    detail: "Turn on speech capture, on-device recognition and spoken replies.",
                    symbol: "waveform",
                    isOn: Binding(
                        get: { model.voiceEnabled },
                        set: { model.setVoiceEnabled($0) }
                    )
                )
                ZiaDivider()
                ZiaSettingRow("Language", detail: "Used for responses and recognition.", symbol: "globe") {
                    Text(PreferenceStore.shared.current.preferredLanguage.uppercased())
                        .font(ZiaType.body)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
                ZiaDivider()
                ZiaSettingRow("Hardware", detail: "ZiA is tuned for Apple Silicon.", symbol: "laptopcomputer") {
                    Text(ProcessInfo.processInfo.machineHardware)
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
            }

            ZiaSection(
                "Autonomy",
                footnote: (AutonomyLevel(rawValue: model.autonomy)?.summary ?? "")
                    + " ZiA still passes every action through the permission gate, sandbox and verification."
            ) {
                ZiaSettingRow("Permission level", detail: "How much ZiA may decide on its own.", symbol: "shield.lefthalf.filled") {
                    Picker("", selection: Binding(
                        get: { model.autonomy },
                        set: { model.setAutonomy($0) }
                    )) {
                        ForEach(AutonomyLevel.allCases, id: \.rawValue) { level in
                            Text(level.title).tag(level.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }
            }

            UserPreferencesSettingsView()
        }
    }
}

/// Tone, verbosity and confirmation behaviour — all real, persisted preferences.
struct UserPreferencesSettingsView: View {
    @ObservedObject private var prefs = PreferenceStoreObservable.shared

    var body: some View {
        ZiaSection("Responses") {
            ZiaSettingRow("Verbosity", detail: nil, symbol: "text.alignleft") {
                Picker("", selection: Binding(
                    get: { prefs.current.verbosity },
                    set: { value in PreferenceStore.shared.updateExplicit { $0.verbosity = value } }
                )) {
                    Text("Concise").tag(ResponseVerbosity.concise)
                    Text("Normal").tag(ResponseVerbosity.normal)
                    Text("Detailed").tag(ResponseVerbosity.detailed)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ZiaDivider()
            ZiaSettingRow("Style", detail: nil, symbol: "text.bubble") {
                Picker("", selection: Binding(
                    get: { prefs.current.style },
                    set: { value in PreferenceStore.shared.updateExplicit { $0.style = value } }
                )) {
                    Text("Direct").tag(ResponseStyle.direct)
                    Text("Friendly").tag(ResponseStyle.friendly)
                    Text("Technical").tag(ResponseStyle.technical)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ZiaDivider()
            ZiaSettingRow(
                "Confirmation",
                detail: "When ZiA must ask before acting.",
                symbol: "hand.raised"
            ) {
                Picker("", selection: Binding(
                    get: { prefs.current.confirmation },
                    set: { value in PreferenceStore.shared.updateExplicit { $0.confirmation = value } }
                )) {
                    Text("Destructive actions").tag(ConfirmationPreference.askForDestructive)
                    Text("All external actions").tag(ConfirmationPreference.askForExternal)
                    Text("Minimal").tag(ConfirmationPreference.minimal)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
            }
        }
    }
}

/// Bridges the non-observable `PreferenceStore` into SwiftUI.
@MainActor
final class PreferenceStoreObservable: ObservableObject {
    static let shared = PreferenceStoreObservable()

    @Published private(set) var current = PreferenceStore.shared.current

    private init() {}

    /// Re-read after a write so the UI reflects the persisted value.
    func refresh() {
        current = PreferenceStore.shared.current
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = ZiaAppearanceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaSection(
                "Theme",
                footnote: "ZiA follows the system theme by default and applies your choice to every window, the overlay and the menu bar."
            ) {
                ZiaSettingRow("Appearance", detail: "Applies immediately.", symbol: appearance.appearance.symbol) {
                    Picker("", selection: $appearance.appearance) {
                        ForEach(ZiaAppearance.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                ZiaDivider()
                ZiaSettingRow(
                    "Reduce motion",
                    detail: "Controlled by macOS. ZiA already pauses its presence animation when this is on.",
                    symbol: "figure.walk"
                ) {
                    ZiaBadge(
                        ZiaMotion.reduceMotion ? "On" : "Off",
                        tint: ZiaMotion.reduceMotion ? ZiaColors.success : ZiaColors.textTertiary
                    )
                }
            }

            ZiaSection("Presence") {
                HStack(spacing: ZiaSpace.xxl) {
                    presenceSample(.idle, "Idle")
                    presenceSample(.listening, "Listening")
                    presenceSample(.working, "Working")
                    presenceSample(.speaking, "Speaking")
                }
                .padding(ZiaSpace.lg)
            }
        }
    }

    private func presenceSample(_ state: ZiaPresenceState, _ label: String) -> some View {
        VStack(spacing: ZiaSpace.sm) {
            ZiaPresenceOrb(state: state, size: 40)
            Text(label)
                .font(ZiaType.caption)
                .foregroundStyle(ZiaColors.textSecondary)
        }
    }
}
