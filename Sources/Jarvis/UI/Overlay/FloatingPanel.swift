import AppKit
import SwiftUI

/// Floating, non-activating HUD overlay panel.
///
/// Deliberately non-activating: showing the HUD must never move the user's
/// Space or pull focus away from what they are doing. It joins all Spaces and
/// floats above full-screen windows, and it sizes itself to its content so
/// nothing is clipped at any appearance or text size.
@MainActor
final class FloatingPanel: NSPanel {
    static let shared = FloatingPanel()

    static let panelWidth: CGFloat = 400

    private var hostingView: NSHostingView<AnyView>?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 320),
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
        hasShadow = true
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false

        // Visual Effect View background keeps the HUD legible over any content.
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 320))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.autoresizingMask = [.width, .height]
        // The window is borderless, so the glass must clip itself to the HUD's
        // rounded silhouette — otherwise the blur bleeds into square corners.
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = ZiaRadius.hud
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.cornerCurve = .continuous

        let hosting = NSHostingView(rootView: AnyView(OverlayView()))
        hosting.frame = visualEffect.bounds
        hosting.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hosting)
        hostingView = hosting

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

    /// Present the HUD without activating the application.
    func show() {
        sizeToFitContent()
        centerOnScreen()
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ZiaMotion.reduceMotion ? 0 : ZiaMotion.standard
                animator().alphaValue = 1
            }
        } else {
            makeKeyAndOrderFront(nil)
        }
        // The presence is the most expensive surface in the app: tell it it is
        // actually on screen so it renders frames, and freeze it when hidden.
        ZiaHUDVisibility.shared.update(true)
        // Only becomes key so typed input works; the app itself is not activated
        // and the user's Space is not changed.
        makeKey()

        // A hosting view that has never been in a window can report an empty
        // fitting size. Re-fit once the panel is on screen so the HUD is never
        // clipped or padded.
        DispatchQueue.main.async { [weak self] in
            self?.sizeToFitContent()
            self?.centerOnScreen()
        }
    }

    /// The size the SwiftUI content wants, for diagnostics and layout checks.
    var contentFittingSize: CGSize {
        guard let hostingView else { return .zero }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let intrinsic = hostingView.intrinsicContentSize
        return CGSize(width: max(fitting.width, intrinsic.width),
                      height: max(fitting.height, intrinsic.height))
    }

    func hide() {
        orderOut(nil)
        ZiaHUDVisibility.shared.update(false)
    }

    // MARK: - Layout

    /// Resize the panel to the SwiftUI content's fitting height.
    private func sizeToFitContent() {
        let wanted = contentFittingSize.height
        // Unknown size (not yet laid out) must not force a wrong one.
        guard wanted > 1 else { return }
        let height = max(160, min(wanted, 760))
        guard abs(frame.height - height) > 1 else { return }
        setContentSize(NSSize(width: Self.panelWidth, height: height))
        invalidateShadow()
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let x = screenRect.midX - frame.width / 2
        let y = screenRect.midY + screenRect.height * 0.15 // Slightly upper-center
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override var canBecomeKey: Bool { true }
}
