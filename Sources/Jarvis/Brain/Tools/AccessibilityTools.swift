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
        ToolParameterSpec(name: "element_label", kind: .string, required: true, description: "Label or title of the element to click"),
        ToolParameterSpec(name: "expected_app", kind: .string, required: false, description: "Declared postcondition: app expected frontmost after click"),
        ToolParameterSpec(name: "expected_element_exists", kind: .string, required: false, description: "Declared postcondition: element expected to exist"),
        ToolParameterSpec(name: "expected_element_disappears", kind: .string, required: false, description: "Declared postcondition: element expected to disappear"),
        ToolParameterSpec(name: "expected_focused", kind: .string, required: false, description: "Declared postcondition: element expected focused")
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

        var meta: [String: String] = ["elementLabel": label]
        if let expectedApp = arguments["expected_app"] as? String {
            meta["expected_app"] = expectedApp
        }
        if let value = arguments["expected_element_exists"] as? String { meta["expected_element_exists"] = value }
        if let value = arguments["expected_element_disappears"] as? String { meta["expected_element_disappears"] = value }
        if let value = arguments["expected_focused"] as? String { meta["expected_focused"] = value }

        return ToolResult(
            success: true,
            output: output,
            sideEffects: ["ui_element_clicked"],
            metadata: meta
        )
    }

    func observe() async throws -> ObservationResult {
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        }
        return ObservationResult(observations: ["frontmostApp": frontmost], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        await MainActor.run {
            guard AccessibilityBridge.shared.isTrusted else { return .unavailable(reason: "Accessibility permission not granted") }
            var values: [String: String] = ["frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""]
            for key in ["expected_element_exists", "expected_element_disappears"] {
                if let label = expected.metadata[key], !label.isEmpty {
                    let result = AccessibilityBridge.shared.elementExists(matchingLabel: label)
                    guard result.isAvailable else { return .unavailable(reason: "Could not observe element '\(label)'") }
                    values[key] = String(result.exists)
                }
            }
            if let label = expected.metadata["expected_focused"], !label.isEmpty {
                let result = AccessibilityBridge.shared.isElementFocused(matchingLabel: label)
                guard result.isAvailable else { return .unavailable(reason: "Could not observe focus for '\(label)'") }
                values["expected_focused"] = String(result.focused)
            }
            return ObservationResult(observations: values)
        }
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("Click execution failed")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "UI observation unavailable")
        }
        if let expectedApp = expected.metadata["expected_app"], !expectedApp.isEmpty {
            let frontmost = observed.observations["frontmostApp"] ?? ""
            if frontmost.lowercased().contains(expectedApp.lowercased()) {
                return .passed
            } else {
                return .failed("Expected frontmost application '\(expectedApp)' after click, but observed '\(frontmost)'")
            }
        }
        if let label = expected.metadata["expected_element_exists"] {
            return observed.observations["expected_element_exists"] == "true" ? .passed(expected: "element \(label) exists", observed: "exists") : .failed("Expected element '\(label)' to exist", expected: "exists", observed: "missing")
        }
        if let label = expected.metadata["expected_element_disappears"] {
            return observed.observations["expected_element_disappears"] == "false" ? .passed(expected: "element \(label) disappears", observed: "missing") : .failed("Expected element '\(label)' to disappear", expected: "missing", observed: "exists")
        }
        if let label = expected.metadata["expected_focused"] {
            return observed.observations["expected_focused"] == "true" ? .passed(expected: "element \(label) focused", observed: "focused") : .failed("Expected element '\(label)' to be focused", expected: "focused", observed: "not focused")
        }
        return .inconclusive("Click executed; no deterministic postcondition specified to verify state mutation")
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

        var meta: [String: String] = ["expectedValue": text]
        if let label = elementLabel { meta["elementLabel"] = label }

        return ToolResult(
            success: true,
            output: output,
            sideEffects: ["ui_text_entered"],
            metadata: meta
        )
    }

    func observe() async throws -> ObservationResult {
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        }
        return ObservationResult(observations: ["frontmostApp": frontmost], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        await MainActor.run {
            guard AccessibilityBridge.shared.isTrusted else { return .unavailable(reason: "Accessibility permission not granted") }
            let label = expected.metadata["elementLabel"]
            let value = AccessibilityBridge.shared.readElementValue(matchingLabel: label)
            guard value.isAvailable else {
                return .unavailable(reason: "Could not observe current AX value for \(label ?? "focused element")")
            }
            return ObservationResult(observations: ["currentValue": value.value ?? ""])
        }
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("set_text execution failed")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "UI observation unavailable")
        }
        guard let expectedVal = expected.metadata["expectedValue"] else {
            return .inconclusive("No expected value was recorded for set_text")
        }
        guard let observedVal = observed.observations["currentValue"] else {
            return .unavailable("Current AX value was not observed", expected: expectedVal)
        }
        return observedVal == expectedVal
            ? .passed(reason: "Observed field value matches expected text", expected: expectedVal, observed: observedVal)
            : .failed("Expected field value '\(expectedVal)', but observed '\(observedVal)'", expected: expectedVal, observed: observedVal)
    }
}
