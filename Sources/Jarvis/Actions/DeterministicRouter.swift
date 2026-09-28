import Foundation

/// Matches incoming spoken or typed transcripts to deterministic actions in 0ms without invoking an LLM.
@MainActor
final class DeterministicRouter {
    static let shared = DeterministicRouter()

    struct Match: Sendable {
        let intent: String
        let parameters: [String: String]
        /// Declared impact of the action this match will perform. Enforced by
        /// ActionEngine via PermissionGate so deterministic actions obey the
        /// same authority policy as planned tools — no path bypasses the gate.
        /// Declared explicitly at every construction site; never inferred.
        let impact: PermissionGate.ActionImpact
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
        var lower = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        while let last = lower.last, ".?!".contains(last) {
            lower = String(lower.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // Strip leading wake word/alias if present ("hey zia, open safari" -> "open safari")
        let cleaned = stripWakeWord(from: lower)

        // For multi-action/compound requests, conservatively fall through to intelligence/planner.
        // The ONLY deterministic commands allowed to contain conjunctions are speech synthesis ("say ...")
        // and verbatim clipboard writing ("copy ... to the clipboard").
        let isCompound = isCompoundCommand(cleaned)

        // 1. Folders: "open downloads", "show my desktop", "open this folder"
        if !isCompound, let folder = matchFolderCommand(cleaned) { return folder }

        // 1b. Folder listing: "list downloads", "list files in desktop"
        if !isCompound, let fileList = matchFileListCommand(cleaned) { return fileList }

        // 2. App control: "open safari", "switch to terminal", "quit mail", "bring safari to front"
        if !isCompound, let app = matchAppCommand(cleaned) { return app }

        // 3. Volume control: "set volume to 50", "volume up", "mute"
        if !isCompound, let vol = matchVolumeCommand(cleaned) { return vol }

        // 3b. Brightness control: "set brightness to 50", "brightness up"
        if !isCompound, let bright = matchBrightnessCommand(cleaned) { return bright }

        // 3c. Screenshot: "take a screenshot", "capture screen"
        if !isCompound, let screen = matchScreenshotCommand(cleaned) { return screen }

        // 4. Time & Date: "what time is it", "what's today's date"
        if !isCompound, let timeDate = matchTimeDateQuery(cleaned) { return timeDate }

        // 5. System State: "what's my battery", "am i connected to wi-fi"
        if !isCompound, let state = matchSystemStateQuery(cleaned) { return state }

        // 6. System controls: "lock screen", "sleep mac", "empty trash"
        if !isCompound, let sys = matchSystemCommand(cleaned) { return sys }

        // 7. Clipboard: "read clipboard", "clear clipboard"
        if !isCompound, let clip = matchClipboardCommand(cleaned) { return clip }

        // 8. System Status: "memory status", "system status"
        if !isCompound, let status = matchStatusCommand(cleaned) { return status }

        // 9. Clipboard write: "copy hello world to the clipboard" (Phase D.5)
        if let clipWrite = matchClipboardWrite(cleaned) { return clipWrite }

        // 10. Text to speech: "say good morning" (Phase D.5)
        if let say = matchSayCommand(cleaned) { return say }

        // 11. Safe single echo passthrough: "echo hello" / "run echo hello"
        //    (Phase D.5) — the router-level subset of run_shell.
        if !isCompound, let echo = matchEchoCommand(cleaned) { return echo }

        return nil
    }

    // MARK: - Phase D.5 matchers

    /// "copy <text> to the clipboard" — unambiguous write intent with read-back verification.
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
                impact: .safeMutation,
                action: {
                    let success = await MainActor.run {
                        ClipboardManager.shared.setClipboardText(body)
                        return ClipboardManager.shared.getClipboardText() == body
                    }
                    if success {
                        return "Copied to clipboard (verified)."
                    } else {
                        return "Copied to clipboard."
                    }
                }
            )
        }

        // Direct "copy this ..." or "copy this: ..."
        if text.hasPrefix("copy this ") || text.hasPrefix("copy this: ") {
            let prefix = text.hasPrefix("copy this: ") ? "copy this: " : "copy this "
            let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty {
                return Match(
                    intent: "clipboard.write",
                    parameters: ["text": body],
                    impact: .safeMutation,
                    action: {
                        let success = await MainActor.run {
                            ClipboardManager.shared.setClipboardText(body)
                            return ClipboardManager.shared.getClipboardText() == body
                        }
                        if success {
                            return "Copied to clipboard (verified)."
                        } else {
                            return "Copied to clipboard."
                        }
                    }
                )
            }
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
            impact: .readOnly,
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
        // Conservative-routing guard: a compound/sequential echo body is NOT an
        // unambiguous single action ("echo a, then b", "echo a and then b",
        // "echo a, b, c"). The fast path must never swallow a multi-step request
        // merely because it can mechanically parse the leading words — fall
        // through to the planner instead. When uncertain: return nil.
        // (Chain operators ; & | are already rejected by the forbidden set.)
        let compoundMarkers = [",", " then ", " and ", " also "]
        if compoundMarkers.contains(where: { echoText.contains($0) }) {
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
            impact: .safeMutation,
            action: {
                let output = try await ShellExecutor.shared.execute(command)
                return output.stdout.isEmpty ? output.stderr : output.stdout
            }
        )
    }

    // MARK: - Matchers

    /// Safe directory navigation in Finder: Downloads, Desktop, Documents, Current workspace.
    private func matchFolderCommand(_ text: String) -> Match? {
        let downloadsQueries = ["open downloads", "open my downloads", "show downloads", "show my downloads"]
        if downloadsQueries.contains(text) {
            return Match(
                intent: "folder.open",
                parameters: ["folder": "Downloads"],
                impact: .safeMutation,
                action: {
                    let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ??
                              URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath)
                    return try await MainActor.run {
                        try SystemControl.shared.openFolder(url: url, displayName: "Downloads")
                    }
                }
            )
        }

        let desktopQueries = ["show my desktop", "show desktop", "open desktop", "open my desktop"]
        if desktopQueries.contains(text) {
            return Match(
                intent: "folder.open",
                parameters: ["folder": "Desktop"],
                impact: .safeMutation,
                action: {
                    let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ??
                              URL(fileURLWithPath: ("~/Desktop" as NSString).expandingTildeInPath)
                    return try await MainActor.run {
                        try SystemControl.shared.openFolder(url: url, displayName: "Desktop")
                    }
                }
            )
        }

        let documentsQueries = ["open documents", "open my documents", "show documents", "show my documents"]
        if documentsQueries.contains(text) {
            return Match(
                intent: "folder.open",
                parameters: ["folder": "Documents"],
                impact: .safeMutation,
                action: {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
                              URL(fileURLWithPath: ("~/Documents" as NSString).expandingTildeInPath)
                    return try await MainActor.run {
                        try SystemControl.shared.openFolder(url: url, displayName: "Documents")
                    }
                }
            )
        }

        let currentFolderQueries = ["open this folder", "open current folder", "show this folder", "open workspace"]
        if currentFolderQueries.contains(text) {
            return Match(
                intent: "folder.open",
                parameters: ["folder": "Current"],
                impact: .safeMutation,
                action: {
                    let currentPath = FileManager.default.currentDirectoryPath
                    let url = URL(fileURLWithPath: currentPath)
                    return try await MainActor.run {
                        try SystemControl.shared.openFolder(url: url, displayName: "Current Folder")
                    }
                }
            )
        }

        return nil
    }

    private func matchAppCommand(_ text: String) -> Match? {
        // Multi-action/compound rejection: compound utterances must fall through to planner intelligence
        if text.contains(" and ") || text.contains(" then ") || text.contains(" & ") || text.contains(";") || text.contains(" also ") {
            return nil
        }

        // Switch to / Bring to foreground / Focus
        if text.hasPrefix("switch to ") {
            let appName = String(text.dropFirst("switch to ".count)).trimmingCharacters(in: .punctuationCharacters)
            guard !appName.isEmpty, AppLauncher.shared.canResolve(appName) else { return nil }
            return Match(
                intent: "app.switch",
                parameters: ["app": appName],
                impact: .safeMutation,
                action: { try await AppLauncher.shared.switchTo(appName) }
            )
        }

        let foregroundPrefixes = ["bring ", "focus ", "foreground "]
        for prefix in foregroundPrefixes {
            if text.hasPrefix(prefix) {
                var appName = String(text.dropFirst(prefix.count))
                let suffixes = [" to foreground", " to front", " to the foreground", " to the front"]
                for suffix in suffixes {
                    if appName.hasSuffix(suffix) {
                        appName = String(appName.dropLast(suffix.count))
                    }
                }
                let targetApp = appName.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                guard !targetApp.isEmpty, AppLauncher.shared.canResolve(targetApp) else { continue }
                return Match(
                    intent: "app.switch",
                    parameters: ["app": targetApp],
                    impact: .safeMutation,
                    action: { try await AppLauncher.shared.switchTo(targetApp) }
                )
            }
        }

        // Launch / Open
        let openPrefixes = ["open ", "launch ", "start "]
        for prefix in openPrefixes {
            if text.hasPrefix(prefix) {
                let appName = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .punctuationCharacters)
                guard !appName.isEmpty, AppLauncher.shared.canResolve(appName) else { continue }
                return Match(
                    intent: "app.open",
                    parameters: ["app": appName],
                    impact: .safeMutation,
                    action: { try await AppLauncher.shared.open(appName) }
                )
            }
        }

        // Close / Quit
        let closePrefixes = ["close ", "quit ", "kill ", "exit "]
        for prefix in closePrefixes {
            if text.hasPrefix(prefix) {
                let appName = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .punctuationCharacters)
                guard !appName.isEmpty, AppLauncher.shared.canResolve(appName) else { continue }
                return Match(
                    intent: "app.quit",
                    parameters: ["app": appName],
                    impact: .safeMutation,
                    action: { try await AppLauncher.shared.quit(appName) }
                )
            }
        }

        return nil
    }

    /// Real-time hardware queries: battery status and Wi-Fi state.
    private func matchSystemStateQuery(_ text: String) -> Match? {
        let batteryQueries = [
            "what's my battery",
            "what is my battery",
            "what is my battery level",
            "what's my battery level",
            "battery level",
            "battery status",
            "check battery",
            "how is my battery",
            "what's the battery"
        ]
        if batteryQueries.contains(text) {
            return Match(
                intent: "system.battery",
                parameters: [:],
                impact: .readOnly,
                action: {
                    await MainActor.run { SystemControl.shared.getBatteryStatus() }
                }
            )
        }

        let wifiQueries = [
            "am i connected to wi-fi",
            "am i connected to wifi",
            "are we connected to wi-fi",
            "are we connected to wifi",
            "is wi-fi connected",
            "is wifi connected",
            "what's my wi-fi status",
            "what's my wifi status",
            "wi-fi status",
            "wifi status",
            "check wi-fi",
            "check wifi",
            "am i on wi-fi",
            "am i on wifi"
        ]
        if wifiQueries.contains(text) {
            return Match(
                intent: "system.wifi",
                parameters: [:],
                impact: .readOnly,
                action: {
                    await MainActor.run { SystemControl.shared.getWiFiStatus() }
                }
            )
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
                    impact: .safeMutation,
                    action: { try await MainActor.run { try SystemControl.shared.setVolume(level) } }
                )
            }
        }

        // Relative volume: "volume up", "increase volume", "louder"
        if text == "volume up" || text == "increase volume" || text == "turn it up" || text == "louder" {
            return Match(
                intent: "system.volume.up",
                parameters: [:],
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.volumeUp() } }
            )
        }

        // Relative volume: "volume down", "decrease volume", "quieter"
        if text == "volume down" || text == "decrease volume" || text == "turn it down" || text == "quieter" {
            return Match(
                intent: "system.volume.down",
                parameters: [:],
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.volumeDown() } }
            )
        }

        // Mute / Unmute
        if text == "mute" || text == "mute audio" || text == "mute volume" || text == "silence" {
            return Match(
                intent: "system.volume.mute",
                parameters: [:],
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.mute() } }
            )
        }

        if text == "unmute" || text == "unmute audio" || text == "unmute volume" {
            return Match(
                intent: "system.volume.unmute",
                parameters: [:],
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.unmute() } }
            )
        }

        // Volume status / query
        if text == "what is the volume" || text == "what's the volume" || text == "current volume" || text == "volume status" || text == "check volume" {
            return Match(
                intent: "system.volume.get",
                parameters: [:],
                impact: .readOnly,
                action: {
                    await MainActor.run {
                        let vol = SystemControl.shared.getVolume()
                        let muted = SystemControl.shared.isMuted()
                        return "Current volume is \(vol)%\(muted ? " (muted)" : "")."
                    }
                }
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
                impact: .readOnly,
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
                impact: .readOnly,
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
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.lockScreen() } }
            )
        }

        // Sleep Mac: Destructive (requires L2 or Preview/Commit)
        if text == "sleep mac" || text == "put mac to sleep" || text == "system sleep" || text == "put computer to sleep" ||
           text == "preview sleep" || text == "preview sleep mac" {
            let isExplicitPreview = text.hasPrefix("preview")
            return Match(
                intent: isExplicitPreview ? "system.sleep.preview" : "system.sleep",
                parameters: [:],
                impact: isExplicitPreview ? .safeMutation : .destructive,
                action: {
                    await MainActor.run {
                        DestructiveActionManager.shared.requestPreview(
                            intent: "system.sleep",
                            description: "Putting Mac to sleep will suspend running background tasks and network connections."
                        ) {
                            try await SystemControl.shared.sleepMac(dryRun: true)
                        }
                    }
                }
            )
        }

        if text == "confirm sleep" || text == "commit sleep" || text == "confirm system sleep" {
            return Match(
                intent: "system.sleep.commit",
                parameters: [:],
                impact: .destructive,
                action: {
                    try await DestructiveActionManager.shared.commit(intent: "system.sleep")
                }
            )
        }

        // Empty Trash: Destructive (requires L2 or Preview/Commit)
        if text == "empty trash" || text == "empty the trash" || text == "preview empty trash" {
            let isExplicitPreview = text.hasPrefix("preview")
            return Match(
                intent: isExplicitPreview ? "system.emptyTrash.preview" : "system.emptyTrash",
                parameters: [:],
                impact: isExplicitPreview ? .safeMutation : .destructive,
                action: {
                    await MainActor.run {
                        DestructiveActionManager.shared.requestPreview(
                            intent: "system.emptyTrash",
                            description: "Emptying the Trash permanently deletes all items in the Trash."
                        ) {
                            try await SystemControl.shared.emptyTrash()
                        }
                    }
                }
            )
        }

        if text == "confirm empty trash" || text == "commit empty trash" || text == "confirm empty the trash" {
            return Match(
                intent: "system.emptyTrash.commit",
                parameters: [:],
                impact: .destructive,
                action: {
                    try await DestructiveActionManager.shared.commit(intent: "system.emptyTrash")
                }
            )
        }

        if text == "confirm" || text == "commit" || text == "confirm action" || text == "commit action" {
            guard let pending = DestructiveActionManager.shared.pendingAction else {
                return nil
            }
            return Match(
                intent: "\(pending.intent).commit",
                parameters: [:],
                impact: .destructive,
                action: {
                    try await DestructiveActionManager.shared.commit()
                }
            )
        }

        if text == "cancel pending action" || text == "cancel action" || text == "abort action" || text == "cancel" || text == "abort" {
            return Match(
                intent: "system.action.cancel",
                parameters: [:],
                impact: .readOnly,
                action: {
                    await MainActor.run { DestructiveActionManager.shared.cancel() }
                }
            )
        }

        return nil
    }

    private func matchClipboardCommand(_ text: String) -> Match? {
        if text == "read clipboard" || text == "what's on my clipboard" || text == "what is on my clipboard" || text == "clipboard content" {
            return Match(
                intent: "clipboard.read",
                parameters: [:],
                impact: .readOnly,
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
                impact: .safeMutation,
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
                impact: .readOnly,
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
                impact: .readOnly,
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

    // MARK: - File Listing Matcher

    private func matchFileListCommand(_ text: String) -> Match? {
        if text == "list downloads" || text == "list files in downloads" || text == "what's in downloads" || text == "what is in downloads" || text == "show files in downloads" {
            return Match(
                intent: "folder.list",
                parameters: ["folder": "Downloads"],
                impact: .readOnly,
                action: {
                    let files = try await MainActor.run { try FileManagerJarvis.shared.getDownloadsFiles() }
                    let sample = files.prefix(10).joined(separator: ", ")
                    return "Downloads contains \(files.count) items: \(sample)"
                }
            )
        }

        if text == "list desktop" || text == "list files in desktop" || text == "what's on my desktop" || text == "what is on my desktop" || text == "show files in desktop" {
            return Match(
                intent: "folder.list",
                parameters: ["folder": "Desktop"],
                impact: .readOnly,
                action: {
                    let files = try await MainActor.run { try FileManagerJarvis.shared.getDesktopFiles() }
                    let sample = files.prefix(10).joined(separator: ", ")
                    return "Desktop contains \(files.count) items: \(sample)"
                }
            )
        }

        if text == "list documents" || text == "list files in documents" || text == "what's in documents" || text == "what is in documents" {
            return Match(
                intent: "folder.list",
                parameters: ["folder": "Documents"],
                impact: .readOnly,
                action: {
                    let files = try await MainActor.run { try FileManagerJarvis.shared.listDirectory(at: "~/Documents") }
                    let sample = files.prefix(10).joined(separator: ", ")
                    return "Documents contains \(files.count) items: \(sample)"
                }
            )
        }

        if text == "list current folder" || text == "list this folder" || text == "list workspace" || text == "list files in current folder" {
            return Match(
                intent: "folder.list",
                parameters: ["folder": "Current"],
                impact: .readOnly,
                action: {
                    let files = try await MainActor.run { try FileManagerJarvis.shared.listDirectory(at: FileManager.default.currentDirectoryPath) }
                    let sample = files.prefix(10).joined(separator: ", ")
                    return "Current directory contains \(files.count) items: \(sample)"
                }
            )
        }

        return nil
    }

    // MARK: - Display Brightness Matcher

    private func matchBrightnessCommand(_ text: String) -> Match? {
        // Specific brightness level: "set brightness to 50", "set brightness 50", "brightness 50%"
        if text.hasPrefix("set brightness to ") || text.hasPrefix("set brightness ") ||
           text.hasPrefix("set screen brightness to ") || text.hasPrefix("set screen brightness ") ||
           text.hasPrefix("brightness ") || text.hasPrefix("screen brightness ") {
            let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let level = Int(digits), level >= 0 && level <= 100 {
                return Match(
                    intent: "system.brightness.set",
                    parameters: ["level": String(level)],
                    impact: .safeMutation,
                    action: { try await MainActor.run { try SystemControl.shared.setBrightness(level) } }
                )
            }
        }

        // Relative brightness up
        if text == "brightness up" || text == "increase brightness" || text == "screen brightness up" ||
           text == "brighter" || text == "make screen brighter" {
            return Match(
                intent: "system.brightness.up",
                parameters: [:],
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.brightnessUp() } }
            )
        }

        // Relative brightness down
        if text == "brightness down" || text == "decrease brightness" || text == "screen brightness down" ||
           text == "dimmer" || text == "dim screen" || text == "dim the screen" || text == "make screen dimmer" {
            return Match(
                intent: "system.brightness.down",
                parameters: [:],
                impact: .safeMutation,
                action: { try await MainActor.run { try SystemControl.shared.brightnessDown() } }
            )
        }

        // Query brightness
        let brightnessQueries = [
            "what is the brightness",
            "what's the brightness",
            "what is screen brightness",
            "what's screen brightness",
            "current brightness",
            "check brightness",
            "brightness status"
        ]
        if brightnessQueries.contains(text) {
            return Match(
                intent: "system.brightness.get",
                parameters: [:],
                impact: .readOnly,
                action: {
                    let b = await MainActor.run { SystemControl.shared.getBrightness() }
                    return "The screen brightness is \(b)%."
                }
            )
        }

        return nil
    }

    // MARK: - Screenshot Matcher

    private func matchScreenshotCommand(_ text: String) -> Match? {
        let screenshotQueries = [
            "take a screenshot",
            "take screenshot",
            "capture screen",
            "capture the screen",
            "capture screenshot",
            "screenshot",
            "save screenshot"
        ]
        if screenshotQueries.contains(text) {
            return Match(
                intent: "system.screenshot",
                parameters: [:],
                impact: .readOnly,
                action: { try await MainActor.run { try SystemControl.shared.takeScreenshot() } }
            )
        }
        return nil
    }

    // MARK: - Private Helper

    private func stripWakeWord(from text: String) -> String {
        if let match = WakeWordDetector.findWakeMatch(in: text) {
            return match.strippedCommand
        }
        return text
    }

    /// Rejects compound or multi-action utterances so they fall through to intelligence.
    private func isCompoundCommand(_ text: String) -> Bool {
        return text.contains(" and ") ||
               text.contains(" then ") ||
               text.contains(" & ") ||
               text.contains(";") ||
               text.contains(" also ")
    }
}
