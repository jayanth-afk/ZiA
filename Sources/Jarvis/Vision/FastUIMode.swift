import Foundation

/// Actionable interactive UI element extracted from the accessibility tree.
struct ActionableUIElement: Sendable, Identifiable {
    let id: UUID
    let role: String
    let label: String
    let value: String?
    let actions: [String]

    init(id: UUID = UUID(), role: String, label: String, value: String? = nil, actions: [String] = []) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.actions = actions
    }
}

/// Fast UI navigation subsystem using macOS Accessibility APIs (<50ms).
/// Rule: Always try Fast UI Mode first before screenshot / deep visual reasoning.
@MainActor
final class FastUIMode {
    static let shared = FastUIMode()

    private init() {}

    // MARK: - Public API

    /// Generate a compact text summary of the current frontmost application UI.
    func describeCurrentUI() -> String? {
        guard let root = AccessibilityBridge.shared.getFrontmostAppElements(maxDepth: 3) else {
            return nil
        }

        let actionable = extractActionableElements(from: root)
        guard !actionable.isEmpty else {
            return nil
        }

        var lines = ["=== Current Frontmost App UI ==="]
        for elem in actionable.prefix(30) {
            var desc = "• [\(elem.role)] \"\(elem.label)\""
            if let val = elem.value, !val.isEmpty {
                desc += " = \"\(val)\""
            }
            if !elem.actions.isEmpty {
                desc += " (Actions: \(elem.actions.joined(separator: ", ")))"
            }
            lines.append(desc)
        }

        return lines.joined(separator: "\n")
    }

    /// Locate an actionable element matching a given name or label.
    func findElement(matching text: String) -> ActionableUIElement? {
        guard let root = AccessibilityBridge.shared.getFrontmostAppElements(maxDepth: 4) else {
            return nil
        }

        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let elements = extractActionableElements(from: root)

        // Exact match first
        if let exact = elements.first(where: { $0.label.lowercased() == lower }) {
            return exact
        }

        // Substring match
        return elements.first(where: { $0.label.lowercased().contains(lower) })
    }

    // MARK: - Private

    private func extractActionableElements(from element: AXElementInfo) -> [ActionableUIElement] {
        var results: [ActionableUIElement] = []

        let label = element.title ?? element.elementDescription ?? ""
        let isInteractive = !element.actions.isEmpty ||
            element.role == "AXButton" ||
            element.role == "AXTextField" ||
            element.role == "AXMenuItem" ||
            element.role == "AXCheckBox" ||
            element.role == "AXRadioButton" ||
            element.role == "AXPopUpButton"

        if isInteractive && !label.isEmpty {
            results.append(ActionableUIElement(
                role: element.role,
                label: label,
                value: element.value,
                actions: element.actions
            ))
        }

        for child in element.children {
            results.append(contentsOf: extractActionableElements(from: child))
        }

        return results
    }
}
