import Foundation

final class ToolRegistry: @unchecked Sendable {
    public static let shared = ToolRegistry()

    private var tools = [String: any JarvisTool]()
    private var cachedList: [any JarvisTool]? = nil
    private let lock = NSLock()

    private init() {
        registerBuiltins()
    }

    func register(_ tool: any JarvisTool) {
        lock.lock()
        tools[tool.name] = tool
        cachedList = nil
        lock.unlock()
    }

    func tool(named name: String) -> (any JarvisTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    func getTool(named name: String) -> (any JarvisTool)? {
        tool(named: name)
    }

    var allTools: [any JarvisTool] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedList {
            return cached
        }
        let list = Array(tools.values)
        cachedList = list
        return list
    }

    func getToolDefinitions() -> [ToolDefinition] {
        allTools.map { tool in
            ToolDefinition(name: tool.name, description: tool.description,
                           parametersJSON: Self.parametersJSON(for: tool))
        }
    }

    private static func parametersJSON(for tool: any JarvisTool) -> String {
        var properties: [String] = []
        var required: [String] = []
        for spec in tool.parameterSpec {
            properties.append("\"\(spec.name)\":{\"type\":\"\(spec.kind.rawValue)\"}")
            if spec.required { required.append("\"\(spec.name)\"") }
        }
        return "{\"type\":\"object\",\"properties\":{\(properties.joined(separator: ","))},\"required\":[\(required.joined(separator: ","))]}"
    }

    private func registerBuiltins() {
        register(OpenAppTool())
        register(SetVolumeTool())
        register(RunProgramTool())
        register(RunShellTool())
        register(WriteFileTool())
        register(ReadFileTool())
        register(WebSearchTool())
        register(FetchURLTool())
        register(OpenBrowserTool())
        register(InspectBrowserPageTool())
        register(ExtractBrowserTextTool())
        register(ClickBrowserLinkTool())
        register(FillBrowserTextTool())
        register(InspectUITool())
        register(ClickElementTool())
        register(SetTextTool())
        // Zia-native capabilities: project awareness, health, scheduling,
        // structured memory, and artifacts. Registered like any other tool so
        // they are discoverable and composable by the planner.
        register(ProjectInfoTool())
        register(CheckHealthTool())
        register(ScheduleTaskTool())
        register(ListScheduleTool())
        register(RememberFactTool())
        register(RecallMemoryTool())
        register(ListArtifactsTool())
        // Safe filesystem, search, and exact-replacement editing capabilities.
        register(ListDirectoryTool())
        register(FileMetadataTool())
        register(SearchFilesTool())
        register(GrepFilesTool())
        register(CreateDirectoryTool())
        register(AppendFileTool())
        register(MoveOrCopyPathTool(move: false))
        register(MoveOrCopyPathTool(move: true))
        register(ReplaceInFileTool())
        register(DeletePathTool())
    }
}

extension JarvisTool {
    func execute(parameters: [String: String]) async throws -> String {
        let arguments = parameters.mapValues { $0 as any Sendable }
        return try await ToolExecutor.shared.execute(toolName: name, arguments: arguments).output
    }
}