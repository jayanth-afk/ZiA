import Foundation
import AppKit

// MARK: - Inspect UI Tool

struct InspectUITool: JarvisTool {
    let name = "inspect_ui"
    let description = "Inspects and lists actionable UI elements (buttons, text fields, menu items) of the frontmost application"
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "filter", kind: .string, required: false, description: "Optional filter string to match specific element labels")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let filter = arguments["filter"] as? String

        let summary = try await MainActor.run { () throws -> String in
            guard AccessibilityBridge.shared.isTrusted else {
                throw JarvisError.actionFailed(
                    action: name,
                    reason: "Accessibility permission not granted. Please grant Accessibility in System Settings -> Privacy & Security."
                )
            }
            guard let desc = FastUIMode.shared.describeCurrentUI() else {
                return "No actionable UI elements detected in frontmost application."
            }

            if let f = filter, !f.isEmpty {
                let lower = f.lowercased()
                let matchingLines = desc.components(separatedBy: "\n").filter { line in
                    line.hasPrefix("===") || line.lowercased().contains(lower)
                }
                return matchingLines.joined(separator: "\n")
            }
            return desc
        }

        return ToolResult(success: true, output: summary, sideEffects: [])
    }

    func observe() async throws -> ObservationResult {
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        }
        return ObservationResult(observations: ["frontmostApp": frontmost])
    }

    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success
    }
}

// MARK: - Click Element Tool

struct ClickElementTool: JarvisTool {
    let name = "click_element"
    let description = "Clicks an interactive UI element by name or label in the frontmost application"
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "element_label", kind: .string, required: true, description: "Label or title of the element to click")
    ]

    static func isDestructiveLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        let destructiveKeywords = [
            "delete", "erase", "format", "empty trash", "shut down",
            "restart", "wipe", "uninstall", "drop table", "remove all"
        ]
        return destructiveKeywords.contains { lower.contains($0) }
    }

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let label = arguments["element_label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JarvisError.actionFailed(action: name, reason: "Missing required argument 'element_label'")
        }

        // Authority boundary: Destructive labels require elevated permission / confirmation
        let targetImpact: PermissionGate.ActionImpact = Self.isDestructiveLabel(label) ? .destructive : .safeMutation
        _ = try await MainActor.run {
            try PermissionGate.shared.isAuthorized(actionName: "click_element:\(label)", impact: targetImpact)
        }

        let output = try await MainActor.run { () throws -> String in
            return try FastUIMode.shared.clickElement(matching: label)
        }

        return ToolResult(success: true, output: output, sideEffects: ["ui_element_clicked"])
    }

    func observe() async throws -> ObservationResult {
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        }
        return ObservationResult(observations: ["frontmostApp": frontmost])
    }

    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success
    }
}

// MARK: - Set Text Tool

struct SetTextTool: JarvisTool {
    let name = "set_text"
    let description = "Enters text into an editable UI field in the frontmost application"
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "text", kind: .string, required: true, description: "Text content to enter"),
        ToolParameterSpec(name: "element_label", kind: .string, required: false, description: "Optional label of the target text field")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let text = arguments["text"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing required argument 'text'")
        }
        let elementLabel = arguments["element_label"] as? String

        let output = try await MainActor.run { () throws -> String in
            return try FastUIMode.shared.setText(text, onElement: elementLabel)
        }

        return ToolResult(success: true, output: output, sideEffects: ["ui_text_entered"])
    }

    func observe() async throws -> ObservationResult {
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        }
        return ObservationResult(observations: ["frontmostApp": frontmost])
    }

    func verify(expected: ToolResult, observed: ObservationResult) -> Bool {
        return expected.success
    }
}
