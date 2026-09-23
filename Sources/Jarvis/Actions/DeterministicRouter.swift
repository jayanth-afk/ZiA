import Foundation

/// Matches incoming spoken or typed transcripts to deterministic actions in 0ms without invoking an LLM.
@MainActor
final class DeterministicRouter {
    static let shared = DeterministicRouter()

    struct Match: Sendable {
        let intent: String
        let parameters: [String: String]
        let action: @Sendable () async throws -> String
    }

    private init() {}

    // MARK: - Public API

    /// Match a transcript to a known deterministic command.
    /// Returns nil if the query requires an LLM / reflex model.
    func match(_ transcript: String) -> Match? {
        let lower = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        // Strip leading wake word if present ("jarvis, open safari" -> "open safari")
        let cleaned = stripWakeWord(from: lower)

        // 1. App control: "open safari", "launch chrome", "quit mail"
        if let app = matchAppCommand(cleaned) { return app }

        // 2. Volume control: "set volume to 50", "volume up", "mute"
        if let vol = matchVolumeCommand(cleaned) { return vol }

        // 3. Time & Date: "what time is it", "what's today's date"
        if let timeDate = matchTimeDateQuery(cleaned) { return timeDate }

        // 4. System controls: "lock screen", "empty trash"
        if let sys = matchSystemCommand(cleaned) { return sys }

        // 5. Clipboard: "read clipboard", "clear clipboard"
        if let clip = matchClipboardCommand(cleaned) { return clip }

        // 6. System Status: "memory status", "system status"
        if let status = matchStatusCommand(cleaned) { return status }

        return nil
    }

    // MARK: - Matchers

    private func matchAppCommand(_ text: String) -> Match? {
        // Launch / Open
        let openPrefixes = ["open ", "launch ", "start ", "switch to "]
        for prefix in openPrefixes {
            if text.hasPrefix(prefix) {
                let appName = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .punctuationCharacters)
                guard !appName.isEmpty else { continue }
                return Match(
                    intent: "app.open",
                    parameters: ["app": appName],
                    action: { try await AppLauncher.shared.open(appName) }
                )
            }
        }

        // Close / Quit
        let closePrefixes = ["close ", "quit ", "kill ", "exit "]
        for prefix in closePrefixes {
            if text.hasPrefix(prefix) {
                let appName = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .punctuationCharacters)
                guard !appName.isEmpty else { continue }
                return Match(
                    intent: "app.quit",
                    parameters: ["app": appName],
                    action: { try await AppLauncher.shared.quit(appName) }
                )
            }
        }

        return nil
    }

    private func matchVolumeCommand(_ text: String) -> Match? {
        // Specific volume level: "set volume to 50", "volume 75%", "set volume 30"
        if text.hasPrefix("set volume to ") || text.hasPrefix("set volume ") || text.hasPrefix("volume ") {
            let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let level = Int(digits), level >= 0 && level <= 100 {
                return Match(
                    intent: "system.volume.set",
                    parameters: ["level": String(level)],
                    action: { try await MainActor.run { try SystemControl.shared.setVolume(level) } }
                )
            }
        }

        // Relative volume: "volume up", "increase volume", "louder"
        if text == "volume up" || text == "increase volume" || text == "turn it up" || text == "louder" {
            return Match(
                intent: "system.volume.up",
                parameters: [:],
                action: { try await MainActor.run { try SystemControl.shared.volumeUp() } }
            )
        }

        // Relative volume: "volume down", "decrease volume", "quieter"
        if text == "volume down" || text == "decrease volume" || text == "turn it down" || text == "quieter" {
            return Match(
                intent: "system.volume.down",
                parameters: [:],
                action: { try await MainActor.run { try SystemControl.shared.volumeDown() } }
            )
        }

        // Mute / Unmute
        if text == "mute" || text == "mute audio" || text == "mute volume" || text == "silence" {
            return Match(
                intent: "system.volume.mute",
                parameters: [:],
                action: { try await MainActor.run { try SystemControl.shared.mute() } }
            )
        }

        if text == "unmute" || text == "unmute audio" || text == "unmute volume" {
            return Match(
                intent: "system.volume.unmute",
                parameters: [:],
                action: { try await MainActor.run { try SystemControl.shared.unmute() } }
            )
        }

        return nil
    }

    private func matchTimeDateQuery(_ text: String) -> Match? {
        let timeQueries = ["what time is it", "what's the time", "tell me the time", "current time", "what is the time"]
        if timeQueries.contains(text) {
            return Match(
                intent: "system.time",
                parameters: [:],
                action: {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    return "The time is \(formatter.string(from: Date()))."
                }
            )
        }

        let dateQueries = ["what date is it", "what's the date", "what is the date", "what is today's date", "what day is it", "today's date"]
        if dateQueries.contains(text) {
            return Match(
                intent: "system.date",
                parameters: [:],
                action: {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .full
                    return "Today is \(formatter.string(from: Date()))."
                }
            )
        }

        return nil
    }

    private func matchSystemCommand(_ text: String) -> Match? {
        if text == "lock screen" || text == "lock mac" || text == "lock the screen" || text == "lock my mac" {
            return Match(
                intent: "system.lock",
                parameters: [:],
                action: { try await MainActor.run { try SystemControl.shared.lockScreen() } }
            )
        }

        if text == "empty trash" || text == "empty the trash" {
            return Match(
                intent: "system.emptyTrash",
                parameters: [:],
                action: { try await MainActor.run { try SystemControl.shared.emptyTrash() } }
            )
        }

        return nil
    }

    private func matchClipboardCommand(_ text: String) -> Match? {
        if text == "read clipboard" || text == "what's on my clipboard" || text == "what is on my clipboard" || text == "clipboard content" {
            return Match(
                intent: "clipboard.read",
                parameters: [:],
                action: {
                    if let text = await MainActor.run { ClipboardManager.shared.getClipboardText() } {
                        return "Clipboard contains: \(text)"
                    } else {
                        return "Clipboard is empty"
                    }
                }
            )
        }

        if text == "clear clipboard" || text == "empty clipboard" {
            return Match(
                intent: "clipboard.clear",
                parameters: [:],
                action: {
                    await MainActor.run { ClipboardManager.shared.clearClipboard() }
                    return "Clipboard cleared"
                }
            )
        }

        return nil
    }

    private func matchStatusCommand(_ text: String) -> Match? {
        if text == "system status" || text == "status" || text == "diagnostics" {
            return Match(
                intent: "system.status",
                parameters: [:],
                action: {
                    await MainActor.run {
                        let mem = ResourceManager.shared.totalMemoryMB
                        let pressure = ResourceManager.shared.currentPressure.rawValue
                        let online = AppState.shared.isOnline ? "online" : "offline"
                        return "All systems operational. Memory is \(mem)MB (\(pressure) pressure), network is \(online)."
                    }
                }
            )
        }

        if text == "memory status" || text == "ram status" {
            return Match(
                intent: "system.memory",
                parameters: [:],
                action: {
                    await MainActor.run {
                        let mem = ResourceManager.shared.totalMemoryMB
                        let pressure = ResourceManager.shared.currentPressure.rawValue
                        let models = ResourceManager.shared.totalModelMemoryMB
                        return "Total memory: \(mem)MB. Memory pressure is \(pressure). Models using \(models)MB."
                    }
                }
            )
        }

        return nil
    }

    // MARK: - Private Helper

    private func stripWakeWord(from text: String) -> String {
        let wakeWord = Config.shared.wakeWord.lowercased()
        if text.hasPrefix(wakeWord) {
            var stripped = String(text.dropFirst(wakeWord.count))
            stripped = stripped.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            return stripped
        }
        return text
    }
}
