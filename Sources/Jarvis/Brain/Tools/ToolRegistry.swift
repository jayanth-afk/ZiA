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

    /// Generates ToolDefinitions formatted for LLM function calling schemas.
    func getToolDefinitions() -> [ToolDefinition] {
        return allTools.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                parametersJSON: "{}" // Schema definitions
            )
        }
    }

    // MARK: - Private

    private func registerBuiltins() {
        register(OpenAppTool())
        register(SetVolumeTool())
        register(RunShellTool())
    }
}
