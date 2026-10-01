import Foundation
import os

/// Thread-safe value wrapper using OSAllocatedUnfairLock for minimal latency synchronization.
public final class LockedValue<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = OSAllocatedUnfairLock()

    public init(_ value: Value) {
        self._value = value
    }

    /// Access or update value within a locked closure
    @inlinable
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock {
            try body(&_value)
        }
    }

    /// Read or write value atomically
    @inlinable
    public var value: Value {
        get {
            lock.withLock { _value }
        }
        set {
            lock.withLock { _value = newValue }
        }
    }

    /// Read and modify in-place
    @inlinable
    public func mutate(_ transform: (inout Value) -> Void) {
        lock.withLock {
            transform(&_value)
        }
    }
}