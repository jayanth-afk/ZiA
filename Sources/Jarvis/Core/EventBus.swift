import Foundation
import os

public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()

    public typealias SubscriptionToken = UUID
    private typealias EventHandler = @MainActor (any Sendable) -> Void

    private struct Subscription: @unchecked Sendable {
        let eventType: ObjectIdentifier
        let handler: EventHandler
    }

    private var subscriptions = [SubscriptionToken: Subscription]()
    private var typeToTokens = [ObjectIdentifier: [SubscriptionToken]]()
    private let lock = OSAllocatedUnfairLock()

    public init() {}

    /// Subscribe to a typed event. Handlers always run on MainActor.
    @discardableResult
    public func subscribe<T: Sendable>(
        _ type: T.Type,
        handler: @escaping @MainActor (T) -> Void
    ) -> SubscriptionToken {
        let token = UUID()
        let eventTypeId = ObjectIdentifier(type)

        let wrappedHandler: EventHandler = { event in
            if let typedEvent = event as? T {
                handler(typedEvent)
            }
        }

        let sub = Subscription(eventType: eventTypeId, handler: wrappedHandler)

        lock.withLock {
            subscriptions[token] = sub
            typeToTokens[eventTypeId, default: []].append(token)
        }

        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        lock.withLock {
            guard let sub = subscriptions.removeValue(forKey: token) else { return }
            typeToTokens[sub.eventType]?.removeAll { $0 == token }
            if typeToTokens[sub.eventType]?.isEmpty == true {
                typeToTokens.removeValue(forKey: sub.eventType)
            }
        }
    }

    public func removeAll() {
        lock.withLock {
            subscriptions.removeAll()
            typeToTokens.removeAll()
        }
    }

    /// Snapshot under the lock, then deliver without holding it across callbacks.
    public func publish<T: Sendable>(_ event: T) {
        let eventTypeId = ObjectIdentifier(T.self)

        let handlersToCall = lock.withLock { () -> [Subscription] in
            guard let tokens = typeToTokens[eventTypeId] else { return [] }
            return tokens.compactMap { subscriptions[$0] }
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handlersToCall.forEach { $0.handler(event) }
            }
        } else {
            Task { @MainActor in
                handlersToCall.forEach { $0.handler(event) }
            }
        }
    }
}