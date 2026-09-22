import Foundation

/// Typed event bus for decoupled subsystem communication.
///
/// All events must conform to `JarvisEvent` (which requires `Sendable`).
/// Publish/subscribe is synchronous on MainActor — events are delivered
/// immediately to all registered handlers in registration order.
///
/// Usage:
///   EventBus.shared.subscribe(StateChangedEvent.self) { event in
///       print("State changed to \(event.to)")
///   }
///   EventBus.shared.publish(StateChangedEvent(from: .off, to: .sleep))
@MainActor
final class EventBus {
    static let shared = EventBus()

    /// Each handler is boxed as (Any) -> Void to allow heterogeneous storage.
    /// The String key is the event type name for O(1) dispatch.
    private var handlers: [String: [(id: UUID, handler: (Any) -> Void)]] = [:]

    private init() {}

    /// Subscribe to a specific event type. Returns a subscription ID for later removal.
    @discardableResult
    func subscribe<E: JarvisEvent>(
        _ eventType: E.Type,
        handler: @escaping @MainActor (E) -> Void
    ) -> UUID {
        let key = String(describing: eventType)
        let id = UUID()

        handlers[key, default: []].append((id: id, handler: { event in
            if let typed = event as? E {
                handler(typed)
            }
        }))

        return id
    }

    /// Remove a specific subscription by ID.
    func unsubscribe(_ subscriptionID: UUID) {
        for key in handlers.keys {
            handlers[key]?.removeAll { $0.id == subscriptionID }
        }
    }

    /// Publish an event to all subscribers of that event type.
    func publish<E: JarvisEvent>(_ event: E) {
        let key = String(describing: E.self)

        JarvisLogger.events.debug("⚡ \(key)")

        guard let subs = handlers[key] else { return }
        for sub in subs {
            sub.handler(event)
        }
    }

    /// Remove all subscriptions (used in tests).
    func removeAll() {
        handlers.removeAll()
    }
}
