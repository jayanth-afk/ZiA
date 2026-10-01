import Foundation
import os

public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()
    
    public typealias SubscriptionToken = UUID
    private typealias EventHandler = (Any) -> Void
    
    private struct Subscription {
        let eventType: ObjectIdentifier
        let handler: EventHandler
    }
    
    private var subscriptions = [SubscriptionToken: Subscription]()
    private var typeToTokens = [ObjectIdentifier: Set<SubscriptionToken>]()
    private let lock = OSAllocatedUnfairLock()
    
    public init() {}
    
    /// Subscribe to events with O(1) hash map registration.
    @discardableResult
    public func subscribe<T>(_ type: T.Type, handler: @escaping (T) -> Void) -> SubscriptionToken {
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
            typeToTokens[eventTypeId, default: []].insert(token)
        }
        
        return token
    }
    
    /// Unsubscribe with O(1) removal.
    public func unsubscribe(_ token: SubscriptionToken) {
        lock.withLock {
            guard let sub = subscriptions.removeValue(forKey: token) else { return }
            typeToTokens[sub.eventType]?.remove(token)
            if typeToTokens[sub.eventType]?.isEmpty == true {
                typeToTokens.removeValue(forKey: sub.eventType)
            }
        }
    }
    
    /// Publish event with zero lock contention during handler invocation.
    public func publish<T>(_ event: T) {
        let eventTypeId = ObjectIdentifier(T.self)
        
        var handlersToCall: [EventHandler] = []
        
        lock.withLock {
            guard let tokens = typeToTokens[eventTypeId] else { return }
            handlersToCall.reserveCapacity(tokens.count)
            for token in tokens {
                if let sub = subscriptions[token] {
                    handlersToCall.append(sub.handler)
                }
            }
        }
        
        for handler in handlersToCall {
            handler(event)
        }
    }
}