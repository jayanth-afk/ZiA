import SwiftUI
import AppKit

/// Design tokens defining JARVIS aesthetic styling, glassmorphism, and color system.
public enum DesignTokens {
    // MARK: - Colors
    public enum Colors {
        /// Deep dark background with subtle blue/slate tint
        public static let background = Color(nsColor: NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 0.85))
        public static let backgroundSecondary = Color(nsColor: NSColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 0.70))
        public static let surface = Color(nsColor: NSColor(red: 0.14, green: 0.17, blue: 0.24, alpha: 0.60))

        /// Glowing vibrant accents
        public static let primaryAccent = Color(red: 0.20, green: 0.60, blue: 1.00) // Electric Blue
        public static let secondaryAccent = Color(red: 0.55, green: 0.35, blue: 1.00) // Cyan/Purple neon
        public static let success = Color(red: 0.18, green: 0.80, blue: 0.44) // Emerald Green
        public static let warning = Color(red: 0.95, green: 0.75, blue: 0.20) // Amber
        public static let error = Color(red: 0.95, green: 0.30, blue: 0.30) // Coral Red

        /// Typography hierarchy
        public static let textPrimary = Color.white.opacity(0.95)
        public static let textSecondary = Color.white.opacity(0.70)
        public static let textTertiary = Color.white.opacity(0.45)

        /// Border highlights for glassmorphic borders
        public static let border = Color.white.opacity(0.12)
        public static let borderHighlight = Color.white.opacity(0.25)
    }

    // MARK: - Spacing & Dimensions
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let cornerRadius: CGFloat = 18
        public static let panelCornerRadius: CGFloat = 24
    }

    // MARK: - Gradients
    public enum Gradients {
        public static let accent = LinearGradient(
            colors: [Colors.primaryAccent, Colors.secondaryAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let glassSurface = LinearGradient(
            colors: [Color.white.opacity(0.15), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
