import SwiftUI

/// Settings card for the opt-in ChatGPT brain. The switch is OFF by default and
/// the status line always states the exact reason the brain can (or cannot)
/// answer — never a vague "connecting".
@MainActor
final class ChatGPTBrainSettingsModel: ObservableObject {
    @Published var enabled = ChatGPTBrain.isEnabled
    @Published var status = "Checking…"
    @Published var transport: String?
    @Published var requestsToday = ChatGPTBrain.requestsToday()
    @Published var isAvailable = false

    var statusColor: Color {
        if !enabled { return ZiaColors.textSecondary }
        return isAvailable ? ZiaColors.success : ZiaColors.warning
    }

    func refresh() async {
        enabled = ChatGPTBrain.isEnabled
        requestsToday = ChatGPTBrain.requestsToday()
        let provider = ProviderManager.shared.chatgptDesktop
        let availability = await provider.verifiedAvailability(probe: true)
        isAvailable = availability.isAvailable
        transport = await provider.lastTransport()
        status = await ChatGPTBrain.statusLine(availability: availability, transport: transport ?? "auto")
    }

    func setEnabled(_ value: Bool) {
        ChatGPTBrain.isEnabled = value
        enabled = value
        Task { await refresh() }
    }
}

struct ChatGPTBrainSettingsView: View {
    @StateObject private var model = ChatGPTBrainSettingsModel()

    var body: some View {
        ZiaSection(
            "ChatGPT as a brain",
            footnote: "Off by default. When on, ChatGPT answers only requests that need real reasoning or writing — never sensitive data, never scheduled or background work, and never tool calls. It uses your own ChatGPT sign-in through the local Agent Bridge, at human scale."
        ) {
            ZiaToggleRow(
                "Allow ChatGPT as a brain",
                detail: model.enabled ? "On — used only when a request needs deep reasoning." : "Off — ZiA stays on-device and local.",
                symbol: "sparkles",
                isOn: Binding(
                    get: { model.enabled },
                    set: { model.setEnabled($0) }
                )
            )
            ZiaDivider()
            ZiaSettingRow("Status", detail: nil, symbol: "waveform.path.ecg") {
                Text(model.status)
                    .font(ZiaType.caption)
                    .foregroundStyle(model.statusColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            ZiaDivider()
            ZiaSettingRow("Transport in use", detail: "The bridge picks the headless engine when available, otherwise the app.", symbol: "arrow.triangle.branch") {
                Text(model.transport ?? "—")
                    .font(ZiaType.code)
                    .foregroundStyle(ZiaColors.textSecondary)
            }
            ZiaDivider()
            ZiaSettingRow("Requests today", detail: "Daily soft cap: \(ChatGPTBrain.dailySoftCap). Resets every day.", symbol: "number") {
                Text("\(model.requestsToday)")
                    .font(ZiaType.body)
                    .foregroundStyle(ZiaColors.textPrimary)
            }
        }
        .task { await model.refresh() }
    }
}
