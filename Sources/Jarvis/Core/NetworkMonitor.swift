import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor.
///
/// Publishes `NetworkStatusChangedEvent` on connectivity changes.
/// Updates `AppState.isOnline` for system-wide visibility.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.jarvis.network", qos: .utility)

    private(set) var isOnline: Bool = true
    private(set) var isExpensive: Bool = false
    private(set) var isConstrained: Bool = false
    private(set) var connectionType: ConnectionType = .unknown

    enum ConnectionType: String, Sendable {
        case wifi
        case cellular
        case wired
        case unknown
    }

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let wasOnline = self.isOnline
                self.isOnline = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained

                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .wired
                } else {
                    self.connectionType = .unknown
                }

                if wasOnline != self.isOnline {
                    JarvisLogger.network.info(
                        "Network: \(self.isOnline ? "online" : "offline") (\(self.connectionType.rawValue))"
                    )

                    EventBus.shared.publish(NetworkStatusChangedEvent(
                        isOnline: self.isOnline,
                        connectionType: self.connectionType.rawValue
                    ))
                    AppState.shared.updateNetworkStatus(self.isOnline)
                }
            }
        }

        monitor.start(queue: queue)
        JarvisLogger.network.info("Network monitor started")
    }

    func stop() {
        monitor.cancel()
        JarvisLogger.network.info("Network monitor stopped")
    }
}
