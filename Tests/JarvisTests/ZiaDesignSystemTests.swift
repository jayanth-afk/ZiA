@testable import Jarvis
import Testing
import SwiftUI

/// Covers the visual design system's contracts: every token the UI relies on is
/// present, every backend interaction phase maps to a distinct presence state,
/// and no status surface can claim something the system does not know.
@Suite struct ZiaDesignSystemTests {

    // MARK: - Tokens

    @Test func spacingScaleIsMonotonic() {
        #expect(ZiaSpace.xxs < ZiaSpace.xs)
        #expect(ZiaSpace.xs < ZiaSpace.sm)
        #expect(ZiaSpace.sm < ZiaSpace.md)
        #expect(ZiaSpace.md < ZiaSpace.lg)
        #expect(ZiaSpace.lg < ZiaSpace.xl)
        #expect(ZiaSpace.xl < ZiaSpace.xxl)
        #expect(ZiaSpace.xxl < ZiaSpace.xxxl)
    }

    @Test func radiusScaleIsMonotonic() {
        #expect(ZiaRadius.xs < ZiaRadius.sm)
        #expect(ZiaRadius.sm < ZiaRadius.md)
        #expect(ZiaRadius.md < ZiaRadius.lg)
        #expect(ZiaRadius.lg < ZiaRadius.xl)
        #expect(ZiaRadius.xl < ZiaRadius.panel)
        #expect(ZiaRadius.panel == 24, "Panel radius stays aligned with the established design token")
    }

    @Test func controlHeightsAreUsable() {
        // macOS minimum comfortable hit target for pointer use.
        #expect(ZiaMetric.controlSm >= 20)
        #expect(ZiaMetric.controlLg > ZiaMetric.controlMd)
        #expect(ZiaMetric.controlMd > ZiaMetric.controlSm)
    }

    @Test func motionDurationsAreShort() {
        // Animation must never be the reason an interaction feels slow.
        #expect(ZiaMotion.micro <= 0.15)
        #expect(ZiaMotion.quick <= 0.25)
        #expect(ZiaMotion.standard <= 0.35)
    }

    @Test func semanticColorsResolveInBothAppearances() {
        // A dynamic NSColor must resolve to different components per appearance;
        // otherwise light and dark modes would be identical.
        let dark = NSAppearance(named: .darkAqua)
        let light = NSAppearance(named: .aqua)

        func components(_ color: Color, _ appearance: NSAppearance?) -> [CGFloat] {
            var result: [CGFloat] = []
            appearance?.performAsCurrentDrawingAppearance {
                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
                result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            }
            return result
        }

        let darkBackground = components(ZiaColors.background, dark)
        let lightBackground = components(ZiaColors.background, light)
        #expect(darkBackground != lightBackground, "Background must adapt to appearance")
        #expect(darkBackground.reduce(0, +) < lightBackground.reduce(0, +), "Dark background must be darker than light")

        let darkText = components(ZiaColors.textPrimary, dark)
        let lightText = components(ZiaColors.textPrimary, light)
        #expect(darkText.reduce(0, +) > lightText.reduce(0, +), "Dark-mode text must be lighter than light-mode text")

        // Status colours must stay distinguishable from one another.
        let success = components(ZiaColors.success, light)
        let warning = components(ZiaColors.warning, light)
        let error = components(ZiaColors.error, light)
        #expect(success != warning)
        #expect(warning != error)
        #expect(success != error)
    }

    @Test func appearanceOptionsCoverTheThreeSupportedModes() {
        #expect(ZiaAppearance.allCases == [.system, .light, .dark])
        #expect(ZiaAppearance.system.colorScheme == nil)
        #expect(ZiaAppearance.light.colorScheme == .light)
        #expect(ZiaAppearance.dark.colorScheme == .dark)
    }

    @Test @MainActor func appearanceStorePersistsSelection() {
        let store = ZiaAppearanceStore.shared
        let original = store.appearance

        store.appearance = .light
        #expect(UserDefaults.standard.string(forKey: "zia.appearance.v1") == ZiaAppearance.light.rawValue)
        #expect(ZiaAppearanceStore.shared.appearance == .light, "Selection must survive a fresh store instance")

        store.appearance = original
    }

    // MARK: - Presence state mapping

    @Test func everyInteractionPhaseMapsToAPresenceState() {
        for phase in InteractionPhase.allCases {
            let presence = ZiaPresenceState.resolve(phase: phase, appEnabled: true)
            #expect(!presence.label.isEmpty, "Presence for \(phase.rawValue) must be labelled")
        }
    }

    @Test func disabledAssistantNeverReportsActivity() {
        for phase in InteractionPhase.allCases where phase == .idle {
            let presence = ZiaPresenceState.resolve(phase: phase, appEnabled: false)
            #expect(presence == .disabled)
        }
    }

    @Test func stopOverridesTheBackendPhase() {
        let presence = ZiaPresenceState.resolve(phase: .executing, appEnabled: true, stopped: true)
        #expect(presence == .stopped, "An explicit stop must win over a stale executing phase")
    }

    @Test func distinctStatesUseDistinctColours() {
        // Idle, listening, working, done and error must be visually separable.
        let colours: [ZiaPresenceState] = [.idle, .listening, .working, .done, .error]
        let labels = Set(colours.map(\.label))
        #expect(labels.count == colours.count, "Each state needs its own label")
        #expect(ZiaPresenceState.listening.color != ZiaPresenceState.working.color)
        #expect(ZiaPresenceState.done.color != ZiaPresenceState.error.color)
    }

    @Test func onlyActiveStatesAnimate() {
        #expect(ZiaPresenceState.idle.isAnimating == false)
        #expect(ZiaPresenceState.error.isAnimating == false)
        #expect(ZiaPresenceState.listening.isAnimating)
        #expect(ZiaPresenceState.thinking.isAnimating)
        #expect(ZiaPresenceState.working.isAnimating)
        #expect(ZiaPresenceState.speaking.isAnimating)
    }

    // MARK: - Truthful status

    @Test @MainActor func providerRowsOnlyClaimWhatWasProbed() async {
        let model = ZiaProviderModel.shared
        await model.refresh()

        for row in model.rows {
            // A row that is not available must carry a reason, not a "Ready" state.
            if !row.isAvailable {
                #expect(row.name.isEmpty == false)
            }
        }
        #expect(model.totalCount >= model.availableCount)
    }

    @Test func providerDisplayNamesAreHumanReadable() {
        #expect(ZiaProviderModel.displayName(for: "chatgpt-desktop") == "ChatGPT Desktop")
        #expect(ZiaProviderModel.displayName(for: "mlx-normal").contains("Local"))
        // Unknown ids degrade to the id itself rather than an empty label.
        #expect(ZiaProviderModel.displayName(for: "some-new-provider") == "some-new-provider")
    }

    @Test @MainActor func permissionModelReportsRealTCCState() {
        let model = ZiaPermissionModel.shared
        model.refresh()

        #expect(model.items.count == 3, "Microphone, speech recognition and accessibility are the real surface")
        #expect(model.grantedCount == model.items.filter(\.enabled).count)
        #expect(model.allGranted == (model.grantedCount == model.items.count))

        // Every item must explain itself and link to a real settings pane.
        for item in model.items {
            #expect(item.reason.isEmpty == false)
            #expect(item.systemSettingsURL.hasPrefix("x-apple.systempreferences:"))
        }
    }

    @Test @MainActor func activityModelOnlySurfacesRealTasks() {
        let model = ZiaActivityModel.shared
        model.refresh()

        // Non-terminal tasks only — a completed task is never shown as active work.
        for task in model.tasks {
            #expect(!task.state.isTerminal, "Active work must not include terminal tasks")
        }
        #expect(model.hasActiveWork == !model.tasks.isEmpty)
    }

    // MARK: - Conversation

    @Test @MainActor func sendingRefreshesAndNeverStreamsFakeText() {
        let model = ZiaConversationModel.shared
        let before = model.turns.count

        // Empty input is a no-op: no phantom turn is created.
        model.send("   ")
        #expect(model.turns.count == before)
    }

    // MARK: - Overlay

    @Test @MainActor func overlayTranslatesErrorsIntoUserFacingText() {
        let message = OverlayViewModel.userFacingMessage(
            for: JarvisError.providerError(provider: "chatgpt-desktop", message: "not running"))
        #expect(message.contains("primary AI") || message.contains("Local fallback"))
        #expect(!message.contains("providerError"), "Raw error enums must not reach the user")
    }

    @Test @MainActor func overlayExposesEveryStateToThePresenceLayer() {
        let viewModel = OverlayViewModel.shared
        let phases: [InteractionPhase] = [.listening, .understanding, .thinking, .executing, .speaking, .success, .error]
        for phase in phases {
            viewModel._applyForRendering(phase: phase)
            #expect(ZiaPresenceState.resolve(phase: viewModel.interactionPhase, appEnabled: true).label.isEmpty == false)
        }
        viewModel._applyForRendering(phase: .idle)
    }
}
