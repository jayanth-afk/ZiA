import AppKit
import SwiftUI

/// Floating, non-activating HUD overlay panel.
/// Displays above full screen apps and windows with smooth glassmorphism.
@MainActor
final class FloatingPanel: NSPanel {
    static let shared = FloatingPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // Shadow handled by SwiftUI overlay

        // Visual Effect View background
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow

        let hostingView = NSHostingView(rootView: OverlayView())
        hostingView.frame = visualEffect.bounds
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        contentView = visualEffect

        centerOnScreen()
    }

    // MARK: - Display Control

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        centerOnScreen()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func hide() {
        orderOut(nil)
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let x = screenRect.midX - frame.width / 2
        let y = screenRect.midY + screenRect.height * 0.15 // Slightly upper-center
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
