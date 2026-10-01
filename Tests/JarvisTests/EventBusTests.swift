@testable import Jarvis
import Testing

@Suite struct EventBusTests {

    /// A test event type.
    struct TestEvent: JarvisEvent {
        let value: Int
    }

    struct AnotherEvent: JarvisEvent {
        let message: String
    }

    @MainActor
    init() {
        EventBus.shared.removeAll()
    }

    @Test @MainActor
    func publishDeliversToSubscriber() {
        let bus = EventBus.shared
        var received: Int?

        bus.subscribe(TestEvent.self) { event in
            received = event.value
        }

        bus.publish(TestEvent(value: 42))

        #expect(received == 42)
    }

    @Test @MainActor
    func multipleSubscribersReceiveSameEvent() {
        let bus = EventBus.shared
        var count = 0

        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.subscribe(TestEvent.self) { _ in count += 1 }

        bus.publish(TestEvent(value: 1))

        #expect(count == 3)
    }

    @Test @MainActor
    func eventTypeIsolation() {
        let bus = EventBus.shared
        var testReceived = false
        var anotherReceived = false

        bus.subscribe(TestEvent.self) { _ in testReceived = true }
        bus.subscribe(AnotherEvent.self) { _ in anotherReceived = true }

        bus.publish(TestEvent(value: 1))

        #expect(testReceived)
        #expect(!anotherReceived)
    }

    @Test @MainActor
    func unsubscribeRemovesHandler() {
        let bus = EventBus.shared
        var count = 0

        let id = bus.subscribe(TestEvent.self) { _ in count += 1 }

        bus.publish(TestEvent(value: 1))
        #expect(count == 1)

        bus.unsubscribe(id)

        bus.publish(TestEvent(value: 2))
        #expect(count == 1, "Should not increment after unsubscribe")
    }

    @Test @MainActor
    func removeAllClearsEverything() {
        let bus = EventBus.shared
        var received = false

        bus.subscribe(TestEvent.self) { _ in received = true }

        bus.removeAll()
        bus.publish(TestEvent(value: 1))

        #expect(!received)
    }

    @Test @MainActor
    func noSubscribersDoesNotCrash() {
        let bus = EventBus.shared

        // Should not throw or crash
        bus.publish(TestEvent(value: 999))
        bus.publish(AnotherEvent(message: "hello"))
    }
}
