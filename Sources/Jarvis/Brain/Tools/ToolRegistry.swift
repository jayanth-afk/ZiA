import Foundation

public protocol JarvisTool: Sendable {
    var name: String { get }
    var description: String { get }
    func execute(parameters: [String: String]) async throws -> String
}

public final class ToolRegistry: @unchecked Sendable {
    public static let shared = ToolRegistry()

    private var tools = [String: JarvisTool]()
    private var cachedList: [JarvisTool]? = nil
    private let lock = NSLock()

    public init() {}

    public func register(_ tool: JarvisTool) {
        lock.lock()
        tools[tool.name] = tool
        cachedList = nil
        lock.unlock()
    }

    public func tool(named name: String) -> JarvisTool? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    public var allTools: [JarvisTool] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedList {
            return cached
        }
        let list = Array(tools.values)
        cachedList = list
        return list
    }
}