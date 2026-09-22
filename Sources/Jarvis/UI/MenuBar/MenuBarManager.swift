import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon) and its popover dropdown.
///
/// The icon changes based on JARVIS state:
///   OFF    → outline brain icon
///   SLEEP  → outline brain icon (listening indicator)
///   ACTIVE → filled brain icon
@MainActor
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState: AppState
    private let eventBus: EventBus
    private var stateSubscription: UUID?

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
        pop.contentSize = NSSize(width: 280, height: 220)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarView(appState: appState)
        )

        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = pop
    }

    // MARK: - Events

    private func subscribeToEvents() {
        stateSubscription = eventBus.subscribe(StateChangedEvent.self) { [weak self] _ in
            self?.updateIcon()
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch appState.state {
        case .off:
            symbolName = "brain.head.profile"
        case .sleep:
            symbolName = "brain.head.profile"
        case .active:
            symbolName = "brain.head.profile.fill"
        }

        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "JARVIS — \(appState.state.rawValue)"
        ) {
            image.isTemplate = true
            button.image = image
        }
    }
}
