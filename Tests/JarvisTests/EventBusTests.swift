@testable import Jarvis
import XCTest

final class EventBusTests: XCTestCase {

    /// A test event type.
    struct TestEvent: JarvisEvent {
        let value: Int
    }

    struct AnotherEvent: JarvisEvent {
        let message: String
    }

    @MainActor
    override func setUp() {
        super.setUp()
        EventBus.shared.removeAll()
    }

    @MainActor
    func testPublishDeliversToSubscriber() {
        let bus = EventBus.shared
        var received: Int?

        bus.subscribe(TestEvent.self) { event in
            received = event.value
        }

        bus.publish(TestEvent(value: 42))

        XCTAssertEqual(received, 42)
    }

    @MainActor
    func testMultipleSubscribersReceiveSameEvent() {
        let bus = EventBus.shared
        var count = 0

        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.subscribe(TestEvent.self) { _ in count += 1 }

        bus.publish(TestEvent(value: 1))

        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testEventTypeIsolation() {
        let bus = EventBus.shared
        var testReceived = false
        var anotherReceived = false

        bus.subscribe(TestEvent.self) { _ in testReceived = true }
        bus.subscribe(AnotherEvent.self) { _ in anotherReceived = true }

        bus.publish(TestEvent(value: 1))

        XCTAssertTrue(testReceived)
        XCTAssertFalse(anotherReceived)
    }

    @MainActor
    func testUnsubscribeRemovesHandler() {
        let bus = EventBus.shared
        var count = 0

        let id = bus.subscribe(TestEvent.self) { _ in count += 1 }

        bus.publish(TestEvent(value: 1))
        XCTAssertEqual(count, 1)

        bus.unsubscribe(id)

        bus.publish(TestEvent(value: 2))
        XCTAssertEqual(count, 1, "Should not increment after unsubscribe")
    }

    @MainActor
    func testRemoveAllClearsEverything() {
        let bus = EventBus.shared
        var received = false

        bus.subscribe(TestEvent.self) { _ in received = true }

        bus.removeAll()
        bus.publish(TestEvent(value: 1))

        XCTAssertFalse(received)
    }

    @MainActor
    func testNoSubscribersDoesNotCrash() {
        let bus = EventBus.shared

        // Should not throw or crash
        bus.publish(TestEvent(value: 999))
        bus.publish(AnotherEvent(message: "hello"))
    }
}
