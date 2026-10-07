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

        // Natural Siri-like auto-dismissal: automatically fade when interaction succeeds or completes
        EventBus.shared.subscribe(InteractionPhaseChangedEvent.self) { [weak self] event in
            guard let self else { return }
            switch event.phase {
            case .success:
                self.scheduleAutoDismiss(after: 4.5)
            case .listening, .understanding, .thinking, .speaking, .executing:
                self.cancelAutoDismiss()
            case .idle, .stopped, .error:
                break
            }
        }
    }

    private var autoDismissTask: Task<Void, Never>?

    /// Schedule natural auto-dismissal when assistant is idle after completing a turn.
    func scheduleAutoDismiss(after delay: TimeInterval = 4.5) {
        cancelAutoDismiss()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isVisible else { return }
            let vm = OverlayViewModel.shared
            // Never dismiss while active, speaking, streaming, or listening
            if !vm.isStreaming && !vm.isSpeaking && vm.interactionPhase != .listening && vm.interactionPhase != .thinking {
                self.hideWithAnimation()
            }
        }
    }

    /// Cancel pending auto-dismissal (e.g. on user hover or interaction).
    func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    /// Hide the panel with a smooth macOS fade animation.
    func hideWithAnimation() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ZiaMotion.standard
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.hide()
            self?.alphaValue = 1
        }
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
