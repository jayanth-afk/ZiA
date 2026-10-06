import SwiftUI

// MARK: - Surface

/// The single layered surface primitive. Everything visible in ZiA sits on one
/// of these; nothing floats as an isolated glass card.
public struct ZiaSurface<Content: View>: View {
    public enum Level {
        /// Base window/panel fill.
        case base
        /// Standard content surface.
        case standard
        /// Slightly lifted (selected, hovered, or a nested group).
        case elevated
    }

    private let level: Level
    private let radius: CGFloat
    private let padding: CGFloat?
    private let interactive: Bool
    private let content: Content

    @StateObject private var hovering = ZiaState(false)

    public init(
        level: Level = .standard,
        radius: CGFloat = ZiaRadius.md,
        padding: CGFloat? = ZiaSpace.lg,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.level = level
        self.radius = radius
        self.padding = padding
        self.interactive = interactive
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding.map { EdgeInsets(top: $0, leading: $0, bottom: $0, trailing: $0) } ?? EdgeInsets())
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ZiaColors.border, lineWidth: 1)
            )
            .onHover { hovering.value = $0 }
            .animation(ZiaMotion.respectingReduceMotion(ZiaMotion.easeOut), value: hovering.value)
    }

    private var fill: Color {
        switch level {
        case .base: return ZiaColors.background
        case .standard: return interactive && hovering.value ? ZiaColors.surfaceHover : ZiaColors.surface
        case .elevated: return interactive && hovering.value ? ZiaColors.surfaceHover : ZiaColors.surfaceElevated
        }
    }
}

// MARK: - Card

/// A content card: optional title/subtitle header, then arbitrary content.
public struct ZiaCard<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let symbol: String?
    private let tint: Color
    private let trailing: AnyView?
    private let content: Content

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color = ZiaColors.accent,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing
        self.content = content()
    }

    public var body: some View {
        ZiaSurface(level: .standard, radius: ZiaRadius.lg, padding: ZiaSpace.lg) {
            VStack(alignment: .leading, spacing: ZiaSpace.md) {
                if title != nil || symbol != nil || trailing != nil {
                    HStack(alignment: .center, spacing: ZiaSpace.sm) {
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: ZiaMetric.iconMd, weight: .semibold))
                                .foregroundStyle(tint)
                                .frame(width: 18)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            if let title {
                                Text(title)
                                    .font(ZiaType.sectionTitle)
                                    .foregroundStyle(ZiaColors.textPrimary)
                            }
                            if let subtitle {
                                Text(subtitle)
                                    .font(ZiaType.caption)
                                    .foregroundStyle(ZiaColors.textSecondary)
                            }
                        }
                        Spacer(minLength: ZiaSpace.sm)
                        if let trailing { trailing }
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Section

/// A titled group of rows used across Settings and the main window.
public struct ZiaSection<Content: View>: View {
    private let title: String
    private let footnote: String?
    private let content: Content

    public init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.sm) {
            Text(title.uppercased())
                .font(ZiaType.metadata)
                .tracking(0.6)
                .foregroundStyle(ZiaColors.textTertiary)
                .padding(.horizontal, ZiaSpace.xxs)

            ZiaSurface(level: .standard, radius: ZiaRadius.md, padding: nil) {
                VStack(spacing: 0) { content }
            }

            if let footnote {
                Text(footnote)
                    .font(ZiaType.caption)
                    .foregroundStyle(ZiaColors.textTertiary)
                    .padding(.horizontal, ZiaSpace.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A horizontal hairline used between rows inside a ``ZiaSection``.
public struct ZiaDivider: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(ZiaColors.separator)
            .frame(height: 1)
            .padding(.leading, ZiaSpace.lg)
    }
}
