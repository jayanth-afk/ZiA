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
        return ToolResult(success: true, output: output, sideEffects: ["app_launched"])
    }

    func observe() async throws -> ObservationResult {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        return ObservationResult(observations: ["frontmostApp": frontmost])
    }

    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success
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
        return ToolResult(success: true, output: output, sideEffects: ["volume_changed"])
    }

    func observe() async throws -> ObservationResult {
        let currentVol = await SystemControl.shared.getVolume()
        return ObservationResult(observations: ["volume": String(currentVol)])
    }

    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success && (Int(observed.observations["volume"] ?? "") != nil)
    }
}

// MARK: - Run Shell Command Tool

struct RunShellTool: JarvisTool {
    let name = "run_shell"
    let description = "Executes a sandboxed shell command on macOS"
    let impact: PermissionGate.ActionImpact = .destructive
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "command", kind: .string, required: true, description: "Shell command to run; must pass the security sandbox")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let command = arguments["command"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'command'")
        }

        let output = try await ShellExecutor.shared.execute(command)
        let success = output.exitCode == 0
        let combined = output.stdout.isEmpty ? output.stderr : output.stdout
        return ToolResult(success: success, output: combined, sideEffects: ["process_executed"])
    }

    func observe() async throws -> ObservationResult {
        return ObservationResult(observations: ["status": "completed"])
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
