import Foundation

/// Central registry of all executable tools available to JARVIS and LLM providers.
@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: any JarvisTool] = [:]

    private init() {
        registerBuiltins()
    }

    // MARK: - Public API

    /// Register a tool.
    func register(_ tool: any JarvisTool) {
        tools[tool.name] = tool
        JarvisLogger.actions.debug("Registered tool: '\(tool.name)'")
    }

    /// Retrieve a tool by name.
    func getTool(named name: String) -> (any JarvisTool)? {
        return tools[name]
    }

    /// Returns all registered tools.
    var allTools: [any JarvisTool] {
        return Array(tools.values)
    }

    /// Generates ToolDefinitions formatted for LLM function calling schemas,
    /// including a real JSON schema built from each tool's declared parameters.
    func getToolDefinitions() -> [ToolDefinition] {
        return allTools.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                parametersJSON: Self.parametersJSON(for: tool)
            )
        }
    }

    /// Compact JSON schema of a tool's declared parameters.
    private nonisolated static func parametersJSON(for tool: any JarvisTool) -> String {
        var properties: [String] = []
        var required: [String] = []
        for spec in tool.parameterSpec {
            properties.append("\"\(spec.name)\":{\"type\":\"\(spec.kind.rawValue)\"}")
            if spec.required { required.append("\"\(spec.name)\"") }
        }
        let props = properties.joined(separator: ",")
        let req = required.joined(separator: ",")
        return "{\"type\":\"object\",\"properties\":{\(props)},\"required\":[\(req)]}"
    }

    // MARK: - Private

    private func registerBuiltins() {
        register(OpenAppTool())
        register(SetVolumeTool())
        register(RunShellTool())
        register(WriteFileTool())
        register(WebSearchTool())
        register(FetchURLTool())
        register(OpenBrowserTool())
        register(InspectUITool())
        register(ClickElementTool())
        register(SetTextTool())
    }
}
