import Foundation
import AppKit

/// A description of something Zia can do, independent of how it is implemented.
/// Enables Zia to reason about (and explain) its own capability surface.
struct CapabilityDescriptor: Sendable, Equatable {
    let name: String
    let purpose: String
    let category: String
    let impact: String
    let requiresNetwork: Bool
    let availability: String
}

/// Zia's self-knowledge, derived entirely from real system state — never from
/// model memory. Used to answer "what can you do?", "what is running?", "are you
/// degraded?", "what permissions do you have?".
@MainActor
enum CapabilityRegistry {

    /// Capability descriptors for every registered tool plus the non-tool
    /// subsystems Zia relies on.
    static func descriptors() -> [CapabilityDescriptor] {
        var result = ToolRegistry.shared.allTools.map { tool in
            let avail: String
            if ["inspect_ui", "click_element", "set_text"].contains(tool.name) {
                avail = AXIsProcessTrusted() ? "available" : "permission blocked (Accessibility)"
            } else {
                avail = "available"
            }
            return CapabilityDescriptor(
                name: tool.name,
                purpose: tool.description,
                category: category(for: tool.name),
                impact: impactLabel(tool.impact),
                requiresNetwork: requiresNetwork(tool.name),
                availability: avail)
        }
        result.append(CapabilityDescriptor(
            name: "intelligence.mlx", purpose: "Local on-device model inference",
            category: "intelligence", impact: "read-only", requiresNetwork: false,
            availability: "available"))
        result.append(CapabilityDescriptor(
            name: "intelligence.cloud", purpose: "Optional external model providers",
            category: "intelligence", impact: "read-only", requiresNetwork: true,
            availability: "configured"))
        result.append(CapabilityDescriptor(
            name: "memory", purpose: "Trust-classified durable memory",
            category: "memory", impact: "read-only", requiresNetwork: false,
            availability: "available"))
        result.append(CapabilityDescriptor(
            name: "scheduler", purpose: "Durable scheduled and recurring goals",
            category: "autonomy", impact: "read-only", requiresNetwork: false,
            availability: "available"))
        result.append(CapabilityDescriptor(
            name: "voice", purpose: "Voice pipeline (transcription, wake-word, TTS)",
            category: "voice", impact: "read-only", requiresNetwork: false,
            availability: VoicePipeline.shared.isRunning ? "active" : "standby"))
        result.append(CapabilityDescriptor(
            name: "agent-bridge", purpose: "Optional external agent transport",
            category: "integration", impact: "read-only", requiresNetwork: true,
            availability: ExternalAgentRegistry.shared.activeTransport?.isConfigured == true ? "configured" : "not configured"))
        return result.sorted { $0.name < $1.name }
    }

    static func capabilitySummary() -> String {
        let all = descriptors()
        let byCategory = Dictionary(grouping: all, by: \.category).sorted { $0.key < $1.key }
        var lines = ["I currently expose \(all.count) capabilities:"]
        for (category, items) in byCategory {
            lines.append("• \(category): " + items.map(\.name).sorted().joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// A complete, state-derived self-report.
    static func selfAwarenessReport() async -> String {
        var lines: [String] = []

        let health = await HealthService.shared.report()
        lines.append("Health: \(health.overall.rawValue)")
        if !health.degradedCapabilities.isEmpty {
            lines.append("Reduced: " + health.degradedCapabilities.joined(separator: "; "))
        }

        let providers = await ProviderManager.shared.healthSnapshot()
        let availableNames = providers.statuses.filter(\.isAvailable).map(\.id)
        lines.append("Intelligence: \(providers.availableCount)/\(providers.totalCount) providers available"
                     + (availableNames.isEmpty ? "" : " (\(availableNames.joined(separator: ", ")))"))
        if !providers.quarantined.isEmpty {
            lines.append("Quarantined providers: " + providers.quarantined.joined(separator: ", "))
        }

        lines.append("Autonomy: \(AutonomyPolicy.current.title)")
        lines.append("Permission level: \(PermissionGate.shared.currentLevel.rawValue)")

        let active = TaskStateMachine.shared.activeTasks
        if active.isEmpty {
            lines.append("Running tasks: none")
        } else {
            let names = active.prefix(5).map { "\(String($0.goal.prefix(60))) [\($0.state.rawValue)]" }
            lines.append("Running tasks: (\(active.count)) " + names.joined(separator: "; "))
        }

        let scheduled = TaskScheduler.shared.enabledJobCount
        lines.append("Scheduled jobs: \(scheduled)")

        lines.append("Artifacts recorded: \(ArtifactRegistry.shared.count)")
        lines.append(ProjectInspector.inspect(root: FileManager.default.currentDirectoryPath).summary)

        let recovery = CrashRecovery.inspect(tasks: TaskStateMachine.shared.allTasks)
        if !recovery.plans.isEmpty {
            lines.append("Interrupted work: \(recovery.plans.count) task(s) — " +
                         recovery.plans.map { $0.disposition.rawValue }.joined(separator: ", "))
        }

        lines.append("Network: \(AppState.shared.isOnline ? "online" : "offline")")
        return lines.joined(separator: "\n")
    }

    // MARK: - Classification helpers

    private static func category(for toolName: String) -> String {
        switch toolName {
        case "read_file", "write_file", "append_file", "list_directory", "file_metadata",
             "copy_path", "move_path", "create_directory", "delete_path", "search_files",
             "grep_files", "replace_in_file", "patch_file":
            return "filesystem"
        case "run_program", "run_shell":
            return "execution"
        case "web_search", "fetch_url", "open_browser", "inspect_browser_page",
             "extract_browser_text", "click_browser_link", "fill_browser_text":
            return "browser-web"
        case "inspect_ui", "click_element", "set_text", "open_app", "set_volume":
            return "computer-control"
        case "remember_fact", "recall_memory", "list_artifacts":
            return "memory-artifacts"
        case "project_info", "find_symbol", "find_markers", "changed_files":
            return "code-intelligence"
        case "schedule_task", "list_schedule", "recovery_status":
            return "autonomy"
        case "check_health":
            return "diagnostics"
        default:
            return "other"
        }
    }

    private static func impactLabel(_ impact: PermissionGate.ActionImpact) -> String {
        switch impact {
        case .readOnly: return "read-only"
        case .safeMutation: return "low-impact"
        case .destructive: return "destructive"
        }
    }

    private static func requiresNetwork(_ toolName: String) -> Bool {
        ["web_search", "fetch_url", "open_browser", "inspect_browser_page",
         "extract_browser_text", "click_browser_link", "fill_browser_text"].contains(toolName)
    }
}
