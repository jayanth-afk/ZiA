import SwiftUI

// MARK: - Button

/// The one button component. Variants differ only in emphasis, never in shape
/// or hit area, so the whole app keeps a consistent control language.
public struct ZiaButton: View {
    public enum Variant {
        case primary
        case secondary
        case ghost
        case destructive
    }

    public enum Size {
        case small
        case regular

        var height: CGFloat { self == .small ? ZiaMetric.controlSm : ZiaMetric.controlMd }
        var font: Font { self == .small ? ZiaType.caption : ZiaType.body }
        var hPad: CGFloat { self == .small ? ZiaSpace.sm : ZiaSpace.md }
    }

    private let title: String
    private let symbol: String?
    private let variant: Variant
    private let size: Size
    private let isEnabled: Bool
    private let action: () -> Void

    @StateObject private var hovering = ZiaState(false)

    public init(
        _ title: String,
        symbol: String? = nil,
        variant: Variant = .secondary,
        size: Size = .regular,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.variant = variant
        self.size = size
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: ZiaSpace.xs + 1) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size == .small ? ZiaMetric.iconSm : ZiaMetric.iconMd, weight: .semibold))
                }
                Text(title).font(size.font.weight(.medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size.hPad)
            .frame(height: size.height)
            .background(
                RoundedRectangle(cornerRadius: ZiaRadius.sm, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiaRadius.sm, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ZiaRadius.sm, style: .continuous))
        }
        .buttonStyle(ZiaPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering.value = $0 }
        .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.easeOut), value: hovering.value)
        .accessibilityLabel(Text(title))
    }

    private var foreground: Color {
        switch variant {
        case .primary: return .white
        case .secondary: return ZiaColors.textPrimary
        case .ghost: return ZiaColors.textSecondary
        case .destructive: return ZiaColors.error
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return hovering.value ? ZiaColors.accent.opacity(0.88) : ZiaColors.accent
        case .secondary: return hovering.value ? ZiaColors.surfaceHover : ZiaColors.surfaceElevated
        case .ghost: return hovering.value ? ZiaColors.surfaceHover : .clear
        case .destructive: return hovering.value ? ZiaColors.error.opacity(0.14) : ZiaColors.error.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary: return .clear
        case .ghost: return .clear
        case .secondary: return ZiaColors.border
        case .destructive: return ZiaColors.error.opacity(0.28)
        }
    }
}

/// A compact, borderless icon button used in headers and toolbars.
public struct ZiaIconButton: View {
    private let symbol: String
    private let help: String
    private let tint: Color
    private let size: CGFloat
    private let action: () -> Void

    @StateObject private var hovering = ZiaState(false)

    public init(
        symbol: String,
        help: String,
        tint: Color = ZiaColors.textSecondary,
        size: CGFloat = ZiaMetric.controlMd,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ZiaMetric.iconMd, weight: .semibold))
                .foregroundStyle(hovering.value ? ZiaColors.textPrimary : tint)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                        .fill(hovering.value ? ZiaColors.surfaceHover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous))
        }
        .buttonStyle(ZiaPressStyle())
        .onHover { hovering.value = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Shared press feedback: a small, fast scale — the only "click" animation.
public struct ZiaPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(
                ZiaMotion.respectingReduceMotion(.easeOut(duration: ZiaMotion.micro)),
                value: configuration.isPressed
            )
    }
}

// MARK: - Badge

/// A small status chip (provider state, counts, metadata).
public struct ZiaBadge: View {
    private let text: String
    private let symbol: String?
    private let tint: Color

    public init(_ text: String, symbol: String? = nil, tint: Color = ZiaColors.textSecondary) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: ZiaMetric.iconSm - 2, weight: .bold))
            }
            Text(text).font(ZiaType.metadata.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status dot

/// The canonical ZiA status light. Colour always carries the same meaning.
public struct ZiaStatusDot: View {
    private let color: Color
    private let diameter: CGFloat
    private let pulsing: Bool

    @StateObject private var state = ZiaState(false)

    public init(color: Color, diameter: CGFloat = 8, pulsing: Bool = false) {
        self.color = color
        self.diameter = diameter
        self.pulsing = pulsing
    }

    public var body: some View {
        ZStack {
            if pulsing && !ZiaMotion.reduceMotion {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(state.value ? 2.0 : 1.0)
                    .opacity(state.value ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: state.value)
            }
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .onAppear { state.value = true }
    }
}

// MARK: - Settings rows

/// A label + description row with an arbitrary trailing control.
public struct ZiaSettingRow<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let symbol: String?
    private let trailing: Trailing

    public init(
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: ZiaSpace.md) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: ZiaMetric.iconMd))
                    .foregroundStyle(ZiaColors.textTertiary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ZiaType.body)
                    .foregroundStyle(ZiaColors.textPrimary)
                if let detail {
                    Text(detail)
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: ZiaSpace.md)
            trailing
        }
        .padding(.horizontal, ZiaSpace.lg)
        .padding(.vertical, ZiaSpace.md)
    }
}

/// A boolean preference row. The toggle is the real control for a real value.
public struct ZiaToggleRow: View {
    private let title: String
    private let detail: String?
    private let symbol: String?
    @Binding private var isOn: Bool
    private let disabled: Bool

    public init(
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self._isOn = isOn
        self.disabled = disabled
    }

    public var body: some View {
        ZiaSettingRow(title, detail: detail, symbol: symbol) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
                .accessibilityLabel(Text(title))
        }
    }
}

// MARK: - Empty / error states

/// Never show a blank pane. An empty state always says what will appear here
/// and (when there is one) the action that makes it appear.
public struct ZiaEmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: ZiaSpace.sm) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(ZiaColors.textTertiary)
            Text(title)
                .font(ZiaType.bodyEmphasis)
                .foregroundStyle(ZiaColors.textSecondary)
            Text(message)
                .font(ZiaType.caption)
                .foregroundStyle(ZiaColors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                ZiaButton(actionTitle, variant: .secondary, size: .small, action: action)
                    .padding(.top, ZiaSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ZiaSpace.xxl)
        .accessibilityElement(children: .combine)
    }
}

/// A user-facing failure. Never a stack trace; technical detail stays collapsed.
public struct ZiaErrorView: View {
    private let title: String
    private let message: String
    private let detail: String?
    private let recovery: [(String, () -> Void)]

    @StateObject private var showDetail = ZiaState(false)

    public init(
        title: String,
        message: String,
        detail: String? = nil,
        recovery: [(String, () -> Void)] = []
    ) {
        self.title = title
        self.message = message
        self.detail = detail
        self.recovery = recovery
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.md) {
            HStack(spacing: ZiaSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: ZiaMetric.iconLg))
                    .foregroundStyle(ZiaColors.error)
                Text(title)
                    .font(ZiaType.bodyEmphasis)
                    .foregroundStyle(ZiaColors.textPrimary)
            }

            Text(message)
                .font(ZiaType.secondary)
                .foregroundStyle(ZiaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !recovery.isEmpty {
                HStack(spacing: ZiaSpace.sm) {
                    ForEach(Array(recovery.enumerated()), id: \.offset) { index, item in
                        ZiaButton(
                            item.0,
                            variant: index == 0 ? .primary : .secondary,
                            size: .small,
                            action: item.1
                        )
                    }
                }
            }

            if let detail {
                Button {
                    showDetail.value.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Text(showDetail.value ? "Hide details" : "Show details")
                        Image(systemName: showDetail.value ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
                }
                .buttonStyle(.plain)

                if showDetail.value {
                    Text(detail)
                        .font(ZiaType.code)
                        .foregroundStyle(ZiaColors.textTertiary)
                        .textSelection(.enabled)
                        .padding(ZiaSpace.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: ZiaRadius.xs, style: .continuous)
                                .fill(ZiaColors.backgroundSecondary)
                        )
                }
            }
        }
        .padding(ZiaSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: ZiaRadius.lg, style: .continuous)
                .fill(ZiaColors.error.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZiaRadius.lg, style: .continuous)
                .strokeBorder(ZiaColors.error.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
