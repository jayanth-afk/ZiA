import Foundation

// MARK: - Project Awareness

/// Detects the project at a path so the planner can choose build/test
/// capabilities instead of guessing. Read-only and deterministic.
struct ProjectInfoTool: JarvisTool {
    let name = "project_info"
    let description = "Reports the detected project type, ecosystems, and suggested build/test commands for a directory. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: false,
                          description: "Directory to inspect (default: current working directory)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let path = (arguments["path"] as? String) ?? FileManager.default.currentDirectoryPath
        let profile = ProjectInspector.inspect(root: path)
        return ToolResult(
            success: true,
            output: profile.summary,
            sideEffects: [],
            metadata: [
                "path": profile.root,
                "kinds": profile.kinds.map(\.rawValue).joined(separator: ","),
                "markers": profile.markers.joined(separator: ",")
            ])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("cannot re-read project directory")
    }
}

// MARK: - Health

/// Reports Zia's own structured health, including degraded capabilities. This
/// is how Zia explains what is blocked and what still works.
struct CheckHealthTool: JarvisTool {
    let name = "check_health"
    let description = "Reports Zia's subsystem health (providers, storage, task queue, network, resources) and any degraded capabilities."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = []

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let report = await HealthService.shared.report()
        let detail = report.components
            .map { "\($0.name): \($0.status.rawValue) (\($0.detail))" }
            .joined(separator: "\n")
        return ToolResult(
            success: true,
            output: report.summary + "\n" + detail,
            sideEffects: [],
            metadata: ["overall": report.overall.rawValue,
                       "degraded": report.degradedCapabilities.joined(separator: "; ")])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("health service did not answer")
    }
}

// MARK: - Scheduling

/// Creates a durable scheduled job. Scheduling is a low-impact mutation: no
/// external effect happens until the job comes due and runs through the normal
/// task system (planning → validation → permission → execution → verification).
struct ScheduleTaskTool: JarvisTool {
    let name = "schedule_task"
    let description = "Schedules a goal to run later (once/interval/daily/weekly). The goal still passes through full planning and permission checks when it runs."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "goal", kind: .string, required: true,
                          description: "The goal to run when the job comes due"),
        ToolParameterSpec(name: "title", kind: .string, required: false,
                          description: "Short human-readable title"),
        ToolParameterSpec(name: "kind", kind: .string, required: true,
                          description: "One of: once, interval, daily, weekly"),
        ToolParameterSpec(name: "interval_seconds", kind: .int, required: false,
                          description: "Required for kind=interval"),
        ToolParameterSpec(name: "hour", kind: .int, required: false,
                          description: "Hour 0-23 for daily/weekly"),
        ToolParameterSpec(name: "minute", kind: .int, required: false,
                          description: "Minute 0-59 for daily/weekly"),
        ToolParameterSpec(name: "weekday", kind: .int, required: false,
                          description: "1=Sunday…7=Saturday for weekly"),
        ToolParameterSpec(name: "max_runs", kind: .int, required: false,
                          description: "Optional cap on total runs")
    ]

    static func scheduleKind(from arguments: [String: any Sendable]) throws -> ScheduleKind {
        let kind = (arguments["kind"] as? String)?.lowercased() ?? ""
        switch kind {
        case "once":
            let delay = Double((arguments["interval_seconds"] as? Int) ?? 0)
            return .once(at: Date().addingTimeInterval(max(0, delay)))
        case "interval":
            guard let seconds = arguments["interval_seconds"] as? Int, seconds > 0 else {
                throw JarvisError.actionFailed(action: "schedule_task", reason: "kind=interval requires a positive interval_seconds")
            }
            return .interval(seconds: Double(seconds))
        case "daily":
            return .daily(hour: (arguments["hour"] as? Int) ?? 9, minute: (arguments["minute"] as? Int) ?? 0)
        case "weekly":
            return .weekly(weekday: (arguments["weekday"] as? Int) ?? 2,
                           hour: (arguments["hour"] as? Int) ?? 9,
                           minute: (arguments["minute"] as? Int) ?? 0)
        default:
            throw JarvisError.actionFailed(action: "schedule_task",
                                           reason: "'kind' must be one of once, interval, daily, weekly")
        }
    }

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let goal = arguments["goal"] as? String,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'goal'")
        }
        let title = (arguments["title"] as? String) ?? String(goal.prefix(60))
        let kind = try Self.scheduleKind(from: arguments)
        let maxRuns = arguments["max_runs"] as? Int

        let job = try TaskScheduler.shared.add(
            title: title, goal: goal, kind: kind,
            priority: TaskPriority.backgroundMaintenance, maxRuns: maxRuns)

        return ToolResult(
            success: true,
            output: "Scheduled '\(title)' (job \(job.id.uuidString)); next run \(job.nextRunAt).",
            sideEffects: ["schedule_created"],
            metadata: ["job_id": job.id.uuidString, "next_run": "\(job.nextRunAt.timeIntervalSince1970)"])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let idText = expected.metadata["job_id"], let id = UUID(uuidString: idText) else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no job id recorded")
        }
        let exists = TaskScheduler.shared.job(id: id) != nil
        return ObservationResult(observations: ["jobExists": exists ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else { return .failed("schedule_task execution failed") }
        guard observed.isAvailable else { return .unavailable("could not read back the schedule") }
        guard observed.observations["jobExists"] == "true" else {
            return .failed("scheduled job was not retained in the scheduler")
        }
        return .passed(reason: "job retained in durable schedule")
    }
}

/// Lists the durable schedule.
struct ListScheduleTool: JarvisTool {
    let name = "list_schedule"
    let description = "Lists scheduled jobs with their next run time and enabled state. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = []

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let jobs = TaskScheduler.shared.all()
        guard !jobs.isEmpty else {
            return ToolResult(success: true, output: "No scheduled jobs.", metadata: ["count": "0"])
        }
        let lines = jobs.map { job in
            "• \(job.title) [\(job.enabled ? "enabled" : "disabled")] next \(job.nextRunAt) runs \(job.runCount)"
        }
        return ToolResult(success: true, output: lines.joined(separator: "\n"),
                          metadata: ["count": String(jobs.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("scheduler did not answer")
    }
}

// MARK: - Structured Memory

/// Remembers an explicit user fact as permanent semantic memory.
struct RememberFactTool: JarvisTool {
    let name = "remember_fact"
    let description = "Stores an explicit user fact as permanent semantic memory (trusted provenance)."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "content", kind: .string, required: true,
                          description: "The fact to remember")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let content = arguments["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'content'")
        }
        let record = await MemoryManager.shared.rememberUserFact(content)
        guard let record else {
            throw JarvisError.actionFailed(action: name, reason: "Memory store rejected the fact")
        }
        return ToolResult(success: true, output: "Remembered: \(record.content)",
                          sideEffects: ["memory_written"],
                          metadata: ["memory_id": record.id.uuidString])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let idText = expected.metadata["memory_id"], let id = UUID(uuidString: idText) else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no memory id recorded")
        }
        let exists = ZiaMemoryStore.shared.record(id: id) != nil
        return ObservationResult(observations: ["stored": exists ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else { return .failed("remember_fact execution failed") }
        guard observed.isAvailable else { return .unavailable("could not read back memory") }
        guard observed.observations["stored"] == "true" else {
            return .failed("fact was not retained in memory")
        }
        return .passed(reason: "fact retained as permanent semantic memory")
    }
}

/// Recalls trusted memory relevant to a query.
struct RecallMemoryTool: JarvisTool {
    let name = "recall_memory"
    let description = "Retrieves trusted, provenance-tagged memory relevant to a query. Untrusted records are excluded. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "query", kind: .string, required: true, description: "What to recall"),
        ToolParameterSpec(name: "limit", kind: .int, required: false, description: "Max records (default 5)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'query'")
        }
        let limit = (arguments["limit"] as? Int) ?? 5
        let records = ZiaMemoryStore.shared.retrieveTrusted(query: query, limit: limit)
        guard !records.isEmpty else {
            return ToolResult(success: true, output: "No trusted memory matched.", metadata: ["count": "0"])
        }
        let lines = records.map { "[\($0.kind.rawValue)/\($0.trust.label)] \(String($0.content.prefix(200)))" }
        return ToolResult(success: true, output: lines.joined(separator: "\n"),
                          metadata: ["count": String(records.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("memory store did not answer")
    }
}

// MARK: - Artifacts

/// Lists artifacts produced by tasks, with verification state.
struct ListArtifactsTool: JarvisTool {
    let name = "list_artifacts"
    let description = "Lists files/reports/outputs produced by tasks, with provenance and verification state. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "task_id", kind: .string, required: false,
                          description: "Optional task UUID to filter by")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let artifacts: [Artifact]
        if let idText = arguments["task_id"] as? String, let id = UUID(uuidString: idText) {
            artifacts = ArtifactRegistry.shared.artifacts(forTask: id)
        } else {
            artifacts = ArtifactRegistry.shared.all()
        }
        guard !artifacts.isEmpty else {
            return ToolResult(success: true, output: "No artifacts recorded.", metadata: ["count": "0"])
        }
        let lines = artifacts.map { "\($0.path) [\($0.kind.rawValue), \($0.verified ? "verified" : "unverified"), \($0.provenance)]" }
        return ToolResult(success: true, output: lines.joined(separator: "\n"),
                          metadata: ["count": String(artifacts.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("artifact registry did not answer")
    }
}
