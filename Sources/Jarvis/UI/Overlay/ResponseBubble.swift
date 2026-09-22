import SwiftUI

/// Elegant bubble displaying streaming response or conversation turn.
public struct ResponseBubble: View {
    public let text: String
    public let isStreaming: Bool
    public let providerName: String?
    public let latencyMs: Int?

    public init(
        text: String,
        isStreaming: Bool = false,
        providerName: String? = nil,
        latencyMs: Int? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.providerName = providerName
        self.latencyMs = latencyMs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // Header: Provider & Latency badge
            if providerName != nil || latencyMs != nil {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let provider = providerName {
                        Text(provider.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(DesignTokens.Colors.primaryAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignTokens.Colors.primaryAccent.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if let latency = latencyMs {
                        Text("\(latency)ms")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(DesignTokens.Colors.textTertiary)
                    }

                    Spacer()
                }
            }

            // Message text
            HStack(alignment: .bottom, spacing: 4) {
                Text(text.isEmpty ? "Thinking..." : text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(text.isEmpty ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.textPrimary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)

                if isStreaming {
                    Circle()
                        .fill(DesignTokens.Colors.primaryAccent)
                        .frame(width: 6, height: 6)
                        .opacity(0.8)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.cornerRadius)
                .fill(DesignTokens.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Spacing.cornerRadius)
                        .stroke(DesignTokens.Colors.border, lineWidth: 1)
                )
        )
    }
}
