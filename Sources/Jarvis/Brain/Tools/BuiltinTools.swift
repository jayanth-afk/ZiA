import Foundation
import AppKit

// MARK: - Open Application Tool

struct OpenAppTool: JarvisTool {
    let name = "open_app"
    let description = "Opens or switches to a macOS application by name"
    let impact: PermissionGate.ActionImpact = .safeMutation

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let appName = arguments["app_name"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing argument 'app_name'")
        }

        let output = try await AppLauncher.shared.open(appName)
        return ToolResult(success: true, output: output, sideEffects: ["app_launched"])
    }

    func observe() async throws -> ObservationResult {
        let frontmost = await NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
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

    func execute(arguments: [String: Any]) async throws -> ToolResult {
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

    func execute(arguments: [String: Any]) async throws -> ToolResult {
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
