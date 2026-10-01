import Foundation

public struct DeterministicRouteResult: Sendable {
    public let actionName: String
    public let parameters: [String: String]
    public let confidence: Double

    public init(actionName: String, parameters: [String: String] = [:], confidence: Double = 1.0) {
        self.actionName = actionName
        self.parameters = parameters
        self.confidence = confidence
    }
}

struct DeterministicMatch: Sendable {
    let intent: String
    let parameters: [String: String]
    let impact: PermissionGate.ActionImpact
    let action: @Sendable () async throws -> String

    init(intent: String, parameters: [String: String] = [:], impact: PermissionGate.ActionImpact,
         action: @escaping @Sendable () async throws -> String) {
        self.intent = intent
        self.parameters = parameters
        self.impact = impact
        self.action = action
    }
}

public final class DeterministicRouter: @unchecked Sendable {
    public static let shared = DeterministicRouter()

    private struct RouteRule {
        let pattern: String
        let actionName: String
        let paramExtractor: (NSTextCheckingResult, String) -> [String: String]
    }

    private let rules: [RouteRule]
    private let exactMatches: [String: (String, [String: String])]

    public init() {
        let appLaunchRegex = "^(?:open|launch|start|run)\\s+(.+)$"
        let webSearchRegex = "^(?:search|google|find online)\\s+(?:for\\s+)?(.+)$"
        let volUpRegex = "^volume\\s+(?:up|increase)$"
        let volDownRegex = "^volume\\s+(?:down|decrease)$"
        let muteRegex = "^(?:mute|silence)$"

        self.rules = [
            RouteRule(
                pattern: appLaunchRegex,
                actionName: "system.openApp",
                paramExtractor: { match, input in
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) {
                        return ["appName": String(input[range])]
                    }
                    return [:]
                }
            ),
            RouteRule(
                pattern: volUpRegex,
                actionName: "system.volumeUp",
                paramExtractor: { _, _ in [:] }
            ),
            RouteRule(
                pattern: volDownRegex,
                actionName: "system.volumeDown",
                paramExtractor: { _, _ in [:] }
            ),
            RouteRule(
                pattern: muteRegex,
                actionName: "system.mute",
                paramExtractor: { _, _ in [:] }
            ),
            RouteRule(
                pattern: webSearchRegex,
                actionName: "web.search",
                paramExtractor: { match, input in
                    if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) {
                        return ["query": String(input[range])]
                    }
                    return [:]
                }
            )
        ]

        self.exactMatches = [
            "mute": ("system.mute", [:]),
            "unmute": ("system.unmute", [:]),
            "lock": ("system.lockScreen", [:]),
            "sleep": ("system.sleep", [:]),
            "time": ("system.getTime", [:]),
            "date": ("system.getDate", [:])
        ]
    }

    public func route(_ query: String) -> DeterministicRouteResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()

        if let exact = exactMatches[lower] {
            return DeterministicRouteResult(actionName: exact.0, parameters: exact.1, confidence: 1.0)
        }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for rule in rules {
            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: trimmed, options: [], range: nsRange) {
                let params = rule.paramExtractor(match, trimmed)
                return DeterministicRouteResult(actionName: rule.actionName, parameters: params, confidence: 0.98)
            }
        }

        return nil
    }

    /// Compatibility adapter for voice callers: all effects still run through
    /// ActionEngine, which performs the permission check before invoking action.
    @MainActor
    func match(_ transcript: String) -> DeterministicMatch? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        while let last = text.last, ".?!".contains(last) { text.removeLast() }
        if let wake = WakeWordDetector.findWakeMatch(in: text) { text = wake.strippedCommand }
        let compound = [" and ", " then ", " & ", ";", " also "].contains(where: text.contains)
        let forbiddenDestructive = ["delete everything", "shut down", "shutdown", "rm -rf", "format the disk", "wipe the disk"]
        if forbiddenDestructive.contains(where: text.contains) { return nil }

        if !compound {
            if let folder = folderMatch(text) { return folder }
            if let list = folderListMatch(text) { return list }
            if let app = appMatch(text) { return app }
            if let volume = volumeMatch(text) { return volume }
            if let brightness = brightnessMatch(text) { return brightness }
            if let screenshot = screenshotMatch(text) { return screenshot }
            if let query = systemQueryMatch(text) { return query }
            if let timeDate = timeDateMatch(text) { return timeDate }
            if let system = systemCommandMatch(text) { return system }
            if let clipboard = clipboardMatch(text) { return clipboard }
            if let status = statusMatch(text) { return status }
        }
        if let clipboardWrite = clipboardWriteMatch(text) { return clipboardWrite }
        if let speech = speechMatch(text) { return speech }
        if !compound, let echo = echoMatch(text) { return echo }

        guard !compound else { return nil }
        guard let result = route(transcript) else { return nil }
        switch result.actionName {
        case "system.openApp":
            guard let app = result.parameters["appName"] else { return nil }
            return DeterministicMatch(intent: "app.open", parameters: result.parameters,
                                      impact: .safeMutation,
                                      action: { try await AppLauncher.shared.open(app) })
        case "system.volumeUp":
            return DeterministicMatch(intent: "system.volume.up", impact: .safeMutation, action: {
                try await MainActor.run {
                    let current = SystemControl.shared.getVolume()
                    return try SystemControl.shared.setVolume(min(100, current + 10))
                }
            })
        case "system.volumeDown":
            return DeterministicMatch(intent: "system.volume.down", impact: .safeMutation, action: {
                try await MainActor.run {
                    let current = SystemControl.shared.getVolume()
                    return try SystemControl.shared.setVolume(max(0, current - 10))
                }
            })
        case "system.mute":
            return DeterministicMatch(intent: "system.volume.mute", impact: .safeMutation,
                                      action: { try await MainActor.run { try SystemControl.shared.mute() } })
        case "system.unmute":
            return DeterministicMatch(intent: "system.volume.unmute", impact: .safeMutation,
                                      action: { try await MainActor.run { try SystemControl.shared.unmute() } })
        case "system.getTime":
            return DeterministicMatch(intent: "system.time", impact: .readOnly, action: {
                Date().formatted(date: .omitted, time: .shortened)
            })
        case "system.getDate":
            return DeterministicMatch(intent: "system.date", impact: .readOnly, action: {
                Date().formatted(date: .long, time: .omitted)
            })
        case "web.search":
            guard let query = result.parameters["query"] else { return nil }
            return DeterministicMatch(intent: "web.search", parameters: result.parameters,
                                      impact: .readOnly, action: {
                let results = try await WebSearch.shared.search(query: query)
                return results.map(\.title).joined(separator: "\n")
            })
        default:
            return nil
        }
    }

    private func folderMatch(_ text: String) -> DeterministicMatch? {
        let folders: [(Set<String>, String, FileManager.SearchPathDirectory)] = [
            (["open downloads", "open my downloads", "show downloads", "show my downloads"], "Downloads", .downloadsDirectory),
            (["show my desktop", "show desktop", "open desktop", "open my desktop"], "Desktop", .desktopDirectory),
            (["open documents", "open my documents", "show documents", "show my documents"], "Documents", .documentDirectory)
        ]
        for (phrases, name, directory) in folders where phrases.contains(text) {
            let url = FileManager.default.urls(for: directory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: ("~/\(name)" as NSString).expandingTildeInPath)
            return DeterministicMatch(intent: "folder.open", parameters: ["folder": name], impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.openFolder(url: url, displayName: name) }
            }
        }
        if ["open this folder", "open current folder", "show this folder", "open workspace"].contains(text) {
            let path = FileManager.default.currentDirectoryPath
            return DeterministicMatch(intent: "folder.open", parameters: ["folder": "Current"], impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.openFolder(url: URL(fileURLWithPath: path), displayName: "Current Folder") }
            }
        }
        return nil
    }

    private func folderListMatch(_ text: String) -> DeterministicMatch? {
        let target: String?
        if ["list downloads", "list files in downloads", "what's in downloads", "what is in downloads", "show files in downloads"].contains(text) { target = "Downloads" }
        else if ["list desktop", "list files in desktop", "what's on my desktop", "what is on my desktop", "show files in desktop"].contains(text) { target = "Desktop" }
        else if ["list documents", "list files in documents", "what's in documents", "what is in documents"].contains(text) { target = "Documents" }
        else if ["list current folder", "list this folder", "list workspace", "list files in current folder"].contains(text) { target = "Current" }
        else { target = nil }
        guard let target else { return nil }
        return DeterministicMatch(intent: "folder.list", parameters: ["folder": target], impact: .readOnly) {
            let files = try await MainActor.run { () throws -> [String] in
                switch target {
                case "Downloads": return try FileManagerJarvis.shared.getDownloadsFiles()
                case "Desktop": return try FileManagerJarvis.shared.getDesktopFiles()
                case "Documents": return try FileManagerJarvis.shared.listDirectory(at: "~/Documents")
                default: return try FileManagerJarvis.shared.listDirectory(at: FileManager.default.currentDirectoryPath)
                }
            }
            return "\(target) contains \(files.count) items: \(files.prefix(10).joined(separator: ", "))"
        }
    }

    private func appMatch(_ text: String) -> DeterministicMatch? {
        for (prefix, intent, operation) in [("switch to ", "app.switch", 1), ("bring ", "app.switch", 1),
                                             ("focus ", "app.switch", 1), ("foreground ", "app.switch", 1),
                                             ("open ", "app.open", 0), ("launch ", "app.open", 0), ("start ", "app.open", 0),
                                             ("quit ", "app.quit", 2), ("close ", "app.quit", 2), ("kill ", "app.quit", 2)] {
            guard text.hasPrefix(prefix) else { continue }
            var app = String(text.dropFirst(prefix.count))
            if operation == 1 {
                for suffix in [" to foreground", " to front", " to the foreground", " to the front"] where app.hasSuffix(suffix) {
                    app = String(app.dropLast(suffix.count))
                }
            }
            app = app.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard !app.isEmpty else { return nil }
            let target = app
            return DeterministicMatch(intent: intent, parameters: ["app": target], impact: .safeMutation) {
                switch operation {
                case 1: return try await AppLauncher.shared.switchTo(target)
                case 2: return try await AppLauncher.shared.quit(target)
                default: return try await AppLauncher.shared.open(target)
                }
            }
        }
        return nil
    }

    private func volumeMatch(_ text: String) -> DeterministicMatch? {
        if text.hasPrefix("set volume to ") || text.hasPrefix("set volume ") || text.hasPrefix("volume ") {
            let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let level = Int(digits), (0...100).contains(level) {
                return DeterministicMatch(intent: "system.volume.set", parameters: ["level": String(level)], impact: .safeMutation) {
                    try await MainActor.run { try SystemControl.shared.setVolume(level) }
                }
            }
        }
        if ["volume up", "increase volume", "turn it up", "louder"].contains(text) {
            return DeterministicMatch(intent: "system.volume.up", impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.volumeUp() }
            }
        }
        if ["volume down", "decrease volume", "turn it down", "quieter"].contains(text) {
            return DeterministicMatch(intent: "system.volume.down", impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.volumeDown() }
            }
        }
        if ["mute", "mute audio", "mute volume", "silence"].contains(text) {
            return DeterministicMatch(intent: "system.volume.mute", impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.mute() }
            }
        }
        if ["unmute", "unmute audio", "unmute volume"].contains(text) {
            return DeterministicMatch(intent: "system.volume.unmute", impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.unmute() }
            }
        }
        if ["what is the volume", "what's the volume", "current volume", "volume status", "check volume"].contains(text) {
            return DeterministicMatch(intent: "system.volume.get", impact: .readOnly) {
                await MainActor.run { "Current volume is \(SystemControl.shared.getVolume())%." }
            }
        }
        return nil
    }

    private func brightnessMatch(_ text: String) -> DeterministicMatch? {
        if ["brightness up", "increase brightness", "screen brightness up", "brighter", "make screen brighter"].contains(text) {
            return DeterministicMatch(intent: "system.brightness.up", impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.brightnessUp() }
            }
        }
        if ["brightness down", "decrease brightness", "screen brightness down", "dimmer", "dim screen", "dim the screen", "make screen dimmer"].contains(text) {
            return DeterministicMatch(intent: "system.brightness.down", impact: .safeMutation) {
                try await MainActor.run { try SystemControl.shared.brightnessDown() }
            }
        }
        if text.hasPrefix("set brightness") || text.hasPrefix("set screen brightness") || text.hasPrefix("brightness ") || text.hasPrefix("screen brightness ") {
            let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let level = Int(digits), (0...100).contains(level) {
                return DeterministicMatch(intent: "system.brightness.set", parameters: ["level": String(level)], impact: .safeMutation) {
                    try await MainActor.run { try SystemControl.shared.setBrightness(level) }
                }
            }
        }
        if ["what is the brightness", "what's the brightness", "what is screen brightness", "what's screen brightness", "current brightness", "check brightness", "brightness status"].contains(text) {
            return DeterministicMatch(intent: "system.brightness.get", impact: .readOnly) {
                await MainActor.run { "The screen brightness is \(SystemControl.shared.getBrightness())%." }
            }
        }
        return nil
    }

    private func screenshotMatch(_ text: String) -> DeterministicMatch? {
        guard ["take a screenshot", "take screenshot", "capture screen", "capture the screen", "capture screenshot", "screenshot", "save screenshot"].contains(text) else { return nil }
        return DeterministicMatch(intent: "system.screenshot", impact: .readOnly) {
            try await MainActor.run { try SystemControl.shared.takeScreenshot() }
        }
    }

    private func systemQueryMatch(_ text: String) -> DeterministicMatch? {
        let battery = ["what's my battery", "what is my battery", "what is my battery level", "what's my battery level", "battery level", "battery status", "check battery", "how is my battery", "what's the battery"]
        if battery.contains(text) {
            return DeterministicMatch(intent: "system.battery", impact: .readOnly) { await MainActor.run { SystemControl.shared.getBatteryStatus() } }
        }
        let wifi = ["am i connected to wi-fi", "am i connected to wifi", "are we connected to wi-fi", "are we connected to wifi", "is wi-fi connected", "is wifi connected", "what's my wi-fi status", "what's my wifi status", "wi-fi status", "wifi status", "check wi-fi", "check wifi", "am i on wi-fi", "am i on wifi"]
        if wifi.contains(text) {
            return DeterministicMatch(intent: "system.wifi", impact: .readOnly) { await MainActor.run { SystemControl.shared.getWiFiStatus() } }
        }
        return nil
    }

    private func timeDateMatch(_ text: String) -> DeterministicMatch? {
        if ["what time is it", "what's the time", "tell me the time", "current time", "what is the time", "time"].contains(text) {
            return DeterministicMatch(intent: "system.time", impact: .readOnly) {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                return "The time is \(formatter.string(from: Date()))."
            }
        }
        if ["what date is it", "what's the date", "what is the date", "what is today's date", "what day is it", "today's date", "date"].contains(text) {
            return DeterministicMatch(intent: "system.date", impact: .readOnly) {
                let formatter = DateFormatter()
                formatter.dateStyle = .full
                return "Today is \(formatter.string(from: Date()))."
            }
        }
        return nil
    }

    private func systemCommandMatch(_ text: String) -> DeterministicMatch? {
        if ["lock screen", "lock mac", "lock the screen", "lock my mac"].contains(text) {
            return DeterministicMatch(intent: "system.lock", impact: .safeMutation) { try await MainActor.run { try SystemControl.shared.lockScreen() } }
        }
        if ["empty trash", "empty the trash", "preview empty trash"].contains(text) {
            let preview = text.hasPrefix("preview")
            return DeterministicMatch(intent: preview ? "system.emptyTrash.preview" : "system.emptyTrash", impact: preview ? .safeMutation : .destructive) {
                DestructiveActionManager.shared.requestPreview(intent: "system.emptyTrash",
                    description: "Emptying the Trash permanently deletes all items in the Trash.") {
                        try await MainActor.run { try SystemControl.shared.emptyTrash() }
                }
            }
        }
        if ["sleep mac", "put mac to sleep", "system sleep", "put computer to sleep", "preview sleep", "preview sleep mac"].contains(text) {
            let preview = text.hasPrefix("preview")
            return DeterministicMatch(intent: preview ? "system.sleep.preview" : "system.sleep", impact: preview ? .safeMutation : .destructive) {
                DestructiveActionManager.shared.requestPreview(intent: "system.sleep",
                    description: "Putting Mac to sleep suspends running background tasks and network connections.") {
                        try await MainActor.run { try SystemControl.shared.sleepMac(dryRun: true) }
                }
            }
        }
        if ["confirm sleep", "commit sleep", "confirm system sleep"].contains(text) {
            return DeterministicMatch(intent: "system.sleep.commit", impact: .destructive) {
                try await DestructiveActionManager.shared.commit(intent: "system.sleep")
            }
        }
        if ["confirm empty trash", "commit empty trash", "confirm empty the trash"].contains(text) {
            return DeterministicMatch(intent: "system.emptyTrash.commit", impact: .destructive) {
                try await DestructiveActionManager.shared.commit(intent: "system.emptyTrash")
            }
        }
        if ["cancel pending action", "cancel action", "abort action", "cancel", "abort"].contains(text) {
            return DeterministicMatch(intent: "system.action.cancel", impact: .readOnly) {
                await MainActor.run { DestructiveActionManager.shared.cancel() }
                return "Pending action cancelled."
            }
        }
        return nil
    }

    private func clipboardMatch(_ text: String) -> DeterministicMatch? {
        if ["read clipboard", "what's on my clipboard", "what is on my clipboard", "clipboard content"].contains(text) {
            return DeterministicMatch(intent: "clipboard.read", impact: .readOnly) {
                await MainActor.run { ClipboardManager.shared.getClipboardText().map { "Clipboard contains: \($0)" } ?? "Clipboard is empty" }
            }
        }
        if ["clear clipboard", "empty clipboard"].contains(text) {
            return DeterministicMatch(intent: "clipboard.clear", impact: .safeMutation) {
                await MainActor.run { ClipboardManager.shared.clearClipboard() }
                return "Clipboard cleared"
            }
        }
        return nil
    }

    private func statusMatch(_ text: String) -> DeterministicMatch? {
        guard ["system status", "status", "diagnostics", "memory status", "ram status"].contains(text) else { return nil }
        return DeterministicMatch(intent: text.contains("memory") || text.contains("ram") ? "system.memory" : "system.status", impact: .readOnly) {
            await MainActor.run {
                let manager = ResourceManager.shared
                let online = AppState.shared.isOnline ? "online" : "offline"
                return "Memory \(manager.totalMemoryMB)MB (\(manager.currentPressure.rawValue) pressure); network \(online)."
            }
        }
    }

    private func clipboardWriteMatch(_ text: String) -> DeterministicMatch? {
        for prefix in ["copy ", "put "] {
            guard text.hasPrefix(prefix), let suffix = [" to the clipboard", " to clipboard", " on the clipboard", " in the clipboard"].first(where: text.hasSuffix) else { continue }
            let value = String(text.dropFirst(prefix.count).dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return DeterministicMatch(intent: "clipboard.write", parameters: ["text": value], impact: .safeMutation) {
                await MainActor.run { ClipboardManager.shared.setClipboardText(value) }
                return "Copied to clipboard."
            }
        }
        if text.hasPrefix("copy this: ") || text.hasPrefix("copy this ") {
            let prefix = text.hasPrefix("copy this: ") ? "copy this: " : "copy this "
            let value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return DeterministicMatch(intent: "clipboard.write", parameters: ["text": value], impact: .safeMutation) {
                await MainActor.run { ClipboardManager.shared.setClipboardText(value) }
                return "Copied to clipboard."
            }
        }
        return nil
    }

    private func speechMatch(_ text: String) -> DeterministicMatch? {
        let prefix = ["say ", "speak the text ", "speak "].first(where: text.hasPrefix)
        guard let prefix else { return nil }
        let value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return DeterministicMatch(intent: "speech.say", parameters: ["text": value], impact: .readOnly) {
            await MainActor.run { TTSEngine.shared.speak(value) }
            return value
        }
    }

    private func echoMatch(_ text: String) -> DeterministicMatch? {
        let prefix = ["run the command echo ", "run echo ", "echo "].first(where: text.hasPrefix)
        guard let prefix else { return nil }
        let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let forbidden = CharacterSet(charactersIn: "|&;$><`\\\"'\n\r")
        guard !body.isEmpty, !body.hasPrefix("-"),
              ![",", " then ", " and ", " also "].contains(where: body.contains),
              body.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let command = "echo \(body)"
        return DeterministicMatch(intent: "shell.echo", parameters: ["command": command], impact: .safeMutation) {
            guard await MainActor.run(body: { CommandSandbox.shared.isSafe(command) }) else {
                throw JarvisError.commandBlocked(command: command, reason: "Rejected by CommandSandbox")
            }
            let output = try await ShellExecutor.shared.execute(command)
            return output.stdout.isEmpty ? output.stderr : output.stdout
        }
    }
}