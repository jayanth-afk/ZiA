import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon) and its popover dropdown.
///
/// The icon reflects the real interaction phase, not just enablement:
///   disabled → outline sparkle
///   idle     → filled sparkle
///   listening→ waveform
///   working  → sparkle (animated state shown in the popover)
///   speaking → speaker
///   error    → warning triangle
@MainActor
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState: AppState
    private let eventBus: EventBus
    private var stateSubscription: UUID?
    private var phaseSubscription: UUID?

    private var phase: InteractionPhase = .idle

    init(appState: AppState, eventBus: EventBus) {
        self.appState = appState
        self.eventBus = eventBus

        setupStatusItem()
        subscribeToEvents()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        updateIcon()

        button.action = #selector(togglePopover)
        button.target = self
        button.toolTip = "ZiA"
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 320, height: 430)
        pop.behavior = .transient
        pop.animates = !ZiaMotion.reduceMotion
        pop.contentViewController = NSHostingController(
            rootView: MenuBarView(appState: appState)
                .preferredColorScheme(ZiaAppearanceStore.shared.appearance.colorScheme)
        )

        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = pop
    }

    // MARK: - Events

    private func subscribeToEvents() {
        stateSubscription = eventBus.subscribe(StateChangedEvent.self) { [weak self] _ in
            self?.updateIcon()
        }
        phaseSubscription = eventBus.subscribe(InteractionPhaseChangedEvent.self) { [weak self] event in
            self?.phase = event.phase
            self?.updateIcon()
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        if appState.state == .off {
            symbolName = "sparkle"
        } else {
            switch phase {
            case .listening: symbolName = "waveform"
            case .speaking: symbolName = "speaker.wave.2.fill"
            case .error: symbolName = "exclamationmark.triangle"
            case .success: symbolName = "checkmark.circle"
            case .understanding, .thinking, .executing: symbolName = "sparkles"
            case .stopped: symbolName = "pause.circle"
            case .idle: symbolName = "sparkle"
            }
        }

        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "ZiA — \(appState.state.rawValue)"
        ) {
            image.isTemplate = true
            button.image = image
        }
    }
}
