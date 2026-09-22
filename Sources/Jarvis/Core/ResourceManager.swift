import Foundation
import Darwin

/// Dynamic resource manager that monitors real memory pressure and
/// makes model load/evict decisions based on actual system state.
///
/// This is NOT a static memory budget table. It observes:
///   - System memory pressure via dispatch source
///   - Available memory via vm_statistics
///   - Loaded model footprints (registered by providers)
///   - Configured reserve (default 4GB for macOS + other apps)
///
/// Decision outputs:
///   - canLoadModel(estimatedMB:) → Bool
///   - modelsToEvict() → [String] (least recently used first)
///   - shouldEvictModel(_:) → Bool
@MainActor
final class ResourceManager {
    static let shared = ResourceManager()

    // MARK: - Types

    enum PressureLevel: String, Sendable, Comparable {
        case nominal
        case warning
        case critical

        static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
            let order: [PressureLevel] = [.nominal, .warning, .critical]
            guard let l = order.firstIndex(of: lhs),
                  let r = order.firstIndex(of: rhs) else { return false }
            return l < r
        }
    }

    struct ModelInfo: Sendable {
        let name: String
        let estimatedMemoryMB: Int
        let loadedAt: Date
        var lastUsedAt: Date
    }

    // MARK: - State

    private(set) var currentPressure: PressureLevel = .nominal
    private(set) var availableMemoryMB: Int = 0
    let totalMemoryMB: Int

    /// Currently loaded models, keyed by name.
    private(set) var loadedModels: [String: ModelInfo] = [:]

    // MARK: - Private

    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollingTimer: Timer?

    private init() {
        totalMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
    }

    // MARK: - Lifecycle

    func start() {
        // 1. Memory pressure dispatch source (fires on system-level warnings)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let data = source.data
                if data.contains(.critical) {
                    self.handlePressureChange(.critical)
                } else if data.contains(.warning) {
                    self.handlePressureChange(.warning)
                }
            }
        }

        source.resume()
        pressureSource = source

        // 2. Poll available memory every 5s for proactive decisions
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollMemory()
            }
        }

        pollMemory()
        JarvisLogger.resources.info(
            "ResourceManager started — total: \(self.totalMemoryMB)MB, reserve: \(Config.shared.memoryReserveMB)MB"
        )
    }

    func stop() {
        pressureSource?.cancel()
        pressureSource = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Model Management

    /// Check if we can load a model of the given estimated size.
    func canLoadModel(estimatedMB: Int) -> Bool {
        guard currentPressure != .critical else { return false }

        let reserveMB = Config.shared.memoryReserveMB
        let currentModelMB = loadedModels.values.reduce(0) { $0 + $1.estimatedMemoryMB }
        let budgetMB = totalMemoryMB - reserveMB
        let projectedMB = currentModelMB + estimatedMB

        let allowed = projectedMB <= budgetMB
        if !allowed {
            JarvisLogger.resources.warning(
                "Cannot load model (~\(estimatedMB)MB): budget \(budgetMB)MB, used \(currentModelMB)MB"
            )
        }
        return allowed
    }

    /// Register that a model was loaded into memory.
    func registerModelLoaded(_ name: String, estimatedMB: Int) {
        loadedModels[name] = ModelInfo(
            name: name,
            estimatedMemoryMB: estimatedMB,
            loadedAt: .now,
            lastUsedAt: .now
        )
        JarvisLogger.resources.info("Model loaded: \(name) (~\(estimatedMB)MB)")
    }

    /// Register that a model was unloaded from memory.
    func registerModelUnloaded(_ name: String) {
        loadedModels.removeValue(forKey: name)
        JarvisLogger.resources.info("Model unloaded: \(name)")
    }

    /// Mark a model as recently used (prevents idle eviction).
    func markModelUsed(_ name: String) {
        loadedModels[name]?.lastUsedAt = .now
    }

    /// Returns model names that should be evicted, ordered by least recently used.
    /// Called when memory pressure rises or idle timeout expires.
    func modelsToEvict() -> [String] {
        guard currentPressure >= .warning else { return [] }

        return loadedModels.values
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
            .map(\.name)
    }

    /// Check if a specific model should be evicted due to idle timeout.
    func shouldEvictIdleModel(_ name: String) -> Bool {
        guard let model = loadedModels[name] else { return false }
        let idleSeconds = Date.now.timeIntervalSince(model.lastUsedAt)
        return idleSeconds > Config.shared.modelIdleEvictionSeconds
    }

    /// Total memory currently used by loaded models.
    var totalModelMemoryMB: Int {
        loadedModels.values.reduce(0) { $0 + $1.estimatedMemoryMB }
    }

    // MARK: - Private

    private func handlePressureChange(_ level: PressureLevel) {
        guard level != currentPressure else { return }
        let previous = currentPressure
        currentPressure = level

        JarvisLogger.resources.warning(
            "Memory pressure: \(previous.rawValue) → \(level.rawValue) (available: \(self.availableMemoryMB)MB)"
        )

        EventBus.shared.publish(MemoryPressureChangedEvent(
            level: level,
            availableMemoryMB: availableMemoryMB
        ))
        AppState.shared.updateMemoryPressure(level)
    }

    private func pollMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = UInt64(getpagesize())
            let free = UInt64(stats.free_count) * pageSize
            let inactive = UInt64(stats.inactive_count) * pageSize
            availableMemoryMB = Int((free + inactive) / 1024 / 1024)
        }

        // Proactive pressure detection (supplement to dispatch source)
        if availableMemoryMB < 512 && currentPressure == .nominal {
            handlePressureChange(.warning)
        } else if availableMemoryMB < 256 && currentPressure == .warning {
            handlePressureChange(.critical)
        } else if availableMemoryMB >= 2048 && currentPressure != .nominal {
            handlePressureChange(.nominal)
        }
    }
}
