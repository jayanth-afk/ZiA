import SwiftUI
import AppKit

// MARK: - Semantic Color

/// A semantic color that resolves differently in light and dark appearances.
///
/// The whole UI reads from these tokens, never from raw RGB literals, so a
/// single edit here restyles every surface. Values are deliberately low-chroma:
/// ZiA should read as calm and premium, not neon.
public enum ZiaColors {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    // MARK: Backgrounds
    public static let background = adaptive(light: rgb(246, 247, 249), dark: rgb(14, 16, 22))
    public static let backgroundSecondary = adaptive(light: rgb(240, 242, 245), dark: rgb(20, 23, 30))

    // MARK: Surfaces
    public static let surface = adaptive(light: rgb(255, 255, 255), dark: rgb(25, 28, 36))
    public static let surfaceElevated = adaptive(light: rgb(255, 255, 255), dark: rgb(31, 35, 45))
    public static let surfaceHover = adaptive(light: rgb(243, 245, 248), dark: rgb(38, 43, 55))
    public static let surfacePressed = adaptive(light: rgb(234, 237, 243), dark: rgb(45, 51, 64))

    // MARK: Lines
    public static let border = adaptive(light: rgb(0, 0, 0, 0.08), dark: rgb(255, 255, 255, 0.10))
    public static let borderStrong = adaptive(light: rgb(0, 0, 0, 0.14), dark: rgb(255, 255, 255, 0.18))
    public static let separator = adaptive(light: rgb(0, 0, 0, 0.06), dark: rgb(255, 255, 255, 0.07))

    // MARK: Text
    public static let textPrimary = adaptive(light: rgb(20, 22, 28), dark: rgb(240, 242, 247))
    public static let textSecondary = adaptive(light: rgb(84, 89, 101), dark: rgb(168, 174, 187))
    public static let textTertiary = adaptive(light: rgb(128, 134, 146), dark: rgb(120, 127, 141))

    // MARK: Accent & status
    public static let accent = adaptive(light: rgb(64, 92, 235), dark: rgb(112, 138, 255))
    public static let accentSoft = adaptive(light: rgb(64, 92, 235, 0.12), dark: rgb(112, 138, 255, 0.16))
    public static let success = adaptive(light: rgb(28, 160, 96), dark: rgb(72, 199, 132))
    public static let warning = adaptive(light: rgb(196, 138, 20), dark: rgb(240, 189, 74))
    public static let error = adaptive(light: rgb(200, 62, 66), dark: rgb(240, 112, 112))
    public static let info = adaptive(light: rgb(52, 128, 214), dark: rgb(96, 168, 245))

    /// Presence accent used for the assistant orb / voice surfaces.
    public static let presence = adaptive(light: rgb(88, 104, 236), dark: rgb(130, 152, 255))
}

// MARK: - Typography

/// macOS-native type hierarchy. System faces only (San Francisco), with a
/// rounded variant reserved for the assistant identity, never for body copy.
public enum ZiaType {
    public static let display = Font.system(size: 30, weight: .semibold, design: .rounded)
    public static let largeTitle = Font.system(size: 22, weight: .semibold)
    public static let title = Font.system(size: 17, weight: .semibold)
    public static let sectionTitle = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13.5, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13.5, weight: .medium)
    public static let secondary = Font.system(size: 12, weight: .regular)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let captionEmphasis = Font.system(size: 11, weight: .semibold)
    public static let metadata = Font.system(size: 10.5, weight: .medium)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let identity = Font.system(size: 15, weight: .semibold, design: .rounded)
}

// MARK: - Spacing

public enum ZiaSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32

    /// Standard horizontal inset for content inside a panel or window.
    public static let contentInset: CGFloat = 20
    /// Maximum readable text width for assistant prose, in points.
    public static let readableWidth: CGFloat = 640
}

// MARK: - Radius

public enum ZiaRadius {
    public static let xs: CGFloat = 5
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let panel: CGFloat = 24
    /// Corner radius of the floating presence HUD.
    public static let hud: CGFloat = 30
}

// MARK: - Motion

/// One motion system. Durations are intentionally short — animation must never
/// be the reason the assistant feels slow.
public enum ZiaMotion {
    public static let micro: Double = 0.12
    public static let quick: Double = 0.20
    public static let standard: Double = 0.30
    public static let slow: Double = 0.50

    public static let easeOut = Animation.easeOut(duration: quick)
    public static let stateChange = Animation.spring(response: 0.32, dampingFraction: 0.86)
    public static let presence = Animation.spring(response: 0.45, dampingFraction: 0.80)
    public static let entrance = Animation.spring(response: 0.38, dampingFraction: 0.88)

    /// Honor the system "Reduce motion" setting across every animated surface.
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Returns the animation, or nil when reduced motion is requested.
    public static func respectingReduceMotion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Elevation

public enum ZiaElevation {
    public static let card = ZiaShadow(color: .black.opacity(0.16), radius: 6, y: 2)
    public static let raised = ZiaShadow(color: .black.opacity(0.22), radius: 14, y: 6)
    public static let floating = ZiaShadow(color: .black.opacity(0.34), radius: 28, y: 14)
}

public struct ZiaShadow: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.y = y
    }
}

// MARK: - Metrics

public enum ZiaMetric {
    public static let iconSm: CGFloat = 11
    public static let iconMd: CGFloat = 13
    public static let iconLg: CGFloat = 17
    public static let iconXl: CGFloat = 22

    public static let controlSm: CGFloat = 22
    public static let controlMd: CGFloat = 28
    public static let controlLg: CGFloat = 34

    /// Assistant presence orb diameter in each presentation.
    public static let orbCompact: CGFloat = 44
    public static let orbRegular: CGFloat = 64
    public static let orbLarge: CGFloat = 104
}

// MARK: - Build information

/// The app version as a string safe to show.
///
/// The debug binary embeds `Scripts/Info.plist` directly, and its version fields
/// are build-time placeholders (`${VERSION}`) that only `Scripts/build-app.sh`
/// substitutes. A placeholder must never reach the UI.
public enum ZiaBuildInfo {
    public static var version: String {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("${") { return "development" }
        return trimmed
    }

    /// Compact form for the menu bar footer.
    public static var shortVersion: String {
        version == "development" ? "dev" : "v\(version)"
    }
}

// MARK: - Local view state

/// A tiny observable box used in place of SwiftUI's `@State`.
///
/// This host builds against the Command Line Tools SwiftUI interface, where the
/// `@State`/`@Environment` macro plugins are not shipped. `@StateObject` is a
/// real property wrapper with storage, so wrapping a plain `ObservableObject`
/// gives the same persistence across view updates without any macro.
@MainActor
public final class ZiaState<Value>: ObservableObject {
    @Published public var value: Value

    public init(_ initial: Value) {
        value = initial
    }
}

// MARK: - Appearance

/// User-selectable appearance. Drives `.preferredColorScheme` on every ZiA
/// surface, and is persisted like any other preference.
public enum ZiaAppearance: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Persisted appearance selection. Small, self-contained, and observable so
/// every window reacts immediately without a restart.
@MainActor
public final class ZiaAppearanceStore: ObservableObject {
    public static let shared = ZiaAppearanceStore()

    private static let key = "zia.appearance.v1"

    @Published public var appearance: ZiaAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.key) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key) ?? ZiaAppearance.system.rawValue
        appearance = ZiaAppearance(rawValue: stored) ?? .system
    }
}
