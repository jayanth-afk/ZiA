import Foundation
import AppKit

// MARK: - Open Application Tool

struct OpenAppTool: JarvisTool {
    let name = "open_app"
    let description = "Opens or switches to a macOS application by name"
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "app_name", kind: .string, required: true, description: "Application name, e.g. Safari or Calculator")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let appName = arguments["app_name"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'app_name'")
        }

        let output = try await AppLauncher.shared.open(appName)
        return ToolResult(
            success: true,
            output: output,
            sideEffects: ["app_launched"],
            metadata: ["targetApp": appName]
        )
    }

    func observe() async throws -> ObservationResult {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        return ObservationResult(observations: ["frontmostApp": frontmost], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("App launch failed during execution")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "Cannot observe system application state")
        }
        guard let targetApp = expected.metadata["targetApp"], !targetApp.isEmpty else {
            return .inconclusive("No target application specified for verification")
        }
        guard let frontmost = observed.observations["frontmostApp"], !frontmost.isEmpty, frontmost != "none" else {
            return .failed("No frontmost application detected after launch")
        }

        let targetLower = targetApp.lowercased()
        let frontmostLower = frontmost.lowercased()
        if frontmostLower == targetLower || frontmostLower.contains(targetLower) || targetLower.contains(frontmostLower) {
            return .passed
        } else {
            return .failed("Expected frontmost application '\(targetApp)', but observed '\(frontmost)'")
        }
    }
}
// MARK: - Set Volume Tool

struct SetVolumeTool: JarvisTool {
    let name = "set_volume"
    let description = "Sets the system audio output volume (0-100%)"
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "level", kind: .int, required: true, description: "Volume level from 0 to 100")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let level = arguments["level"] as? Int else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'level'")
        }

        let output = try await SystemControl.shared.setVolume(level)
        return ToolResult(
            success: true,
            output: output,
            sideEffects: ["volume_changed"],
            metadata: ["targetLevel": String(level)]
        )
    }

    func observe() async throws -> ObservationResult {
        let currentVol = await SystemControl.shared.getVolume()
        return ObservationResult(observations: ["volume": String(currentVol)], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("Volume adjustment failed")
        }
        guard observed.isAvailable else {
            return .unavailable("Cannot observe system volume")
        }
        guard let volStr = observed.observations["volume"], let vol = Int(volStr) else {
            return .failed("Observed volume is missing or invalid")
        }
        if let targetLevelStr = expected.metadata["targetLevel"], let targetLevel = Int(targetLevelStr) {
            if abs(vol - targetLevel) <= 2 {
                return .passed
            } else {
                return .failed("Expected volume \(targetLevel)%, but observed \(vol)%")
            }
        }
        return .passed
    }
}

// MARK: - Run Shell Command Tool

struct RunShellTool: JarvisTool {
    let name = "run_shell"
    let description = "Executes a sandboxed shell command on macOS"
    let impact: PermissionGate.ActionImpact = .destructive
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "command", kind: .string, required: true, description: "Shell command to run; must pass the security sandbox"),
        ToolParameterSpec(name: "expected_file", kind: .string, required: false, description: "Optional file path expected to exist after command execution"),
        ToolParameterSpec(name: "expected_file_non_empty", kind: .string, required: false, description: "Require expected_file to have non-zero size"),
        ToolParameterSpec(name: "expected_directory", kind: .string, required: false, description: "Optional directory expected to exist after command execution")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let command = arguments["command"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'command'")
        }

        var meta: [String: String] = ["command": command]
        if let expectedFile = arguments["expected_file"] as? String {
            meta["expectedFile"] = expectedFile
        }
        if let nonEmpty = arguments["expected_file_non_empty"] as? String { meta["expectedFileNonEmpty"] = nonEmpty }
        if let directory = arguments["expected_directory"] as? String { meta["expectedDirectory"] = directory }

        let output = try await ShellExecutor.shared.execute(command)
        let success = output.exitCode == 0
        meta["exitCode"] = String(output.exitCode)
        let combined = output.stdout.isEmpty ? output.stderr : output.stdout
        return ToolResult(
            success: success,
            output: combined,
            sideEffects: ["process_executed"],
            metadata: meta
        )
    }

    func observe() async throws -> ObservationResult {
        return ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            let code = expected.metadata["exitCode"] ?? "unknown"
            return .failed("Shell process failed with exit code \(code)", expected: "exit code 0", observed: "exit code \(code)")
        }
        guard observed.isAvailable else {
            return .unavailable("Observation mechanism unavailable", expected: "filesystem observation", observed: "unavailable")
        }
        if let expectedFile = expected.metadata["expectedFile"], !expectedFile.isEmpty {
            let state = FileSystemObserver.shared.observe(path: expectedFile)
            guard state.exists && state.isRegularFile else {
                return .failed("Expected file does not exist after command: \(expectedFile)", expected: "regular file at \(expectedFile)", observed: state.exists ? "directory" : "missing")
            }
            if expected.metadata["expectedFileNonEmpty"] == "true", (state.fileSize ?? 0) == 0 {
                return .failed("Expected file '\(expectedFile)' to be non-empty", expected: "size > 0", observed: "0 bytes")
            }
            return .passed(reason: "Expected file observed on disk", expected: "regular file at \(expectedFile)", observed: "\(state.fileSize ?? 0) bytes")
        }
        if let expectedDirectory = expected.metadata["expectedDirectory"], !expectedDirectory.isEmpty {
            let state = FileSystemObserver.shared.observe(path: expectedDirectory)
            return state.isDirectory
                ? .passed(reason: "Expected directory observed on disk", expected: "directory at \(expectedDirectory)", observed: "directory")
                : .failed("Expected directory does not exist after command: \(expectedDirectory)", expected: "directory at \(expectedDirectory)", observed: state.exists ? "regular file" : "missing")
        }
        return .passed(reason: "Shell command exited successfully; no side-effect was declared", expected: "exit code 0", observed: "exit code 0")
    }
}

// MARK: - Web Search Tool

struct WebSearchTool: JarvisTool {
    let name = "web_search"
    let description = "Searches the web for up-to-date information, returning top results with URLs and snippets"
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "query", kind: .string, required: true, description: "Search query text"),
        ToolParameterSpec(name: "max_results", kind: .int, required: false, description: "Maximum number of results (default 5)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'query'")
        }

        let maxResults = (arguments["max_results"] as? Int) ?? 5
        let results = try await WebSearch.shared.search(query: query, maxResults: maxResults)

        // Record sources in SourceManager
        for item in results {
            if let url = URL(string: item.url) {
                SourceManager.shared.recordSource(
                    url: url,
                    title: item.title,
                    snippet: item.snippet,
                    query: query
                )
            }
        }

        let formatted = results.enumerated().map { index, r in
            "[\(index + 1)] \(r.title)\nURL: \(r.url)\nSnippet: \(r.snippet)"
        }.joined(separator: "\n\n")

        return ToolResult(
            success: !results.isEmpty,
            output: formatted.isEmpty ? "No results found for '\(query)'" : formatted,
            sideEffects: ["web_searched"]
        )
    }

    func observe() async throws -> ObservationResult {
        let sources = SourceManager.shared.allSources()
        return ObservationResult(observations: ["recordedSourcesCount": String(sources.count)])
    }
}

// MARK: - Fetch URL Tool

struct FetchURLTool: JarvisTool {
    let name = "fetch_url"
    let description = "Fetches web page content at a URL and extracts readable text and metadata"
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "url", kind: .string, required: true, description: "Absolute http(s) URL to fetch"),
        ToolParameterSpec(name: "max_characters", kind: .int, required: false, description: "Maximum characters of extracted text (default 8000)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let urlStr = arguments["url"] as? String,
              let url = URL(string: urlStr) else {
            throw JarvisError.actionFailed(action: name, reason: "Missing or invalid 'url'")
        }

        let maxChars = (arguments["max_characters"] as? Int) ?? 8_000
        let content = try await URLFetcher.shared.fetch(url: url, maxCharacters: maxChars)

        SourceManager.shared.recordSource(
            url: url,
            title: content.title,
            snippet: String(content.text.prefix(300))
        )

        let output = """
        Title: \(content.title)
        URL: \(content.url.absoluteString)
        Status: \(content.statusCode)
        Content Length: \(content.contentLength) bytes

        --- Content ---
        \(content.text)
        """

        return ToolResult(success: true, output: output, sideEffects: ["url_fetched"])
    }

    func observe() async throws -> ObservationResult {
        return ObservationResult(observations: ["fetchStatus": "completed"])
    }
}

// MARK: - Open Browser Tool

struct OpenBrowserTool: JarvisTool {
    let name = "open_browser"
    let description = "Opens a web URL in the system default browser or specific browser (Safari, Chrome)"
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "url", kind: .string, required: true, description: "Absolute http(s) URL to open"),
        ToolParameterSpec(name: "browser", kind: .string, required: false, description: "Browser name: Default, Safari, or Chrome")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let urlStr = arguments["url"] as? String,
              let url = URL(string: urlStr) else {
            throw JarvisError.actionFailed(action: name, reason: "Missing or invalid 'url'")
        }

        let browserName = arguments["browser"] as? String ?? "Default"
        let browserType = BrowserType(rawValue: browserName) ?? .defaultBrowser

        let opened = try await BrowserManager.shared.open(url: url, in: browserType)
        return ToolResult(
            success: opened,
            output: "Opened \(url.absoluteString) in \(browserType.rawValue)",
            sideEffects: ["browser_opened"],
            metadata: ["targetURL": url.absoluteString, "browser": browserType.rawValue]
        )
    }

    func observe() async throws -> ObservationResult {
        return .unavailable(reason: "Browser observation requires the execution metadata")
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let browserName = expected.metadata["browser"], let browser = BrowserType(rawValue: browserName) else {
            return .unavailable(reason: "Browser identity was not recorded")
        }
        guard browser == .safari || browser == .chrome else {
            return .unavailable(reason: "Active-tab observation is unavailable for \(browser.rawValue)")
        }
        guard let tab = try await BrowserManager.shared.getActiveTabInfo(browser: browser) else {
            return .unavailable(reason: "Could not observe an active \(browser.rawValue) tab")
        }
        return ObservationResult(observations: ["url": tab.url, "title": tab.title, "browser": browser.rawValue])
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("Browser navigation request failed", expected: expected.metadata["targetURL"], observed: "execution failure")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "Browser state is unavailable", expected: expected.metadata["targetURL"])
        }
        guard let target = expected.metadata["targetURL"], let actual = observed.observations["url"] else {
            return .inconclusive("Navigation URL evidence is incomplete")
        }
        // The browser may append a trailing slash for a bare origin; normalize only that harmless representation.
        let normalizedTarget = target.hasSuffix("/") ? String(target.dropLast()) : target
        let normalizedActual = actual.hasSuffix("/") ? String(actual.dropLast()) : actual
        return normalizedTarget == normalizedActual
            ? .passed(reason: "Observed active-tab URL matches navigation target", expected: target, observed: actual)
            : .failed("Observed active-tab URL differs from navigation target", expected: target, observed: actual)
    }
}
