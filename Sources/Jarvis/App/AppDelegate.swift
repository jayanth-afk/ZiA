import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar accessory only
        NSApp.setActivationPolicy(.accessory)

        // Initialize core services
        let appState = AppState.shared
        let eventBus = EventBus.shared

        // Restore the persisted conversation window (SQLite) so memory
        // survives restart. CONTEXT ONLY: restored turns help understanding;
        // they never authorize an action (authority stays with the existing
        // gates and validators).
        ConversationManager.shared.loadPersistedHistory()

        // Setup menu bar
        menuBarManager = MenuBarManager(appState: appState, eventBus: eventBus)

        // Start monitors
        NetworkMonitor.shared.start()
        ResourceManager.shared.start()
        HotkeyManager.shared.register()

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

        JarvisLogger.app.info("JARVIS initialized — \(ResourceManager.shared.totalMemoryMB)MB total memory")
    }

    func applicationWillTerminate(_ notification: Notification) {
        VoicePipeline.shared.stop()
        HotkeyManager.shared.unregister()
        NetworkMonitor.shared.stop()
        ResourceManager.shared.stop()
        AppState.shared.transition(to: .off)
        JarvisLogger.app.info("JARVIS shut down")
    }
}
