import SwiftUI
import AppKit

// MARK: - Provider status

/// Truthful provider health. Every row comes from a live `isAvailable` probe via
/// `ProviderManager.healthSnapshot()`; a provider is never shown as connected
/// unless it actually answered.
@MainActor
public final class ZiaProviderModel: ObservableObject {
    public static let shared = ZiaProviderModel()

    public struct Row: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let isAvailable: Bool
        public let failureCount: Int
        public let lastError: String?
        public let isLocal: Bool
        public let quarantined: Bool
    }

    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var availableCount = 0
    @Published public private(set) var totalCount = 0
    @Published public private(set) var isDegraded = false
    @Published public private(set) var lastChecked: Date?
    /// Exact Groq model status when a key is configured ("model 'x': ready" or
    /// "model 'x': <reason>"). nil when Groq is not configured/available.
    @Published public private(set) var groqModelNote: String?

    private init() {}

    /// Human-readable name for a provider id, derived from the registered id.
    /// Pure mapping, so it is callable from any isolation.
    public nonisolated static func displayName(for id: String) -> String {
        switch id {
        case "chatgpt-desktop": return "ChatGPT Desktop"
        case "anthropic": return "Claude"
        case "openai": return "OpenAI"
        case "google": return "Gemini"
        case "groq": return "Groq"
        case "openrouter": return "OpenRouter"
        case "mlx-normal": return "Local model (normal)"
        case "mlx-reflex": return "Local model (reflex)"
        default: return id
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let summary = await ProviderManager.shared.healthSnapshot()
        rows = summary.statuses
            .map { status in
                Row(
                    id: status.id,
                    name: Self.displayName(for: status.id),
                    isAvailable: status.isAvailable,
                    failureCount: status.failureCount,
                    lastError: status.lastError,
                    isLocal: status.id.hasPrefix("mlx"),
                    quarantined: summary.quarantined.contains(status.id))
            }
            .sorted { lhs, rhs in
                // Primary brain first, then local fallbacks, then the rest.
                if lhs.id == "chatgpt-desktop" { return true }
                if rhs.id == "chatgpt-desktop" { return false }
                if lhs.isLocal != rhs.isLocal { return !lhs.isLocal }
                return lhs.name < rhs.name
            }
        availableCount = summary.availableCount
        totalCount = summary.totalCount
        isDegraded = summary.isDegraded
        lastChecked = Date()

        // Surface the Groq model's real availability when it is configured. The
        // configured default model is NOT available to every account, so this is
        // verified against /models (bounded) rather than assumed.
        if summary.statuses.first(where: { $0.id == "groq" })?.isAvailable == true {
            let groq = ProviderManager.shared.groq
            let model = await groq.resolvedModel
            switch await groq.verifyModelAvailability() {
            case .available:
                groqModelNote = "Groq model '\(model)': ready"
            case .unavailable(let reason):
                groqModelNote = "Groq model '\(model)': \(reason)"
            }
        } else {
            groqModelNote = nil
        }
        isRefreshing = false
    }

    /// The provider that would answer right now, in routing order.
    public var primaryAvailable: Row? {
        rows.first { $0.id == "chatgpt-desktop" && $0.isAvailable }
    }

    public var localFallback: Row? {
        rows.first { $0.isLocal && $0.isAvailable }
    }
}

/// A provider row: real availability, real failure count, no invented status.
public struct ZiaProviderCard: View {
    @ObservedObject private var model = ZiaProviderModel.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.md) {
            HStack(spacing: ZiaSpace.sm) {
                ZiaStatusDot(
                    color: model.availableCount == 0
                        ? ZiaColors.error
                        : (model.isDegraded ? ZiaColors.warning : ZiaColors.success),
                    pulsing: model.isRefreshing
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.availableCount == 0 ? "No model available" : "Intelligence available")
                        .font(ZiaType.sectionTitle)
                        .foregroundStyle(ZiaColors.textPrimary)
                    Text("\(model.availableCount) of \(model.totalCount) providers responding")
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                }
                Spacer(minLength: ZiaSpace.sm)
                ZiaIconButton(symbol: "arrow.clockwise", help: "Re-check providers") {
                    Task { await model.refresh() }
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ZiaDivider() }
                    providerRow(row)
                }
            }

            if let note = model.groqModelNote {
                Text(note)
                    .font(ZiaType.caption)
                    .foregroundStyle(note.contains(": ready") ? ZiaColors.textSecondary : ZiaColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let primary = model.primaryAvailable {
                Text("Primary brain: \(primary.name)")
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
            } else if let fallback = model.localFallback {
                Text("ChatGPT Desktop is not responding — ZiA will use \(fallback.name).")
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textSecondary)
            }
        }
        .task { await model.refresh() }
    }

    private func providerRow(_ row: ZiaProviderModel.Row) -> some View {
        HStack(spacing: ZiaSpace.sm) {
            ZiaStatusDot(
                color: row.quarantined ? ZiaColors.error : (row.isAvailable ? ZiaColors.success : ZiaColors.textTertiary),
                diameter: 7
            )
            Text(row.name)
                .font(ZiaType.body)
                .foregroundStyle(row.isAvailable ? ZiaColors.textPrimary : ZiaColors.textSecondary)
            if row.isLocal {
                ZiaBadge("Local", symbol: "cpu", tint: ZiaColors.info)
            }
            Spacer(minLength: ZiaSpace.sm)
            if row.quarantined {
                ZiaBadge("Quarantined", symbol: "pause.circle", tint: ZiaColors.error)
            } else if row.isAvailable {
                Text("Ready").font(ZiaType.caption).foregroundStyle(ZiaColors.textSecondary)
            } else {
                Text(row.failureCount > 0 ? "Unavailable · \(row.failureCount) failures" : "Not configured")
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
            }
        }
        .padding(.horizontal, ZiaSpace.lg)
        .padding(.vertical, ZiaSpace.sm + 2)
        .help(row.lastError ?? "")
    }
}

// MARK: - Permissions

/// Real TCC state for the three permissions ZiA actually needs, with an honest
/// explanation of what each unlocks and a direct link to the right pane.
@MainActor
public final class ZiaPermissionModel: ObservableObject {
    public static let shared = ZiaPermissionModel()

    public struct Item: Identifiable, Sendable {
        public enum Kind: String, Sendable {
            case microphone
            case speechRecognition
            case accessibility
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let reason: String
        public let enabled: Bool
        public let systemSettingsURL: String
    }

    @Published public private(set) var items: [Item] = []

    private init() { refresh() }

    public func refresh() {
        let mic = AudioCapture.shared.authorizationStatus
        let speech = SpeechRecognizer.shared.authorizationStatus
        let axTrusted = AXIsProcessTrusted()

        items = [
            Item(
                id: Item.Kind.microphone.rawValue,
                kind: .microphone,
                title: "Microphone",
                reason: "Lets ZiA hear a wake word and your spoken request. Audio is transcribed on-device.",
                enabled: mic == .authorized,
                systemSettingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
            Item(
                id: Item.Kind.speechRecognition.rawValue,
                kind: .speechRecognition,
                title: "Speech Recognition",
                reason: "Turns your speech into text locally. ZiA uses on-device recognition only.",
                enabled: speech == .authorized,
                systemSettingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"),
            Item(
                id: Item.Kind.accessibility.rawValue,
                kind: .accessibility,
                title: "Accessibility",
                reason: "Required only for computer control — inspecting and clicking UI elements in other apps.",
                enabled: axTrusted,
                systemSettingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        ]
    }

    public var allGranted: Bool { items.allSatisfy(\.enabled) }
    public var grantedCount: Int { items.filter(\.enabled).count }
}

public struct ZiaPermissionCard: View {
    @ObservedObject private var model = ZiaPermissionModel.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.md) {
            HStack(spacing: ZiaSpace.sm) {
                ZiaStatusDot(color: model.allGranted ? ZiaColors.success : ZiaColors.warning)
                Text(model.allGranted ? "All permissions granted" : "\(model.grantedCount) of \(model.items.count) permissions granted")
                    .font(ZiaType.sectionTitle)
                    .foregroundStyle(ZiaColors.textPrimary)
                Spacer(minLength: ZiaSpace.sm)
                ZiaIconButton(symbol: "arrow.clockwise", help: "Re-check permissions") {
                    model.refresh()
                }
            }

            Text("ZiA asks only for what it uses. Each permission can be revoked at any time in System Settings.")
                .font(ZiaType.caption)
                .foregroundStyle(ZiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { ZiaDivider() }
                    ZiaSettingRow(item.title, detail: item.reason) {
                        if item.enabled {
                            ZiaBadge("Granted", symbol: "checkmark", tint: ZiaColors.success)
                        } else {
                            ZiaButton("Open Settings", variant: .secondary, size: .small) {
                                if let url = URL(string: item.systemSettingsURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

// MARK: - Activity / background work

/// Real task activity, read from the authoritative task state machine. There is
/// no fake progress: rows exist only for tasks that actually exist, and step
/// icons reflect each step's true state and verification outcome.
@MainActor
final class ZiaActivityModel: ObservableObject {
    static let shared = ZiaActivityModel()

    @Published private(set) var tasks: [JarvisTask] = []

    private var subscription: UUID?

    private init() {
        subscription = EventBus.shared.subscribe(InteractionPhaseChangedEvent.self) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        tasks = TaskStateMachine.shared.activeTasks.sorted { $0.createdAt > $1.createdAt }
    }

    var hasActiveWork: Bool { !tasks.isEmpty }

    /// One bounded refresh pass. Called only while an activity surface is
    /// visible; it does not install a global timer.
    func refreshAndReschedule() {
        refresh()
    }
}

struct ZiaTaskCard: View {
    let task: JarvisTask

    init(task: JarvisTask) {
        self.task = task
    }

    public var body: some View {
        ZiaSurface(level: .standard, radius: ZiaRadius.md, padding: ZiaSpace.md) {
            VStack(alignment: .leading, spacing: ZiaSpace.sm) {
                HStack(spacing: ZiaSpace.sm) {
                    ZiaStatusDot(color: stateColor, pulsing: isActive)
                    Text(task.title)
                        .font(ZiaType.bodyEmphasis)
                        .foregroundStyle(ZiaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: ZiaSpace.sm)
                    ZiaBadge(task.state.rawValue.capitalized, tint: stateColor)
                }

                if !task.steps.isEmpty {
                    VStack(alignment: .leading, spacing: ZiaSpace.xs + 1) {
                        ForEach(task.steps) { step in
                            stepRow(step)
                        }
                    }
                } else {
                    Text("Preparing steps…")
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textTertiary)
                }
            }
        }
    }

    private var isActive: Bool {
        task.state == .running || task.state == .planning || task.state == .verifying
    }

    private var stateColor: Color {
        switch task.state {
        case .completed: return ZiaColors.success
        case .failed: return ZiaColors.error
        case .cancelled: return ZiaColors.textTertiary
        case .recovering, .replanning: return ZiaColors.warning
        case .created, .planning, .running, .verifying: return ZiaColors.info
        }
    }

    @ViewBuilder
    private func stepRow(_ step: TaskStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZiaSpace.sm) {
            Image(systemName: stepSymbol(step))
                .font(.system(size: ZiaMetric.iconSm, weight: .semibold))
                .foregroundStyle(stepColor(step))
                .frame(width: 14)
            Text(step.description)
                .font(ZiaType.caption)
                .foregroundStyle(step.state == .completed ? ZiaColors.textSecondary : ZiaColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// Only a verified step gets a checkmark. Unverified work never looks done.
    private func stepSymbol(_ step: TaskStep) -> String {
        if step.verification == .passed { return "checkmark.circle.fill" }
        switch step.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running, .verifying: return "circle.dotted"
        case .cancelled: return "minus.circle"
        default: return "circle"
        }
    }

    private func stepColor(_ step: TaskStep) -> Color {
        if step.verification == .failed { return ZiaColors.error }
        if step.verification == .passed { return ZiaColors.success }
        switch step.state {
        case .completed: return ZiaColors.success
        case .failed: return ZiaColors.error
        case .running, .verifying: return ZiaColors.info
        default: return ZiaColors.textTertiary
        }
    }
}

/// Compact background-work strip: tells the user work continues without
/// stealing focus or opening a window.
struct ZiaActivityStrip: View {
    @ObservedObject private var model = ZiaActivityModel.shared
    private let onReveal: () -> Void

    init(onReveal: @escaping () -> Void = {}) {
        self.onReveal = onReveal
    }

    public var body: some View {
        Group {
            if let task = model.tasks.first {
                HStack(spacing: ZiaSpace.sm) {
                    ZiaStatusDot(color: ZiaColors.info, pulsing: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Working in background")
                            .font(ZiaType.captionEmphasis)
                            .foregroundStyle(ZiaColors.textPrimary)
                        Text(task.title)
                            .font(ZiaType.caption)
                            .foregroundStyle(ZiaColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: ZiaSpace.sm)
                    if model.tasks.count > 1 {
                        ZiaBadge("+\(model.tasks.count - 1)")
                    }
                    ZiaButton("View", variant: .ghost, size: .small, action: onReveal)
                }
                .padding(.horizontal, ZiaSpace.md)
                .padding(.vertical, ZiaSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: ZiaRadius.sm, style: .continuous)
                        .fill(ZiaColors.info.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ZiaRadius.sm, style: .continuous)
                        .strokeBorder(ZiaColors.info.opacity(0.20), lineWidth: 1)
                )
                .onAppear { model.refresh() }
            }
        }
    }
}
