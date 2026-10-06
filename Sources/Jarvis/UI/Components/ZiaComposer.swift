import SwiftUI
import AppKit

/// Which surface the composer is sitting on. The HUD is always dark glass, the
/// conversation window follows the user's appearance — one control, two tones,
/// never a second composer implementation.
public enum ZiaComposerTone {
    /// Dark glass (the voice HUD).
    case dark
    /// Semantic surface (the conversation window).
    case surface
}

/// The composer: one object, not a row of controls.
///
/// Text, voice and send share a single capsule. While ZiA is listening the same
/// object *becomes* the listening affordance instead of sprouting another button.
public struct ZiaComposer: View {
    @Binding private var text: String
    private let isWorking: Bool
    private let isListening: Bool
    private let placeholder: String
    private let tone: ZiaComposerTone
    private let onSubmit: (String) -> Void
    private let onMic: () -> Void

    @StateObject private var hovering = ZiaState(false)

    public init(
        text: Binding<String>,
        isWorking: Bool,
        isListening: Bool,
        placeholder: String = "Ask ZiA…",
        tone: ZiaComposerTone = .dark,
        onSubmit: @escaping (String) -> Void,
        onMic: @escaping () -> Void
    ) {
        self._text = text
        self.isWorking = isWorking
        self.isListening = isListening
        self.placeholder = placeholder
        self.tone = tone
        self.onSubmit = onSubmit
        self.onMic = onMic
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        HStack(spacing: ZiaSpace.sm) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(enteredTextColor)
                .lineLimit(1...5)
                .onSubmit { submit() }

            // Voice and send live inside the same object, at the trailing edge.
            ZiaIconButton(
                symbol: isListening ? "waveform" : "mic.fill",
                help: isListening ? "Finish speaking" : "Start listening",
                tint: isListening ? strongTint : micTint,
                size: 26,
                action: onMic
            )

            if isWorking {
                ZiaIconButton(symbol: "stop.fill", help: "Stop", tint: stopTint, size: 26) {
                    VoicePipeline.shared.handleUserStopAction()
                }
            } else {
                ZiaIconButton(
                    symbol: "arrow.up",
                    help: "Send",
                    tint: hasText ? strongTint : sendTint,
                    size: 26
                ) {
                    submit()
                }
                .disabled(!hasText)
            }
        }
        .padding(.leading, ZiaSpace.lg)
        .padding(.trailing, ZiaSpace.sm)
        .padding(.vertical, ZiaSpace.sm)
        .background(
            Capsule(style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .onHover { hovering.value = $0 }
        .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.easeOut), value: hovering.value)
        .modifier(ForceDarkScheme(when: tone == .dark))
    }

    // MARK: Tone

    private var enteredTextColor: Color {
        tone == .dark ? .white.opacity(0.95) : ZiaColors.textPrimary
    }

    private var strongTint: Color {
        tone == .dark ? .white.opacity(0.95) : ZiaColors.accent
    }

    private var micTint: Color {
        tone == .dark ? .white.opacity(0.55) : ZiaColors.textSecondary
    }

    private var stopTint: Color {
        tone == .dark ? .white.opacity(0.75) : ZiaColors.error
    }

    private var sendTint: Color {
        tone == .dark ? .white.opacity(0.28) : ZiaColors.textTertiary
    }

    private var fillColor: Color {
        switch tone {
        case .dark:
            return .white.opacity(hovering.value ? 0.10 : 0.07)
        case .surface:
            return hovering.value ? ZiaColors.surfaceHover : ZiaColors.surfaceElevated
        }
    }

    private var borderColor: Color {
        switch tone {
        case .dark:
            return .white.opacity(hovering.value ? 0.22 : 0.13)
        case .surface:
            return hovering.value ? ZiaColors.borderStrong : ZiaColors.border
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        onSubmit(value)
    }
}

/// The HUD is dark glass whatever the app appearance is, so its text field must
/// resolve its placeholder against a dark scheme. The window keeps the user's
/// appearance untouched.
private struct ForceDarkScheme: ViewModifier {
    let when: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if when {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}
