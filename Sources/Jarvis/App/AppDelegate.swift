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

        // Setup menu bar
        menuBarManager = MenuBarManager(appState: appState, eventBus: eventBus)

        // Start monitors
        NetworkMonitor.shared.start()
        ResourceManager.shared.start()
        HotkeyManager.shared.register()

        // Start voice pipeline
        VoicePipeline.shared.start()

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
