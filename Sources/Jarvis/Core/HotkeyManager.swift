import Foundation
import HotKey
import Carbon

/// Global hotkey manager (Option+Space).
///
/// Publishes `HotkeyPressedEvent` through EventBus and toggles
/// JARVIS state between SLEEP ↔ ACTIVE.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkey: HotKey?

    private init() {}

    func register() {
        guard Config.shared.hotkeyEnabled else {
            JarvisLogger.app.info("Hotkey disabled in config")
            return
        }

        // Option + Space
        hotkey = HotKey(key: .space, modifiers: [.option])

        hotkey?.keyDownHandler = {
            JarvisLogger.app.info("Hotkey pressed: Option+Space")
            EventBus.shared.publish(HotkeyPressedEvent())

            let state = AppState.shared.state
            switch state {
            case .sleep:
                AppState.shared.transition(to: .active)
            case .active:
                AppState.shared.transition(to: .sleep)
            case .off:
                // Enable JARVIS if it was off
                AppState.shared.transition(to: .sleep)
            }
        }

        JarvisLogger.app.info("Hotkey registered: Option+Space")
    }

    func unregister() {
        hotkey = nil
        JarvisLogger.app.info("Hotkey unregistered")
    }
}
