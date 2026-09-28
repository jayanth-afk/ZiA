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
        return ObservationResult(observations: ["frontmostApp": frontmost], isAvailable: true)
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

    private static let lastClickedElement = LockedValue<String>("")
    private static let declaredPostcondition = LockedValue<[String: String]>([:])

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
        var postconditions: [String: String] = [:]
        if let expectedApp = arguments["expected_app"] as? String {
            meta["expected_app"] = expectedApp
            postconditions["expected_app"] = expectedApp
        }
        if let expectedExists = arguments["expected_element_exists"] as? String {
            meta["expected_element_exists"] = expectedExists
            postconditions["expected_element_exists"] = expectedExists
        }
        if let expectedDisappears = arguments["expected_element_disappears"] as? String {
            meta["expected_element_disappears"] = expectedDisappears
            postconditions["expected_element_disappears"] = expectedDisappears
        }
        if let expectedFocused = arguments["expected_focused"] as? String {
            meta["expected_focused"] = expectedFocused
            postconditions["expected_focused"] = expectedFocused
        }
        if let hasPostcondition = arguments["has_postcondition"] as? String {
            meta["has_postcondition"] = hasPostcondition
            postconditions["has_postcondition"] = hasPostcondition
        }

        Self.lastClickedElement.value = label
        Self.declaredPostcondition.value = postconditions

        return ToolResult(
            success: true,
            output: output,
            sideEffects: ["ui_element_clicked"],
            metadata: meta
        )
    }

    func observe() async throws -> ObservationResult {
        return await MainActor.run {
            guard AccessibilityBridge.shared.isTrusted else {
                return ObservationResult.unavailable(reason: "Accessibility permission not granted")
            }

            let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            var obs: [String: String] = ["frontmostApp": frontmost]

            let target = Self.lastClickedElement.value
            if !target.isEmpty {
                let exists = AccessibilityBridge.shared.elementExists(matchingLabel: target)
                obs["elementExists"] = String(exists)
            }

            let post = Self.declaredPostcondition.value
            if let expectedExists = post["expected_element_exists"], !expectedExists.isEmpty {
                obs["elementExists_\(expectedExists)"] = String(AccessibilityBridge.shared.elementExists(matchingLabel: expectedExists))
            }
            if let expectedDisappears = post["expected_element_disappears"], !expectedDisappears.isEmpty {
                obs["elementExists_\(expectedDisappears)"] = String(AccessibilityBridge.shared.elementExists(matchingLabel: expectedDisappears))
            }
            if let expectedFocused = post["expected_focused"], !expectedFocused.isEmpty {
                obs["isFocused_\(expectedFocused)"] = String(AccessibilityBridge.shared.isElementFocused(matchingLabel: expectedFocused))
            }

            return ObservationResult(observations: obs, isAvailable: true)
        }
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed("Click execution failed", expected: "action success", observed: "execution failure")
        }
        guard observed.isAvailable else {
            return .unavailable(observed.reason ?? "UI observation unavailable", expected: "valid observation", observed: "unavailable")
        }

        // Postcondition 1: expected_app transition
        if let expectedApp = expected.metadata["expected_app"], !expectedApp.isEmpty {
            let frontmost = observed.observations["frontmostApp"] ?? ""
            if frontmost.lowercased().contains(expectedApp.lowercased()) || expectedApp.lowercased().contains(frontmost.lowercased()) {
                return .passed(expected: expectedApp, observed: frontmost)
            } else {
                return .failed(
                    "Expected frontmost application '\(expectedApp)' after click, but observed '\(frontmost)'",
                    expected: expectedApp,
                    observed: frontmost
                )
            }
        }

        // Postcondition 2: expected_element_exists
        if let targetElem = expected.metadata["expected_element_exists"], !targetElem.isEmpty {
            let exists = (observed.observations["elementExists_\(targetElem)"] == "true") || (observed.observations["elementExists"] == "true" && targetElem == expected.metadata["elementLabel"])
            if exists {
                return .passed(expected: "element '\(targetElem)' exists", observed: "exists")
            } else {
                return .failed(
                    "Expected element '\(targetElem)' to exist after click",
                    expected: "exists",
                    observed: "missing"
                )
            }
        }

        // Postcondition 3: expected_element_disappears
        if let targetElem = expected.metadata["expected_element_disappears"], !targetElem.isEmpty {
            let exists = (observed.observations["elementExists_\(targetElem)"] == "true") || (observed.observations["elementExists"] == "true" && targetElem == expected.metadata["elementLabel"])
            if !exists {
                return .passed(expected: "element '\(targetElem)' disappears", observed: "disappeared")
            } else {
                return .failed(
                    "Expected element '\(targetElem)' to disappear after click",
                    expected: "disappeared",
                    observed: "still present"
                )
            }
        }

        // Postcondition 4: expected_focused
        if let focusedElem = expected.metadata["expected_focused"], !focusedElem.isEmpty {
            let isFocused = observed.observations["isFocused_\(focusedElem)"] == "true"
            if isFocused {
                return .passed(expected: "element '\(focusedElem)' focused", observed: "focused")
            } else {
                return .failed(
                    "Expected element '\(focusedElem)' to be focused after click",
                    expected: "focused",
                    observed: "not focused"
                )
            }
        }

        // Postcondition 5: explicit confirmation flag
        if expected.metadata["has_postcondition"] == "true" {
            return .passed(expected: "explicit postcondition confirmed", observed: "confirmed")
        }

        // Default: A click without a deterministic postcondition cannot claim verified success
        return .inconclusive(
            "Click executed; no deterministic postcondition specified to verify state mutation",
            expected: "deterministic postcondition",
            observed: "none"
        )
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

    private static let lastTargetElement = LockedValue<String?>(nil)

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let text = arguments["text"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Missing required argument 'text'")
        }
        let elementLabel = arguments["element_label"] as? String

        let output = try await MainActor.run { () throws -> String in
            return try FastUIMode.shared.setText(text, onElement: elementLabel)
        }

        Self.lastTargetElement.value = elementLabel

        var meta: [String: String] = ["expectedValue": text]
        if let label = elementLabel {
            meta["targetElement"] = label
        }

        return ToolResult(
            success: true,
            output: output,
            sideEffects: ["ui_text_entered"],
            metadata: meta
        )
    }

    func observe() async throws -> ObservationResult {
        return await MainActor.run {
            guard AccessibilityBridge.shared.isTrusted else {
                return ObservationResult.unavailable(reason: "Accessibility permission not granted")
            }

            let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            let targetLabel = Self.lastTargetElement.value

            let (val, isAvailable) = AccessibilityBridge.shared.readElementValue(matchingLabel: targetLabel)
            guard isAvailable else {
                let targetDesc = targetLabel ?? "focused element"
                return ObservationResult.unavailable(reason: "Could not read accessibility value for '\(targetDesc)'")
            }

            var obs: [String: String] = [
                "frontmostApp": frontmost,
                "currentValue": val ?? ""
            ]
            if let label = targetLabel {
                obs["targetElement"] = label
            }

            return ObservationResult(observations: obs, isAvailable: true)
        }
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard expected.success else {
            return .failed(
                "set_text execution failed",
                expected: expected.metadata["expectedValue"],
                observed: nil
            )
        }
        guard observed.isAvailable else {
            return .unavailable(
                observed.reason ?? "UI value observation unavailable",
                expected: expected.metadata["expectedValue"],
                observed: nil
            )
        }
        guard let expectedVal = expected.metadata["expectedValue"] else {
            return .inconclusive(
                "No expected value recorded for verification",
                expected: nil,
                observed: observed.observations["currentValue"]
            )
        }
        guard let observedVal = observed.observations["currentValue"] else {
            return .unavailable(
                "Observed field value is missing",
                expected: expectedVal,
                observed: nil
            )
        }

        if observedVal == expectedVal {
            return .passed(
                reason: "Observed field value matches expected text",
                expected: expectedVal,
                observed: observedVal
            )
        } else {
            return .failed(
                "Expected field value '\(expectedVal)', but observed '\(observedVal)'",
                expected: expectedVal,
                observed: observedVal
            )
        }
    }
}
