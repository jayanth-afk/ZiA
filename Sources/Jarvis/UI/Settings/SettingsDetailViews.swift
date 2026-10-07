import SwiftUI
import AppKit

// MARK: - Voice

/// Voice pane state. Everything shown here reads live system state; nothing is
/// a placeholder.
@MainActor
final class VoiceSettingsModel: ObservableObject {
    @Published var aliases: [String] = Config.shared.wakeAliases
    @Published var newAlias: String = ""
    @Published var permissions: [ZiaPermissionModel.Item] = ZiaPermissionModel.shared.items

    var microphoneItem: ZiaPermissionModel.Item? {
        permissions.first { $0.kind == .microphone }
    }

    func addAlias() {
        let value = newAlias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !aliases.contains(value) else { return }
        aliases.append(value)
        Config.shared.wakeAliases = aliases
        newAlias = ""
    }

    func removeAlias(_ alias: String) {
        guard aliases.count > 1 else { return }
        aliases.removeAll { $0 == alias }
        Config.shared.wakeAliases = aliases
    }

    func refresh() {
        ZiaPermissionModel.shared.refresh()
        permissions = ZiaPermissionModel.shared.items
    }
}

struct VoiceSettingsView: View {
    @StateObject private var model = VoiceSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaCard(
                title: "Microphone",
                subtitle: AudioDiagnostic.shared.currentInputDeviceName() ?? "No input device detected",
                symbol: "mic"
            ) {
                HStack(spacing: ZiaSpace.sm) {
                    ZiaStatusDot(
                        color: AudioCapture.shared.isCapturing ? ZiaColors.success : ZiaColors.textTertiary,
                        pulsing: AudioCapture.shared.isCapturing
                    )
                    Text(AudioCapture.shared.isCapturing ? "Capturing" : "Idle")
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                    Spacer(minLength: 0)
                    if let item = model.microphoneItem, !item.enabled {
                        ZiaButton("Grant access", variant: .secondary, size: .small) {
                            if let url = URL(string: item.systemSettingsURL) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }

            ZiaCard(title: "Speech recognition", subtitle: "Apple Speech · on-device", symbol: "text.bubble") {
                VStack(alignment: .leading, spacing: ZiaSpace.sm) {
                    infoLine("Recognition available", SpeechRecognizer.shared.recognizerAvailable ? "Yes" : "No")
                    infoLine("On-device support", SpeechRecognizer.shared.supportsOnDeviceRecognition ? "Yes" : "No")
                    infoLine("Status", SpeechRecognizer.shared.authorizationStatus.rawValue)
                    Text("Recognition runs entirely on this Mac. No audio or transcript leaves the device for transcription.")
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZiaSection(
                "Automatic endpointing",
                footnote: "ZiA detects the end of your sentence from live audio and partial-transcript context, then finalises the request. There is no threshold to tune, and you never need to press Stop to finish a sentence."
            ) {
                ZiaSettingRow("Behaviour", detail: "Always on for spoken requests.", symbol: "waveform.badge.mic") {
                    ZiaBadge("Automatic", symbol: "checkmark", tint: ZiaColors.success)
                }
                ZiaDivider()
                ZiaSettingRow(
                    "Barge-in",
                    detail: "Speaking while ZiA talks stops playback immediately. This is a safety behaviour, so it is not switchable.",
                    symbol: "hand.raised.fill"
                ) {
                    ZiaBadge("Always on", symbol: "lock", tint: ZiaColors.textTertiary)
                }
            }

            ZiaSection("Wake word", footnote: "ZiA listens for these words to start a turn. Say one, then your request.") {
                ForEach(model.aliases, id: \.self) { alias in
                    ZiaSettingRow(alias.capitalized, detail: nil, symbol: "quote.bubble") {
                        if model.aliases.count > 1 {
                            ZiaIconButton(symbol: "minus.circle", help: "Remove wake word", tint: ZiaColors.textTertiary) {
                                model.removeAlias(alias)
                            }
                        }
                    }
                    ZiaDivider()
                }
                HStack(spacing: ZiaSpace.sm) {
                    TextField("Add a wake word", text: $model.newAlias)
                        .textFieldStyle(.plain)
                        .font(ZiaType.body)
                        .padding(.horizontal, ZiaSpace.sm)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                                .fill(ZiaColors.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                                .strokeBorder(ZiaColors.border, lineWidth: 1)
                        )
                    ZiaButton(
                        "Add",
                        variant: .secondary,
                        size: .small,
                        isEnabled: !model.newAlias.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        model.addAlias()
                    }
                }
                .padding(.horizontal, ZiaSpace.lg)
                .padding(.vertical, ZiaSpace.md)
            }
        }
        .onAppear { model.refresh() }
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(ZiaType.caption).foregroundStyle(ZiaColors.textSecondary)
            Spacer(minLength: ZiaSpace.md)
            Text(value).font(ZiaType.caption).foregroundStyle(ZiaColors.textPrimary)
        }
    }
}

// MARK: - Intelligence

@MainActor
final class IntelligenceSettingsModel: ObservableObject {
    @Published var reflex = Config.shared.localReflexModel
    @Published var normal = Config.shared.localNormalModel
    @Published var budget = Config.shared.dailyBudgetUSD
    /// Models already present in the local cache. Only these can be loaded.
    @Published var cachedLocalModels = LocalModelCatalog.cachedModelIDs()

    func commitReflex() { Config.shared.localReflexModel = reflex }
    func commitNormal() { Config.shared.localNormalModel = normal }
    func commitBudget() { Config.shared.dailyBudgetUSD = budget }
}

struct ModelSettingsView: View {
    @StateObject private var model = IntelligenceSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaSection(
                "Routing order",
                footnote: "ZiA always tries the cheapest sufficient intelligence first. Deterministic actions need no model at all, which is why many commands complete instantly and offline."
            ) {
                routingRow(1, "Deterministic actions", "No model · under a millisecond", ZiaColors.success, "bolt.fill")
                ZiaDivider()
                routingRow(2, "ChatGPT Desktop", "Primary brain for reasoning", ZiaColors.accent, "sparkles")
                ZiaDivider()
                routingRow(3, "Local models (MLX)", "On-device fallback, works offline", ZiaColors.info, "cpu")
                ZiaDivider()
                routingRow(4, "Cloud providers", "Only when configured and needed", ZiaColors.textTertiary, "cloud")
            }

            ZiaSection(
                "Local models",
                footnote: "ZiA only ever loads a model whose weights are already cached on disk — it never downloads one at runtime. A name that is not cached is ignored in favour of a cached model."
            ) {
                ZiaSettingRow("Reflex model", detail: "Small, fast intent classification.", symbol: "bolt") {
                    TextField("", text: $model.reflex)
                        .textFieldStyle(.plain)
                        .font(ZiaType.code)
                        .frame(width: 230)
                        .onSubmit { model.commitReflex() }
                }
                ZiaDivider()
                ZiaSettingRow("Normal model", detail: "General local reasoning.", symbol: "cpu") {
                    TextField("", text: $model.normal)
                        .textFieldStyle(.plain)
                        .font(ZiaType.code)
                        .frame(width: 230)
                        .onSubmit { model.commitNormal() }
                }
                ZiaDivider()
                ZiaSettingRow("Cached on disk", detail: "Only cached models can run.", symbol: "internaldrive") {
                    Text(model.cachedLocalModels.isEmpty ? "none" : model.cachedLocalModels.joined(separator: ", "))
                        .font(ZiaType.code)
                        .foregroundStyle(model.cachedLocalModels.isEmpty ? ZiaColors.warning : ZiaColors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }

            ZiaSection("Budget", footnote: "A ceiling for external providers. Local work is never billed and never blocked by this.") {
                ZiaSettingRow("Daily cloud budget", detail: nil, symbol: "dollarsign.circle") {
                    HStack(spacing: ZiaSpace.sm) {
                        Text(String(format: "$%.2f", model.budget))
                            .font(ZiaType.body)
                            .foregroundStyle(ZiaColors.textPrimary)
                            .frame(width: 60, alignment: .trailing)
                        Stepper("", value: $model.budget, in: 0...100, step: 1)
                            .labelsHidden()
                            .onChange(of: model.budget) { _, _ in model.commitBudget() }
                    }
                }
            }
        }
    }

    private func routingRow(_ index: Int, _ title: String, _ detail: String, _ tint: Color, _ symbol: String) -> some View {
        ZiaSettingRow(title, detail: detail, symbol: symbol) {
            ZiaBadge("Step \(index)", tint: tint)
        }
    }
}

// MARK: - Providers

struct ProviderSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaCard(
                title: "What is answering right now",
                subtitle: "Probed live — a provider is only shown as ready when it actually responded.",
                symbol: "sparkles"
            ) {
                ZiaProviderCard()
            }

            APIKeysView(embedded: true)
        }
    }
}

// MARK: - Shortcuts

@MainActor
final class ShortcutSettingsModel: ObservableObject {
    @Published var hotkeyEnabled = Config.shared.hotkeyEnabled

    func setEnabled(_ enabled: Bool) {
        hotkeyEnabled = enabled
        Config.shared.hotkeyEnabled = enabled
    }
}

struct ShortcutSettingsView: View {
    @StateObject private var model = ShortcutSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaSection(
                "Global shortcut",
                footnote: "The shortcut works from any application. ZiA reacts to it without moving your windows or changing Spaces."
            ) {
                ZiaToggleRow(
                    "Enable global shortcut",
                    detail: "Takes effect the next time ZiA starts.",
                    symbol: "keyboard",
                    isOn: Binding(
                        get: { model.hotkeyEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                ZiaDivider()
                ZiaSettingRow("Show or hide ZiA", detail: nil, symbol: "command") {
                    KeyboardKeyHints(keys: ["⌥", "Space"])
                }
            }

            ZiaSection("While using ZiA") {
                shortcutRow("Send a request", ["↩"])
                ZiaDivider()
                shortcutRow("New line", ["⇧", "↩"])
                ZiaDivider()
                shortcutRow("Finish speaking or stop", ["⎋"])
            }
        }
    }

    private func shortcutRow(_ title: String, _ keys: [String]) -> some View {
        ZiaSettingRow(title, detail: nil, symbol: nil) {
            KeyboardKeyHints(keys: keys)
        }
    }
}

struct KeyboardKeyHints: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(ZiaType.metadata)
                    .foregroundStyle(ZiaColors.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(ZiaColors.surfaceHover)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(ZiaColors.border, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Permissions

struct PermissionSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaCard(
                title: "What ZiA can use",
                subtitle: "Nothing is requested that ZiA does not use.",
                symbol: "lock.shield"
            ) {
                ZiaPermissionCard()
            }

            ZiaSection(
                "Why each permission matters",
                footnote: "Revoking a permission never weakens ZiA's safety guarantees — it only reduces what ZiA can do."
            ) {
                explanationRow("Microphone", "Hearing a wake word and your spoken request. Without it, voice and hands-free use are unavailable; typing still works.")
                ZiaDivider()
                explanationRow("Speech Recognition", "Turning speech into text locally. Without it, ZiA cannot understand spoken requests.")
                ZiaDivider()
                explanationRow("Accessibility", "Inspecting and clicking controls in other apps. ZiA can do everything else without it.")
            }
        }
    }

    private func explanationRow(_ title: String, _ detail: String) -> some View {
        ZiaSettingRow(title, detail: detail, symbol: nil) { EmptyView() }
    }
}

// MARK: - Notifications

@MainActor
final class NotificationSettingsModel: ObservableObject {
    @Published var onCompletion = PreferenceStore.shared.current.notifyOnCompletion
    @Published var onFailure = PreferenceStore.shared.current.notifyOnFailure

    func setCompletion(_ value: Bool) {
        onCompletion = value
        PreferenceStore.shared.updateExplicit { $0.notifyOnCompletion = value }
        PreferenceStoreObservable.shared.refresh()
    }

    func setFailure(_ value: Bool) {
        onFailure = value
        PreferenceStore.shared.updateExplicit { $0.notifyOnFailure = value }
        PreferenceStoreObservable.shared.refresh()
    }
}

struct NotificationSettingsView: View {
    @StateObject private var model = NotificationSettingsModel()

    var body: some View {
        ZiaSection(
            "Tell me when…",
            footnote: "ZiA never notifies you because it merely did something small — only when a task ends, or when it needs you."
        ) {
            ZiaToggleRow(
                "A task finishes",
                detail: "Useful for work that runs while you are in another app.",
                symbol: "checkmark.circle",
                isOn: Binding(get: { model.onCompletion }, set: { model.setCompletion($0) })
            )
            ZiaDivider()
            ZiaToggleRow(
                "A task fails",
                detail: "So a failed action never goes unnoticed.",
                symbol: "exclamationmark.triangle",
                isOn: Binding(get: { model.onFailure }, set: { model.setFailure($0) })
            )
        }
    }
}

// MARK: - Privacy & memory

@MainActor
final class PrivacySettingsModel: ObservableObject {
    @Published var localOnly = PreferenceStore.shared.current.localOnly
    @Published var backgroundWork = PreferenceStore.shared.current.backgroundWork ?? false
    @Published var factCount = UserProfile.shared.allFacts.count
    @Published var memoryCount = ZiaMemoryStore.shared.count
    @Published var purgeConfirm = false

    func setLocalOnly(_ value: Bool) {
        localOnly = value
        PreferenceStore.shared.updateExplicit { $0.localOnly = value }
        PreferenceStoreObservable.shared.refresh()
    }

    func setBackgroundWork(_ value: Bool) {
        backgroundWork = value
        PreferenceStore.shared.updateExplicit { $0.backgroundWork = value }
        PreferenceStoreObservable.shared.refresh()
    }

    func purge() {
        UserProfile.shared.clearAll()
        MemoryManager.shared.clearAll()
        factCount = UserProfile.shared.allFacts.count
        memoryCount = ZiaMemoryStore.shared.count
        purgeConfirm = false
    }
}

struct MemoryPrivacySettingsView: View {
    @StateObject private var model = PrivacySettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaSection(
                "Data boundaries",
                footnote: "Local-only mode is a hard boundary: no request text leaves this Mac, even for a provider you have configured."
            ) {
                ZiaToggleRow(
                    "Local-only mode",
                    detail: "Block all external requests. Local models keep working.",
                    symbol: "hand.raised",
                    isOn: Binding(get: { model.localOnly }, set: { model.setLocalOnly($0) })
                )
                ZiaDivider()
                ZiaToggleRow(
                    "Background work",
                    detail: "Allow ZiA to continue long tasks while you are away. Requires an autonomy level of L4 or above.",
                    symbol: "clock.arrow.circlepath",
                    isOn: Binding(get: { model.backgroundWork }, set: { model.setBackgroundWork($0) })
                )
                ZiaDivider()
                ZiaSettingRow(
                    "Conversation storage",
                    detail: "Stored locally in SQLite on this Mac.",
                    symbol: "externaldrive"
                ) {
                    ZiaBadge(
                        ConversationStore.shared.isPersistentStorage ? "Local" : "In-memory",
                        tint: ConversationStore.shared.isPersistentStorage ? ZiaColors.success : ZiaColors.warning
                    )
                }
            }

            ZiaSection("Memory") {
                ZiaSettingRow("Stored facts", detail: "Things you asked ZiA to remember.", symbol: "brain") {
                    Text("\(model.factCount)")
                        .font(ZiaType.body)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
                ZiaDivider()
                ZiaSettingRow("Structured records", detail: "Trust-classified memories.", symbol: "tray.full") {
                    Text("\(model.memoryCount)")
                        .font(ZiaType.body)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
                ZiaDivider()
                ZiaSettingRow(
                    "Forget everything",
                    detail: "Deletes stored facts and structured memories. This cannot be undone.",
                    symbol: "trash"
                ) {
                    if model.purgeConfirm {
                        HStack(spacing: ZiaSpace.sm) {
                            ZiaButton("Confirm", variant: .destructive, size: .small) { model.purge() }
                            ZiaButton("Cancel", variant: .ghost, size: .small) { model.purgeConfirm = false }
                        }
                    } else {
                        ZiaButton("Forget…", variant: .secondary, size: .small) { model.purgeConfirm = true }
                    }
                }
            }
        }
    }
}

// MARK: - Advanced / diagnostics

@MainActor
final class DiagnosticsSettingsModel: ObservableObject {
    @Published var report: HealthReport?
    @Published var refreshing = false
    @Published var showAllCapabilities = false

    var capabilities: [CapabilityDescriptor] {
        let all = CapabilityRegistry.descriptors()
        return showAllCapabilities ? all : Array(all.prefix(8))
    }

    func load() async {
        guard !refreshing else { return }
        refreshing = true
        // Explicit user action: perform the bounded live model probes too.
        report = await HealthService.shared.report(verifyExternalModels: true)
        refreshing = false
    }

    func tint(for status: HealthStatus) -> Color {
        switch status {
        case .healthy: return ZiaColors.success
        case .degraded, .disabled, .notConfigured: return ZiaColors.warning
        case .unavailable, .permissionBlocked: return ZiaColors.error
        case .unknown: return ZiaColors.textTertiary
        }
    }

    var healthTint: Color {
        switch report?.overall {
        case .healthy: return ZiaColors.success
        case .degraded: return ZiaColors.warning
        case .unavailable, .permissionBlocked: return ZiaColors.error
        default: return ZiaColors.textSecondary
        }
    }
}

struct HealthDiagnosticsSettingsView: View {
    @StateObject private var model = DiagnosticsSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaCard(
                title: "System health",
                subtitle: model.report.map { "Overall: \($0.overall.rawValue)" } ?? "Checking…",
                symbol: "cross.case",
                tint: model.healthTint,
                trailing: AnyView(
                    ZiaIconButton(symbol: "arrow.clockwise", help: "Re-run diagnostics") {
                        Task { await model.load() }
                    }
                )
            ) {
                if let report = model.report {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(report.components.enumerated()), id: \.offset) { index, component in
                            if index > 0 { ZiaDivider() }
                            ZiaSettingRow(
                                component.name.replacingOccurrences(of: "-", with: " ").capitalized,
                                detail: component.detail,
                                symbol: nil
                            ) {
                                ZiaBadge(component.status.rawValue, tint: model.tint(for: component.status))
                            }
                        }
                    }
                } else {
                    ZiaEmptyState(
                        symbol: "ellipsis.circle",
                        title: "Checking subsystems",
                        message: "Reading live status from each subsystem."
                    )
                    .frame(height: 120)
                }
            }

            ZiaSection(
                "Capabilities",
                footnote: "Derived from the live tool registry — the same list ZiA reasons about when you ask what it can do."
            ) {
                ForEach(Array(model.capabilities.enumerated()), id: \.offset) { index, capability in
                    if index > 0 { ZiaDivider() }
                    ZiaSettingRow(capability.name, detail: capability.purpose, symbol: nil) {
                        ZiaBadge(
                            capability.availability,
                            tint: capability.availability.contains("blocked") ? ZiaColors.warning : ZiaColors.textTertiary
                        )
                    }
                }
                ZiaDivider()
                HStack {
                    ZiaButton(
                        model.showAllCapabilities ? "Show fewer" : "Show all capabilities",
                        variant: .ghost,
                        size: .small
                    ) {
                        model.showAllCapabilities.toggle()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ZiaSpace.lg)
                .padding(.vertical, ZiaSpace.sm)
            }

            ZiaSection("Runtime") {
                diagRow("Voice pipeline", VoicePipeline.shared.isRunning ? "Running" : "Stopped")
                ZiaDivider()
                diagRow("Microphone", AudioCapture.shared.authorizationStatus.rawValue)
                ZiaDivider()
                diagRow("Speech recognition", SpeechRecognizer.shared.authorizationStatus.rawValue)
                ZiaDivider()
                diagRow("Accessibility trust", AXIsProcessTrusted() ? "Granted" : "Not granted")
                ZiaDivider()
                diagRow("Durable task state", TaskStateMachine.shared.isPersistenceAvailable ? "Loaded" : "Unavailable")
                ZiaDivider()
                diagRow("Active tasks", String(TaskStateMachine.shared.activeTasks.count))
                ZiaDivider()
                diagRow("Scheduled jobs", String(TaskScheduler.shared.enabledJobCount))
                ZiaDivider()
                diagRow("Network", AppState.shared.isOnline ? "Online" : "Offline")
            }
        }
        .task { await model.load() }
    }

    private func diagRow(_ title: String, _ value: String) -> some View {
        ZiaSettingRow(title, detail: nil, symbol: nil) {
            Text(value).font(ZiaType.caption).foregroundStyle(ZiaColors.textSecondary)
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            HStack(spacing: ZiaSpace.lg) {
                ZiaPresenceOrb(state: .idle, size: 64)
                VStack(alignment: .leading, spacing: ZiaSpace.xs) {
                    Text("ZiA")
                        .font(ZiaType.display)
                        .foregroundStyle(ZiaColors.textPrimary)
                    Text("Your intelligent Mac assistant.")
                        .font(ZiaType.body)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
            }

            ZiaSection("Build") {
                ZiaSettingRow("Version", detail: nil, symbol: "tag") {
                    Text(ZiaBuildInfo.version)
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
                ZiaDivider()
                ZiaSettingRow("Host", detail: nil, symbol: "laptopcomputer") {
                    Text("\(ProcessInfo.processInfo.machineHardware) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
            }

            ZiaSection(
                "Principles",
                footnote: "These are invariants in the code, not marketing copy. A model may propose; only deterministic gates decide."
            ) {
                principleRow("Intelligence never equals authority", "Models propose. Validators, sandboxes and permissions decide.")
                ZiaDivider()
                principleRow("Evidence before green", "A step is only done when its effect was mechanically verified.")
                ZiaDivider()
                principleRow("Fail closed on authority", "Ambiguity never becomes permission.")
                ZiaDivider()
                principleRow("Focus is never stolen", "Background work, speech and streaming never move your windows.")
            }
        }
    }

    private func principleRow(_ title: String, _ detail: String) -> some View {
        ZiaSettingRow(title, detail: detail, symbol: "checkmark.seal") { EmptyView() }
    }
}

// MARK: - Helpers

extension ProcessInfo {
    /// e.g. "Apple M4" — used by the General and About panes.
    var machineHardware: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return self.machineArchitecture }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return brand.isEmpty ? self.machineArchitecture : brand
    }

    var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? "Apple Silicon" : machine
    }
}
