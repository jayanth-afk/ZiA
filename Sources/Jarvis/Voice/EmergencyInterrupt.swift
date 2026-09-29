import Foundation

/// Hardware-independent emergency safety monitor running outside the normal agent loop.
/// Immediately detects stop/cancel phrases and cancels all ongoing pipelines and tasks.
@MainActor
final class EmergencyInterrupt {
    static let shared = EmergencyInterrupt()

    private var emergencyPhrases: [String] {
        var phrases = [
            "stop",
            "cancel",
            "abort",
            "shut up",
            "emergency stop",
            "halt"
        ]
        for alias in Config.shared.wakeAliases {
            let lower = alias.lowercased()
            phrases.append("\(lower) stop")
            phrases.append("hey \(lower) stop")
        }
        return phrases
    }

    // MARK: - Emergency stop wiring

    /// Subscriptions registered by emergencyStopSubscriberCount; used by the
    /// integration audit to verify that the REAL app wiring responds to
    /// EmergencyStopEvent (no ad-hoc test listeners involved).
    private var eventSubscriptions: [UUID] = []
    private(set) var emergencyStopSubscriberCount = 0

    /// Registers the production emergency-stop wiring on the EventBus:
    /// TTS stop, AudioPlayer stop, SpeechRecognizer cancel, and
    /// TaskWorkerPool.cancelAll() must all happen via event propagation.
    func registerProductionSubscribers() {
        guard eventSubscriptions.isEmpty else { return }

        eventSubscriptions.append(EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            TTSEngine.shared.stop()
            AudioPlayer.shared.stopPlayback()
        })
        eventSubscriptions.append(EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            SpeechRecognizer.shared.cancelRecognition()
        })
        eventSubscriptions.append(EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            Task { await ShellExecutor.shared.cancelAll() }
        })
        eventSubscriptions.append(EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            Task { await BrowserManager.shared.cancelAutomation() }
        })
        eventSubscriptions.append(EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            Task<Void, Never> { await TaskWorkerPool.shared.cancelAll() }
        })
        eventSubscriptions.append(EventBus.shared.subscribe(EmergencyStopEvent.self) { _ in
            Task<Void, Never> { await AgentLoop.shared.emergencyCancel() }
        })

        emergencyStopSubscriberCount = eventSubscriptions.count
        JarvisLogger.security.info("EmergencyInterrupt production subscribers registered: \(self.emergencyStopSubscriberCount)")
    }

    /// Measured time to halt TTS, earcons, and any active speech-recognition
    /// session. State/task cleanup is still synchronous but is not audio-halt latency.
    private(set) var lastEmergencyHaltLatencyMs: Double?

    private init() {
        registerProductionSubscribers()
    }

    // MARK: - Public API

    /// Check if transcript or text contains an emergency phrase.
    /// If detected, immediately fires emergency stop sequence.
    @discardableResult
    func checkForEmergency(in text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        guard !words.isEmpty else { return false }
        let normalized = words.joined(separator: " ")

        // 1. Direct match with full emergency phrase
        for phrase in emergencyPhrases {
            if cleaned == phrase || normalized == phrase {
                triggerEmergencyStop(phrase: phrase)
                return true
            }
        }

        // 2. Short imperative command (<= 3 words), e.g., "jarvis stop", "please stop", "cancel that"
        if words.count <= 3 {
            for phrase in emergencyPhrases {
                if cleaned.hasPrefix(phrase) || cleaned.hasSuffix(phrase) || words.contains(phrase) {
                    // Prevent false positives on negative phrasing ("don't stop", "never stop")
                    if let stopIdx = words.firstIndex(of: phrase), stopIdx > 0 {
                        let prev = words[stopIdx - 1]
                        if prev == "dont" || prev == "don't" || prev == "not" || prev == "never" {
                            continue
                        }
                    }
                    triggerEmergencyStop(phrase: phrase)
                    return true
                }
            }
        }

        return false
    }

    /// Explicitly trigger emergency stop.
    func triggerEmergencyStop(phrase: String) {
        let start = CFAbsoluteTimeGetCurrent()

        // 1. Immediately kill all audio output
        TTSEngine.shared.stop()
        AudioPlayer.shared.stopPlayback()

        // 2. Cancel current speech recognition
        SpeechRecognizer.shared.cancelRecognition()

        // Measure the actual I/O halt boundary. State transitions and pending
        // confirmation cleanup remain synchronous below, before background
        // cancellation is published, but are not part of audio-stop latency.
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        lastEmergencyHaltLatencyMs = elapsed

        // 3. Fall back to SLEEP if currently ACTIVE
        if AppState.shared.state == .active {
            AppState.shared.transition(to: .sleep)
        }

        // 3b. Cancel any pending destructive actions (Preview/Commit) synchronously
        DestructiveActionManager.shared.cancel()

        // Keep synchronous OS logging out of the measured halt critical path;
        // log immediately after the user-facing stop has actually occurred.
        JarvisLogger.security.fault("EMERGENCY STOP TRIGGERED: '\(phrase, privacy: .public)'")
        JarvisLogger.security.info("Emergency stop halt completed in \(String(format: "%.2f", elapsed), privacy: .public)ms")

        // 4. Publish emergency event to cancel all background workers and tasks
        EventBus.shared.publish(EmergencyStopEvent(phrase: phrase))

        // 5. Deterministic acknowledgement corresponding to real emergency halt
        TTSEngine.shared.speak("Stopped.", mode: .acknowledgement)
    }
}
