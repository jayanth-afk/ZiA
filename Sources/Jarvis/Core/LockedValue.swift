import Foundation
import os

/// Thread-safe value wrapper using OSAllocatedUnfairLock for minimal latency synchronization.
public final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ value: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: value)
    }

    /// Access or update value within a locked closure
    public func withLock<T: Sendable>(_ body: @Sendable (inout Value) throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    /// Read or write value atomically
    public var value: Value {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    /// Read and modify in-place
    public func mutate(_ transform: @Sendable (inout Value) -> Void) {
        lock.withLock(transform)
    }
}