import AppKit
import SwiftUI

/// Owns the main ZiA window.
///
/// Invariant: nothing in the app opens this window on its own. Background work,
/// streaming, TTS, provider probes and Agent Bridge activity never call `show()`.
/// Only an explicit user action (menu bar, HUD button, hotkey) does — and only
/// that call activates the application.
@MainActor
final class ZiaWindowController {
    static let shared = ZiaWindowController()

    private var window: NSWindow?

    private init() {}

    var isVisible: Bool { window?.isVisible ?? false }

    /// Show the window, creating it on first use. Explicit user intent only.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if isVisible {
            window?.orderOut(nil)
        } else {
            show()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ZiA"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.setFrameAutosaveName("ZiaMainWindow")
        window.animationBehavior = .documentWindow

        let hosting = NSHostingView(rootView: ZiaWindowView())
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        window.center()
        return window
    }
}
