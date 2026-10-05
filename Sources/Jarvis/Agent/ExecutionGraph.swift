import Foundation

/// Type of operation a node in the execution graph performs.
enum ExecutionNodeKind: String, Codable, Sendable, CaseIterable {
    /// Execute a tool or model composition.
    case action
    /// Observe environmental reality (read-back, tab query, process probe).
    case observation
    /// Deterministically verify expected vs observed state.
    case verification
    /// Evaluate condition and choose branching path.
    case decision
    /// Wait for condition, external signal, or timer.
    case wait
    /// Require explicit user confirmation before proceeding.
    case userConfirmation
}

/// A discrete node in an asynchronous, dependency-tracked execution graph.
struct ExecutionNode: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let kind: ExecutionNodeKind
    let description: String
    let toolName: String?
    let arguments: [String: String]
    /// Node IDs that must complete before this node can run.
    let dependencies: [String]
    var state: TaskState
    var output: String?
    var error: String?
    var verificationOutcome: VerificationOutcome?

    init(
        id: String = UUID().uuidString,
        kind: ExecutionNodeKind = .action,
        description: String,
        toolName: String? = nil,
        arguments: [String: String] = [:],
        dependencies: [String] = [],
        state: TaskState = .created,
        output: String? = nil,
        error: String? = nil,
        verificationOutcome: VerificationOutcome? = nil
    ) {
        self.id = id
        self.kind = kind
        self.description = description
        self.toolName = toolName
        self.arguments = arguments
        self.dependencies = dependencies
        self.state = state
        self.output = output
        self.error = error
        self.verificationOutcome = verificationOutcome
    }
}

enum ExecutionGraphError: LocalizedError, Equatable {
    case emptyGraph
    case missingDependency(node: String, dependency: String)
    case cycleDetected(String)
    case nodeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyGraph: return "Execution graph contains no nodes"
        case .missingDependency(let n, let d): return "Node '\(n)' depends on non-existent node '\(d)'"
        case .cycleDetected(let c): return "Cycle detected in execution graph: \(c)"
        case .nodeNotFound(let n): return "Node '\(n)' not found in execution graph"
        }
    }
}

/// A validated Directed Acyclic Graph (DAG) of execution nodes.
///
/// Ensures:
/// - Explicit dependencies between actions, observations, verifications, and confirmations.
/// - Cycle detection prevents deadlock or infinite loops.
/// - Nodes can only run when all prerequisites have completed successfully.
/// - Model may propose the graph structure, but authority and validation gate execution.
struct ExecutionGraph: Codable, Sendable, Equatable {
    let id: UUID
    let goal: String
    var nodes: [String: ExecutionNode]

    init(id: UUID = UUID(), goal: String, nodes: [ExecutionNode]) {
        self.id = id
        self.goal = goal
        var map: [String: ExecutionNode] = [:]
        for node in nodes { map[node.id] = node }
        self.nodes = map
    }

    /// All node descriptors in deterministic ID order.
    var allNodes: [ExecutionNode] {
        nodes.values.sorted { $0.id < $1.id }
    }

    /// Nodes with zero dependencies (can start immediately).
    var rootNodes: [ExecutionNode] {
        nodes.values.filter { $0.dependencies.isEmpty }.sorted { $0.id < $1.id }
    }

    /// Nodes that no other node depends on.
    var leafNodes: [ExecutionNode] {
        let allDepIDs = Set(nodes.values.flatMap(\.dependencies))
        return nodes.values.filter { !allDepIDs.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// Return nodes that are ready to execute given the currently completed node IDs.
    func readyNodes(completedNodeIDs: Set<String>) -> [ExecutionNode] {
        nodes.values.filter { node in
            node.state == .created &&
            node.dependencies.allSatisfy { completedNodeIDs.contains($0) }
        }.sorted { $0.id < $1.id }
    }

    /// Validates the graph: verifies every dependency exists and there are no cycles.
    func validate() throws {
        guard !nodes.isEmpty else { throw ExecutionGraphError.emptyGraph }

        // 1. Dependency existence check
        for (nodeID, node) in nodes {
            for depID in node.dependencies {
                guard nodes[depID] != nil else {
                    throw ExecutionGraphError.missingDependency(node: nodeID, dependency: depID)
                }
            }
        }

        // 2. Cycle detection via Kahn's algorithm
        _ = try topologicalOrder()
    }

    /// Returns nodes in a valid topological execution order.
    func topologicalOrder() throws -> [ExecutionNode] {
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]

        for id in nodes.keys {
            inDegree[id] = 0
            dependents[id] = []
        }

        for (id, node) in nodes {
            inDegree[id] = node.dependencies.count
            for dep in node.dependencies {
                dependents[dep, default: []].append(id)
            }
        }

        var queue: [String] = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var ordered: [ExecutionNode] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let node = nodes[current] { ordered.append(node) }

            for next in (dependents[current] ?? []).sorted() {
                inDegree[next] = (inDegree[next] ?? 1) - 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }

        guard ordered.count == nodes.count else {
            let cycleNodes = nodes.keys.filter { (inDegree[$0] ?? 0) > 0 }
            throw ExecutionGraphError.cycleDetected(cycleNodes.sorted().joined(separator: ", "))
        }

        return ordered
    }

    /// Compiles a linear AgentPlan into a robust execution graph with explicit
    /// action -> observation -> verification node triples for verifiable tools.
    static func compile(from plan: AgentPlan) -> ExecutionGraph {
        var nodes: [ExecutionNode] = []
        var previousTerminalID: String? = nil

        for (index, step) in plan.steps.enumerated() {
            let stepNum = index + 1
            let actionID = "step_\(stepNum)_action"
            var actionDeps: [String] = []
            if let prev = previousTerminalID { actionDeps.append(prev) }

            let requiresConfirmation = step.toolName.flatMap { ToolRegistry.shared.getTool(named: $0) }?.impact == .destructive

            if requiresConfirmation {
                let confirmID = "step_\(stepNum)_confirm"
                let confirmNode = ExecutionNode(
                    id: confirmID,
                    kind: .userConfirmation,
                    description: "Confirm destructive action: \(step.purpose)",
                    dependencies: actionDeps
                )
                nodes.append(confirmNode)
                actionDeps = [confirmID]
            }

            let actionNode = ExecutionNode(
                id: actionID,
                kind: .action,
                description: step.purpose,
                toolName: step.toolName,
                arguments: step.arguments,
                dependencies: actionDeps
            )
            nodes.append(actionNode)

            // If the tool supports verification, add observation & verification nodes
            if let toolName = step.toolName, ToolRegistry.shared.getTool(named: toolName) != nil {
                let observeID = "step_\(stepNum)_observe"
                let verifyID = "step_\(stepNum)_verify"

                let observeNode = ExecutionNode(
                    id: observeID,
                    kind: .observation,
                    description: "Observe environment after \(step.purpose)",
                    toolName: toolName,
                    dependencies: [actionID]
                )
                let verifyNode = ExecutionNode(
                    id: verifyID,
                    kind: .verification,
                    description: "Verify state for \(step.purpose)",
                    toolName: toolName,
                    dependencies: [observeID]
                )
                nodes.append(observeNode)
                nodes.append(verifyNode)
                previousTerminalID = verifyID
            } else {
                previousTerminalID = actionID
            }
        }

        return ExecutionGraph(goal: plan.goal, nodes: nodes)
    }
}
