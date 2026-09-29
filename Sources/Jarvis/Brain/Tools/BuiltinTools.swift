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
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return ObservationResult.unavailable(reason: "Cannot observe system application state (no frontmost application)")
        }
        let frontmost = frontApp.localizedName ?? "none"
        let bundleId = frontApp.bundleIdentifier ?? ""
        return ObservationResult(
            observations: ["frontmostApp": frontmost, "bundleId": bundleId],
            isAvailable: true
        )
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("App launch failed during execution", expected: expected.metadata["targetApp"], observed: "execution failure")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "Cannot observe system application state", expected: expected.metadata["targetApp"], observed: "unavailable")
        }
        guard let targetApp = expected.metadata["targetApp"], !targetApp.isEmpty else {
            return .inconclusive("No target application specified for verification", expected: nil, observed: observed.observations["frontmostApp"])
        }
        guard let frontmost = observed.observations["frontmostApp"], !frontmost.isEmpty, frontmost != "none" else {
            return .failed("No frontmost application detected after launch", expected: targetApp, observed: "none")
        }

        let targetLower = targetApp.lowercased()
        let frontmostLower = frontmost.lowercased()
        if frontmostLower == targetLower || frontmostLower.contains(targetLower) || targetLower.contains(frontmostLower) {
            return .passed(
                reason: "Observed frontmost application matches target application",
                expected: targetApp,
                observed: frontmost
            )
        } else {
            return .failed(
                "Expected frontmost application '\(targetApp)', but observed '\(frontmost)'",
                expected: targetApp,
                observed: frontmost
            )
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
            return .failed("Volume adjustment failed during execution", expected: expected.metadata["targetLevel"], observed: "execution failure")
        }
        guard observed.isAvailable else {
            return .unavailable("Cannot observe system volume", expected: expected.metadata["targetLevel"], observed: "unavailable")
        }
        guard let volStr = observed.observations["volume"], let vol = Int(volStr) else {
            return .failed("Observed volume is missing or invalid", expected: expected.metadata["targetLevel"], observed: observed.observations["volume"])
        }
        if let targetLevelStr = expected.metadata["targetLevel"], let targetLevel = Int(targetLevelStr) {
            if abs(vol - targetLevel) <= 2 {
                return .passed(
                    reason: "Observed volume satisfies expected volume level within tolerance",
                    expected: "\(targetLevel)%",
                    observed: "\(vol)%"
                )
            } else {
                return .failed(
                    "Expected volume \(targetLevel)%, but observed \(vol)%",
                    expected: "\(targetLevel)%",
                    observed: "\(vol)%"
                )
            }
        }
        return .passed(expected: "valid volume", observed: "\(vol)%")
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
        ToolParameterSpec(name: "expected_file_non_empty", kind: .string, required: false, description: "Optional assertion that expected file has non-zero size ('true')"),
        ToolParameterSpec(name: "expected_file_contains", kind: .string, required: false, description: "Optional text the expected_file must contain (requires expected_file)"),
        ToolParameterSpec(name: "expected_directory", kind: .string, required: false, description: "Optional directory path expected to exist after command execution")
    ]

    private static let lastExpectedPath = LockedValue<String?>("")

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let command = arguments["command"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'command'")
        }

        var meta: [String: String] = ["command": command]
        if let expectedFile = arguments["expected_file"] as? String {
            meta["expectedFile"] = expectedFile
            Self.lastExpectedPath.value = expectedFile
        }
        if let expectedNonEmpty = arguments["expected_file_non_empty"] as? String {
            meta["expectedNonEmpty"] = expectedNonEmpty
        }
        if let expectedContains = arguments["expected_file_contains"] as? String {
            meta["expectedContains"] = expectedContains
        }
        if let expectedDir = arguments["expected_directory"] as? String {
            meta["expectedDirectory"] = expectedDir
            Self.lastExpectedPath.value = expectedDir
        }

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
        var obs: [String: String] = ["status": "completed"]
        if let path = Self.lastExpectedPath.value, !path.isEmpty {
            let fileState = FileSystemObserver.shared.observe(path: path)
            obs["targetPath"] = path
            obs["fileExists"] = String(fileState.exists)
            obs["isRegularFile"] = String(fileState.isRegularFile)
            obs["isDirectory"] = String(fileState.isDirectory)
            obs["fileSize"] = String(fileState.fileSize ?? 0)
        }
        return ObservationResult(observations: obs, isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            let code = expected.metadata["exitCode"] ?? "unknown"
            return .failed(
                "Shell process failed with exit code \(code)",
                expected: "exit code 0",
                observed: "exit code \(code)"
            )
        }
        guard observed.isAvailable else {
            return .unavailable(
                "Observation mechanism unavailable",
                expected: "process completion",
                observed: "unavailable"
            )
        }

        // Side-effect verification 1: expected_file existence and non-empty
        if let expectedFile = expected.metadata["expectedFile"], !expectedFile.isEmpty {
            let fileState = FileSystemObserver.shared.observe(path: expectedFile)
            if !fileState.exists {
                return .failed(
                    "Expected file does not exist after command: \(expectedFile)",
                    expected: "file exists at \(expectedFile)",
                    observed: "missing"
                )
            }
            if expected.metadata["expectedNonEmpty"] == "true" && (fileState.fileSize ?? 0) == 0 {
                return .failed(
                    "Expected file '\(expectedFile)' to be non-empty, but observed 0 bytes",
                    expected: "file size > 0",
                    observed: "0 bytes"
                )
            }
            // Content postcondition: declared text must be present in the file.
            if let needle = expected.metadata["expectedContains"], !needle.isEmpty {
                if !FileSystemObserver.shared.fileContains(path: expectedFile, substring: needle) {
                    return .failed(
                        "Expected file '\(expectedFile)' to contain '\(needle)', but content does not match",
                        expected: "file contains '\(needle)'",
                        observed: "content mismatch"
                    )
                }
            }
            return .passed(
                reason: "Expected file verified on disk: \(expectedFile)",
                expected: "file exists (\(expectedFile))",
                observed: "present (\(fileState.fileSize ?? 0) bytes)"
            )
        }

        // Side-effect verification 2: expected_directory existence
        if let expectedDir = expected.metadata["expectedDirectory"], !expectedDir.isEmpty {
            let dirState = FileSystemObserver.shared.observe(path: expectedDir)
            if !dirState.isDirectory {
                return .failed(
                    "Expected directory does not exist after command: \(expectedDir)",
                    expected: "directory at \(expectedDir)",
                    observed: dirState.exists ? "not a directory" : "missing"
                )
            }
            return .passed(
                reason: "Expected directory verified on disk: \(expectedDir)",
                expected: "directory at \(expectedDir)",
                observed: "present"
            )
        }

        return .passed(
            reason: "Shell command executed and exited with status 0",
            expected: "exit code 0",
            observed: "exit code 0"
        )
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
            sideEffects: ["browser_opened"]
        )
    }

    func observe() async throws -> ObservationResult {
        return ObservationResult(observations: ["browser": "opened"])
    }
}
