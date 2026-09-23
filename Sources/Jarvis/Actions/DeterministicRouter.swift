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
    ///
    /// Phase D.5: extended conservatively (STEP 2). Only unambiguous intents
    /// whose parameters can be extracted safely are matched — this is NOT a
    /// regex chatbot. Semantic/multi-step/ambiguous goals still go to the
    /// MLX planner. Latency is measured by the caller (AgentLoop/audit).
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

        // 7. Clipboard write: "copy hello world to the clipboard" (Phase D.5)
        if let clipWrite = matchClipboardWrite(cleaned) { return clipWrite }

        // 8. Text to speech: "say good morning" (Phase D.5)
        if let say = matchSayCommand(cleaned) { return say }

        // 9. Safe single echo passthrough: "echo hello" / "run echo hello"
        //    (Phase D.5) — the router-level subset of run_shell.
        if let echo = matchEchoCommand(cleaned) { return echo }

        return nil
    }

    // MARK: - Phase D.5 matchers

    /// "copy <text> to the clipboard" — unambiguous write intent. The copied
    /// text is preserved verbatim (only the fixed prefix/suffix is stripped).
    private func matchClipboardWrite(_ text: String) -> Match? {
        let prefixes = ["copy ", "put "]
        let suffixes = [" to the clipboard", " to clipboard", " on the clipboard", " in the clipboard"]
        for prefix in prefixes {
            guard text.hasPrefix(prefix) else { continue }
            var body = String(text.dropFirst(prefix.count))
            guard let suffix = suffixes.first(where: { body.hasSuffix($0) }) else { continue }
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            return Match(
                intent: "clipboard.write",
                parameters: ["text": body],
                action: {
                    await MainActor.run { ClipboardManager.shared.setClipboardText(body) }
                    return "Copied to clipboard."
                }
            )
        }
        return nil
    }

    /// "say <text>" / "speak the text <text>" — speak text aloud via TTS and
    /// return the spoken text as the response.
    private func matchSayCommand(_ text: String) -> Match? {
        var body: String?
        if text.hasPrefix("say ") {
            body = String(text.dropFirst("say ".count))
        } else if text.hasPrefix("speak the text ") {
            body = String(text.dropFirst("speak the text ".count))
        } else if text.hasPrefix("speak ") {
            body = String(text.dropFirst("speak ".count))
        }
        guard let textToSpeak = body?.trimmingCharacters(in: .whitespaces), !textToSpeak.isEmpty else {
            return nil
        }
        return Match(
            intent: "speech.say",
            parameters: ["text": textToSpeak],
            action: {
                await MainActor.run { TTSEngine.shared.speak(textToSpeak) }
                return textToSpeak
            }
        )
    }

    /// "echo <text>" / "run echo <text>" / "run the command echo <text>" —
    /// safe single echo with no shell metacharacters. Everything else goes to
    /// the planner. Wrapped in a quoted, sandbox-checked run_shell call so the
    /// existing permission + safety gates stay in the path.
    private func matchEchoCommand(_ text: String) -> Match? {
        var body: String?
        if text.hasPrefix("echo ") {
            body = String(text.dropFirst("echo ".count))
        } else if text.hasPrefix("run echo ") {
            body = String(text.dropFirst("run echo ".count))
        } else if text.hasPrefix("run the command echo ") {
            body = String(text.dropFirst("run the command echo ".count))
        }
        guard let echoText = body?.trimmingCharacters(in: .whitespaces), !echoText.isEmpty else {
            return nil
        }
        // Refuse anything beyond a plain single echo: no metacharacters, no
        // quotes, no flags. This keeps the deterministic subset strictly safe;
        // complex shell requests still go through the planner + full sandbox.
        let forbidden = CharacterSet(charactersIn: "|&;$><`\\\"'\n\r")
        guard echoText.unicodeScalars.allSatisfy({ !forbidden.contains($0) }), !echoText.hasPrefix("-") else {
            return nil
        }
        let command = "echo \(echoText)"
        guard CommandSandbox.shared.isSafe(command) else { return nil }
        return Match(
            intent: "shell.echo",
            parameters: ["command": command],
            action: {
                let output = try await ShellExecutor.shared.execute(command)
                return output.stdout.isEmpty ? output.stderr : output.stdout
            }
        )
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
