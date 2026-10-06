import SwiftUI
import AppKit

/// Renders the real SwiftUI surfaces to PNG reference images.
///
/// This exists so the visual language can be inspected and diffed as files
/// instead of only in a running session: `swift run Jarvis --render-ui <dir>`.
/// It renders the actual views used by the app (identical components and
/// tokens), not a separate mock-up, so the references cannot drift from the
/// shipped UI.
///
/// Note: `ImageRenderer` captures a single static frame. Time-driven presence
/// layers therefore appear at a representative phase, and system materials
/// render as their flat fallback colour.
///
/// Second note: AppKit-backed controls do not rasterise faithfully here. A plain
/// `TextField` renders as an opaque light bar in a reference image while the
/// capsule fills around it resolve to the correct token values (verified against
/// the rendered pixels), so a composer reference shows that bar. It is a renderer
/// artefact, not the shipped appearance.
@MainActor
enum UIRenderHarness {
    struct Capture {
        let name: String
        let size: CGSize
        let dark: Bool
        /// Runs before this capture renders and again after it is written — used
        /// only when a surface depends on app state that must be restored.
        let prepare: @MainActor () -> Void
        let teardown: @MainActor () -> Void
        /// Main-actor isolated: it builds real views, which are actor-isolated too.
        let view: @MainActor () -> AnyView

        init(
            name: String,
            size: CGSize,
            dark: Bool,
            prepare: @escaping @MainActor () -> Void = {},
            teardown: @escaping @MainActor () -> Void = {},
            view: @escaping @MainActor () -> AnyView
        ) {
            self.name = name
            self.size = size
            self.dark = dark
            self.prepare = prepare
            self.teardown = teardown
            self.view = view
        }
    }

    /// Remembers whether first-run onboarding had already been completed, so the
    /// capture can show the real window and then put things back exactly.
    @MainActor
    private final class OnboardingSnapshot {
        var wasComplete = false
    }

    static func run(outputDirectory: String) async -> Int32 {
        // Preload asynchronous status so the reference images show real state
        // rather than a card that is still loading.
        await ZiaProviderModel.shared.refresh()
        ZiaPermissionModel.shared.refresh()
        ZiaActivityModel.shared.refresh()

        // The presence only renders frames while its container is on screen. A
        // headless capture *is* drawing the surface, so declare it visible.
        ZiaHUDVisibility.shared.update(true)

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("render-ui: could not create \(directory.path): \(error.localizedDescription)")
            return 1
        }

        var rendered = 0
        var failures: [String] = []

        for capture in captures() {
            capture.prepare()
            defer { capture.teardown() }
            for dark in [true, false] {
                let name = dark ? capture.name : capture.name + "-light"
                guard let data = render(capture.view(), size: capture.size, dark: dark) else {
                    failures.append(name)
                    continue
                }
                let url = directory.appendingPathComponent("\(name).png")
                do {
                    try data.write(to: url)
                    rendered += 1
                } catch {
                    failures.append(name)
                }
            }
        }

        // Leave no representative sample behind: the running app would otherwise
        // show energy the microphone never measured, and would look enabled.
        ZiaAudioMeter.shared.reset()
        ZiaHUDVisibility.shared.update(false)
        AppState.shared.transition(to: .off)

        print("render-ui: wrote \(rendered) reference image(s) to \(directory.path)")
        if !failures.isEmpty {
            print("render-ui: failures: \(failures.joined(separator: ", "))")
        }
        return failures.isEmpty ? 0 : 2
    }

    /// Reference-only sample buffer for the listening energy field: a speech-like
    /// envelope so the images show the *shape* of the treatment. It is not a
    /// measurement, it never reaches the running app, and every other capture
    /// renders the real (silent) meter.
    private static func representativeSpeechEnvelope() -> [Float] {
        (0..<ZiaAudioMeter.historyCount).map { index in
            let t = Double(index) / Double(max(1, ZiaAudioMeter.historyCount - 1))
            let syllable = 0.45 + 0.55 * sin(t * .pi * 7)
            let swell = 0.30 + 0.70 * sin(t * .pi)
            return Float(min(1, max(0.02, syllable * swell * 0.85)))
        }
    }

    /// Every surface we want a reference for. States in one image are laid out
    /// in a labelled row so a single file documents the state language.
    ///
    /// The HUD is captured at its real width (400 pt). Heights are generous on
    /// purpose: the panel sizes itself to its content, so a capture must never
    /// clip the composition it is documenting.
    private static func captures() -> [Capture] {
        let onboardingSnapshot = OnboardingSnapshot()
        return [
            Capture(name: "01-presence-states", size: CGSize(width: 1040, height: 220), dark: true) {
                AnyView(PresenceStateGallery())
            },
            Capture(name: "02-hud-idle", size: CGSize(width: 400, height: 260), dark: true) {
                HUDCapture(phase: .idle).view
            },
            Capture(name: "02b-hud-disabled", size: CGSize(width: 400, height: 260), dark: true) {
                HUDCapture(phase: .idle, appEnabled: false).view
            },
            Capture(name: "03-hud-listening", size: CGSize(width: 400, height: 380), dark: true) {
                ZiaAudioMeter.shared._applyForRendering(history: representativeSpeechEnvelope())
                return HUDCapture(
                    phase: .listening,
                    transcript: "open safari and search for the best coffee shops near me"
                ).view
            },
            Capture(name: "04-hud-understanding", size: CGSize(width: 400, height: 330), dark: true) {
                HUDCapture(
                    phase: .understanding,
                    transcript: "open safari and search for coffee shops near me",
                    settled: true
                ).view
            },
            Capture(name: "05-hud-thinking", size: CGSize(width: 400, height: 340), dark: true) {
                HUDCapture(phase: .thinking, streaming: true).view
            },
            Capture(name: "06-hud-working", size: CGSize(width: 400, height: 340), dark: true) {
                HUDCapture(phase: .executing, streaming: true).view
            },
            Capture(name: "07-hud-speaking", size: CGSize(width: 400, height: 330), dark: true) {
                HUDCapture(
                    phase: .speaking,
                    response: "Safari is open and searching for coffee shops near you."
                ).view
            },
            Capture(name: "08-hud-long-response", size: CGSize(width: 400, height: 480), dark: true) {
                HUDCapture(
                    phase: .success,
                    response: "Safari is open and searching for the best coffee shops near you. I took the fastest path here: the request needed no model call, so it completed immediately. Three results matched closely, and the closest one is a two minute walk from where you are now. Say the word and I'll open the directions, or ask me to compare opening hours across the three of them before you decide."
                ).view
            },
            Capture(name: "09-hud-error", size: CGSize(width: 400, height: 330), dark: true) {
                HUDCapture(
                    phase: .error,
                    failure: "ZiA couldn't reach its primary AI. Local fallback will be used where possible."
                ).view
            },
            Capture(name: "10-hud-stopped", size: CGSize(width: 400, height: 300), dark: true) {
                HUDCapture(phase: .stopped).view
            },
            Capture(name: "11-menu-bar", size: CGSize(width: 340, height: 520), dark: true) {
                AnyView(MenuBarView(appState: .shared).frame(width: 320).background(ZiaColors.background))
            },
            Capture(name: "12-settings-general", size: CGSize(width: 620, height: 560), dark: true) {
                AnyView(SettingsPage(title: "General") { GeneralSettingsView() })
            },
            Capture(name: "13-settings-voice", size: CGSize(width: 620, height: 660), dark: true) {
                AnyView(SettingsPage(title: "Voice") { VoiceSettingsView() })
            },
            Capture(name: "14-settings-appearance", size: CGSize(width: 620, height: 480), dark: true) {
                AnyView(SettingsPage(title: "Appearance") { AppearanceSettingsView() })
            },
            Capture(name: "15-providers", size: CGSize(width: 620, height: 520), dark: true) {
                AnyView(SettingsPage(title: "AI Providers") { ProviderSettingsView() })
            },
            Capture(name: "16-permissions", size: CGSize(width: 620, height: 520), dark: true) {
                AnyView(SettingsPage(title: "Permissions") { PermissionSettingsView() })
            },
            Capture(name: "17-diagnostics", size: CGSize(width: 620, height: 620), dark: true) {
                AnyView(SettingsPage(title: "Advanced") { HealthDiagnosticsSettingsView() })
            },
            Capture(name: "18-conversation", size: CGSize(width: 760, height: 700), dark: true) {
                AnyView(WindowSurfaceReferenceSample())
            },
            Capture(
                name: "19-real-window",
                size: CGSize(width: 760, height: 560),
                dark: true,
                prepare: {
                    onboardingSnapshot.wasComplete = ZiaOnboardingStore.shared.isComplete
                    ZiaOnboardingStore.shared.complete()
                },
                teardown: {
                    // Leave the first-run state exactly as it was found.
                    if !onboardingSnapshot.wasComplete { ZiaOnboardingStore.shared.reset() }
                }
            ) {
                AnyView(ZiaWindowView())
            },
            Capture(name: "20-active-work", size: CGSize(width: 620, height: 420), dark: true) {
                AnyView(SettingsPage(title: "Active work") { TaskReferenceSample() })
            },
            Capture(name: "21-states-empty-error", size: CGSize(width: 620, height: 460), dark: true) {
                AnyView(StateReferenceSample())
            },
            Capture(name: "22-onboarding", size: CGSize(width: 760, height: 640), dark: true) {
                AnyView(OnboardingView(onContinue: {}))
            }
        ]
    }

    /// Applies a real overlay state and returns the live HUD view for capture.
    ///
    /// The HUD reads enablement from the real `AppState`, so the capture sets it
    /// the way the app itself does — a fresh process starts disabled, which is
    /// why the disabled variant is captured explicitly rather than by accident.
    @MainActor
    private struct HUDCapture {
        private let phase: InteractionPhase

        init(
            phase: InteractionPhase,
            appEnabled: Bool = true,
            response: String = "",
            transcript: String = "",
            failure: String? = nil,
            streaming: Bool = false,
            settled: Bool = false
        ) {
            self.phase = phase
            AppState.shared.transition(to: appEnabled ? .sleep : .off)
            // Every field is written on every capture, so no state can leak from
            // one reference image into the next.
            OverlayViewModel.shared._applyForRendering(
                phase: phase,
                response: response,
                transcript: transcript,
                failure: failure,
                streaming: streaming,
                settled: settled
            )
        }

        var view: AnyView { AnyView(OverlayView()) }
    }

    private static func render(_ view: AnyView, size: CGSize, dark: Bool) -> Data? {
        let framed = view
            .frame(width: size.width, height: size.height)
            .background(ZiaColors.background)
            .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2

        // ZiA's semantic colors are dynamic NSColors. Resolving them requires the
        // matching NSAppearance to be current while the image is drawn, otherwise
        // both variants render with the host appearance.
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return }
            data = bitmap.representation(using: .png, properties: [:])
        }
        return data
    }
}

// MARK: - Reference compositions

/// Settings pane wrapped in the same page chrome the real Settings window uses.
struct SettingsPage<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    // Deliberately no ScrollView: `ImageRenderer` does not rasterise scroll
    // content, so a scrolled page would capture as an empty surface.
    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            Text(title)
                .font(ZiaType.largeTitle)
                .foregroundStyle(ZiaColors.textPrimary)
            content
        }
        .padding(ZiaSpace.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZiaColors.background)
    }
}

/// The presence language: one image for every state ZiA can be in. Captions name
/// what the *motion* does, because a still frame cannot show it.
struct PresenceStateGallery: View {
    private let states: [(ZiaPresenceState, String)] = [
        (.idle, "Almost still"),
        (.listening, "Driven by your voice"),
        (.understanding, "Folds inward"),
        (.thinking, "Light reorganises"),
        (.working, "Held, breathing"),
        (.speaking, "Expands outward"),
        (.done, "Settles"),
        (.error, "Dim, red-shifted"),
        (.stopped, "Cooled"),
        (.disabled, "Off")
    ]

    var body: some View {
        HStack(spacing: ZiaSpace.lg) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: ZiaSpace.sm) {
                    ZiaPresenceOrb(state: entry.0, size: 56)
                    Text(entry.0.label)
                        .font(ZiaType.captionEmphasis)
                        .foregroundStyle(ZiaColors.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    Text(entry.1)
                        .font(ZiaType.metadata)
                        .foregroundStyle(ZiaColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(width: 84)
                }
            }
        }
        .padding(ZiaSpace.xxl)
        .background(ZiaColors.background)
    }
}

/// The conversation surface as it actually composes: the real message rows in the
/// readable column, plus the real composer. `ImageRenderer` cannot rasterise a
/// `ScrollView`, so the column is laid out directly here.
struct WindowSurfaceReferenceSample: View {
    private let turns: [ZiaConversationModel.Turn] = [
        ZiaConversationModel.Turn(
            id: "1", kind: .user,
            text: "Open Safari and search for the best coffee shops near me",
            timestamp: .now, isWaiting: false),
        ZiaConversationModel.Turn(
            id: "2", kind: .assistant,
            text: "Safari is open and searching. I took the fastest path: the action needed no model call, so it completed immediately. Here are the top three results I found.",
            timestamp: .now, isWaiting: false),
        ZiaConversationModel.Turn(
            id: "3", kind: .assistant,
            text: "", timestamp: .now, isWaiting: true),
        ZiaConversationModel.Turn(
            id: "4", kind: .failure,
            text: "ZiA couldn't reach its primary AI. Local fallback will be used where possible.",
            timestamp: .now, isWaiting: false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(turns) { turn in
                ZiaMessageRow(turn: turn, statusNote: "Working…")
            }
        }
        .frame(maxWidth: ZiaSpace.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 34)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            ZiaComposer(
                text: .constant(""),
                isWorking: false,
                isListening: false,
                tone: .surface,
                onSubmit: { _ in },
                onMic: {}
            )
            .frame(maxWidth: ZiaSpace.readableWidth)
            .padding(.horizontal, 34)
            .padding(.bottom, 26)
        }
        .background(ZiaColors.background)
    }
}

/// Background-work reference built from a real `JarvisTask` value.
struct TaskReferenceSample: View {
    private var task: JarvisTask {
        var task = JarvisTask(title: "Prepare weekly summary", goal: "Prepare the weekly summary and save it")
        task.state = .running
        task.steps = [
            TaskStep(stepNumber: 1, description: "Gather recent activity", toolName: "read_file",
                     state: .completed, verification: .passed),
            TaskStep(stepNumber: 2, description: "Open Safari", toolName: "open_app",
                     state: .completed, verification: .passed),
            TaskStep(stepNumber: 3, description: "Compose the summary", toolName: nil, state: .running),
            TaskStep(stepNumber: 4, description: "Save to Documents", toolName: "write_file", state: .created)
        ]
        return task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.lg) {
            ZiaTaskCard(task: task)
            ZiaActivityStrip(onReveal: {})
        }
        .padding(ZiaSpace.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZiaColors.background)
    }
}

/// Empty and error states side by side.
struct StateReferenceSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZiaSpace.xxl) {
            ZiaCard(title: "No conversations yet", symbol: "sparkles") {
                ZiaEmptyState(
                    symbol: "sparkles",
                    title: "Ask ZiA anything",
                    message: "Type a request, or hold the shortcut from any app.")
                .frame(height: 160)
            }
            ZiaErrorView(
                title: "ZiA couldn't reach its primary AI",
                message: "ChatGPT Desktop isn't responding right now.",
                detail: "providerError(provider: \"chatgpt-desktop\", message: \"app not running\")",
                recovery: [("Retry", {}), ("Use local AI", {})])
        }
        .padding(ZiaSpace.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZiaColors.background)
    }
}
