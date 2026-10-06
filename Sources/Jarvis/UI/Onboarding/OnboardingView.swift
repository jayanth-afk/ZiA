import SwiftUI
import AppKit

/// First-run state. Deliberately stored as a plain flag: onboarding is shown the
/// first time the user *opens ZiA*, never automatically at launch, so starting
/// the app never moves the user's focus or Spaces.
@MainActor
public final class ZiaOnboardingStore: ObservableObject {
    public static let shared = ZiaOnboardingStore()

    private static let key = "zia.onboarding.completed.v1"

    @Published public private(set) var isComplete: Bool

    private init() {
        isComplete = UserDefaults.standard.bool(forKey: Self.key)
    }

    public func complete() {
        isComplete = true
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    /// Test/diagnostic helper: show onboarding again on the next open.
    public func reset() {
        isComplete = false
        UserDefaults.standard.set(false, forKey: Self.key)
    }
}

/// A short, honest first-run experience: what ZiA is, exactly which permissions
/// it needs and why, and one action that starts it. No carousel of feature
/// slides, and nothing that claims a capability the machine does not have.
struct OnboardingView: View {
    let onContinue: () -> Void

    @ObservedObject private var permissions = ZiaPermissionModel.shared
    @StateObject private var requesting = ZiaState(false)

    var body: some View {
        VStack(spacing: ZiaSpace.xxl) {
            Spacer(minLength: 0)

            VStack(spacing: ZiaSpace.md) {
                ZiaPresenceOrb(state: .idle, size: 78)
                Text("Welcome to ZiA")
                    .font(ZiaType.display)
                    .foregroundStyle(ZiaColors.textPrimary)
                Text("Your intelligent Mac assistant. Ask in your own words — by voice or by typing — and ZiA answers, or acts on your Mac when you ask.")
                    .font(ZiaType.body)
                    .foregroundStyle(ZiaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            ZiaCard(title: "Before you begin", subtitle: "Only what ZiA actually uses.", symbol: "lock.shield") {
                VStack(spacing: 0) {
                    ForEach(Array(permissions.items.enumerated()), id: \.element.id) { index, item in
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
            .frame(maxWidth: 460)

            VStack(spacing: ZiaSpace.sm) {
                ZiaButton(
                    permissions.allGranted ? "Continue" : "Continue without granting",
                    variant: .primary,
                    action: onContinue
                )
                .keyboardShortcut(.defaultAction)

                if !permissions.allGranted {
                    Text("You can grant permission later — ZiA explains what changes in Settings › Permissions.")
                        .font(ZiaType.caption)
                        .foregroundStyle(ZiaColors.textTertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(ZiaSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZiaColors.background)
        .onAppear { permissions.refresh() }
    }
}
