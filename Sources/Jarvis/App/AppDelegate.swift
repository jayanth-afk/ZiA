import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar accessory only
        NSApp.setActivationPolicy(.accessory)

        // TaskState's initializer validates and restores the complete durable
        // snapshot before any interaction path can resolve references or route
        // a continuation. Rejection stays visible and disables continuation.
        let taskStateMachine = TaskStateMachine.shared
        if !taskStateMachine.isPersistenceAvailable {
            JarvisLogger.security.error("Durable TaskState could not be restored; task continuation is disabled")
        }

        // Initialize core services
        let appState = AppState.shared
        let eventBus = EventBus.shared

        // Restore the persisted conversation window (SQLite) so memory
        // survives restart. CONTEXT ONLY: restored turns help understanding;
        // they never authorize an action (authority stays with the existing
        // gates and validators).
        ConversationManager.shared.loadPersistedHistory()

        // Storage retention: one explicit startup maintenance pass (never in
        // read paths, never on the interaction hot path). Bounds the SQLite
        // archive by age with a newest-N floor; the model context window is
        // independent and untouched.
        HistoryRetentionPolicy.enforce()

        // Setup menu bar
        menuBarManager = MenuBarManager(appState: appState, eventBus: eventBus)

        // Start monitors
        NetworkMonitor.shared.start()
        ResourceManager.shared.start()
        HotkeyManager.shared.register()

        // Background autonomy: durable scheduled jobs run through the normal
        // task system. Gated by autonomy level (>= L4). Never bypasses
        // planning, permission, execution, or verification.
        BackgroundAutonomy.shared.start()

        // Record startup health so degraded state is visible without guessing.
        Task { @MainActor in
            let report = await HealthService.shared.report()
            if report.overall != .healthy {
                JarvisLogger.app.warning("Zia health '\(report.overall.rawValue)': \(report.degradedCapabilities.joined(separator: "; "))")
            } else {
                JarvisLogger.app.info("Zia health: healthy")
            }
        }

        // Start voice pipeline
        VoicePipeline.shared.start()

        // Request permissions asynchronously if running in app bundle
        Task { @MainActor in
            await VoicePipeline.shared.requestPermissionsIfNeeded()
        }

        // Wire HUD and UI event listeners
        eventBus.subscribe(HotkeyPressedEvent.self) { _ in
            FloatingPanel.shared.toggle()
        }

        eventBus.subscribe(WakeWordDetectedEvent.self) { _ in
            FloatingPanel.shared.show()
        }

        eventBus.subscribe(EmergencyStopEvent.self) { _ in
            OverlayViewModel.shared.lastResponse = "EMERGENCY STOP EXECUTED"
            OverlayViewModel.shared.isStreaming = false
            AudioPlayer.shared.stopPlayback()
            TTSEngine.shared.stop()
        }

        eventBus.subscribe(TranscriptPartialEvent.self) { event in
            OverlayViewModel.shared.inputText = event.text
        }

        eventBus.subscribe(TranscriptFinalEvent.self) { event in
            OverlayViewModel.shared.inputText = event.text
        }

        eventBus.subscribe(StateChangedEvent.self) { event in
            if event.to == .off {
                FloatingPanel.shared.hide()
            }
        }

        // Transition to SLEEP (listening mode)
        appState.transition(to: .sleep)

        // Diagnostic affordance: `--show-ui` presents the overlay and the main
        // window at launch so both surfaces can be inspected in a live session.
        // Never triggered by normal startup.
        if CommandLine.arguments.contains("--show-ui") {
            FloatingPanel.shared.show()
            ZiaWindowController.shared.show()
            let overlayFrame = FloatingPanel.shared.frame
            let fitting = FloatingPanel.shared.contentFittingSize
            JarvisLogger.app.info(
                "[UI_TRACE] overlay visible=\(FloatingPanel.shared.isVisible, privacy: .public) x=\(overlayFrame.origin.x, privacy: .public) y=\(overlayFrame.origin.y, privacy: .public) w=\(overlayFrame.width, privacy: .public) h=\(overlayFrame.height, privacy: .public) fittingW=\(fitting.width, privacy: .public) fittingH=\(fitting.height, privacy: .public)")
            if let window = NSApp.windows.first(where: { $0.title == "ZiA" }) {
                let frame = window.frame
                JarvisLogger.app.info(
                    "[UI_TRACE] main visible=\(window.isVisible, privacy: .public) x=\(frame.origin.x, privacy: .public) y=\(frame.origin.y, privacy: .public) w=\(frame.width, privacy: .public) h=\(frame.height, privacy: .public) subviews=\(window.contentView?.subviews.count ?? 0, privacy: .public)")
            } else {
                JarvisLogger.app.error("[UI_TRACE] main window missing after show()")
            }
        }

        JarvisLogger.app.info("JARVIS initialized — \(ResourceManager.shared.totalMemoryMB)MB total memory")
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackgroundAutonomy.shared.stop()
        VoicePipeline.shared.stop()
        HotkeyManager.shared.unregister()
        NetworkMonitor.shared.stop()
        ResourceManager.shared.stop()
        AppState.shared.transition(to: .off)
        JarvisLogger.app.info("JARVIS shut down")
    }
}
