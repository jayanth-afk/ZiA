import Foundation
import ApplicationServices
import AppKit

/// Represents an element in the macOS Accessibility UI element tree.
struct AXElementInfo: Sendable, Identifiable {
    let id: UUID
    let role: String
    let title: String?
    let value: String?
    let elementDescription: String?
    let frame: CGRect?
    let actions: [String]
    let children: [AXElementInfo]

    init(
        id: UUID = UUID(),
        role: String,
        title: String? = nil,
        value: String? = nil,
        elementDescription: String? = nil,
        frame: CGRect? = nil,
        actions: [String] = [],
        children: [AXElementInfo] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.elementDescription = elementDescription
        self.frame = frame
        self.actions = actions
        self.children = children
    }
}

/// Bridges macOS Accessibility (AXUIElement) APIs for Fast UI inspection.
/// Rule: Always try Accessibility API first before falling back to Vision models.
@MainActor
final class AccessibilityBridge {
    static let shared = AccessibilityBridge()

    private init() {}

    // MARK: - Permissions

    /// Check if accessibility trust is granted for the app.
    var isTrusted: Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt user for Accessibility permissions if missing.
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - UI Tree Inspection

    /// Extract the element hierarchy of the frontmost running application.
    func getFrontmostAppElements(maxDepth: Int = 3) -> AXElementInfo? {
        guard isTrusted else {
            JarvisLogger.actions.warning("Accessibility permission not granted; cannot inspect UI tree")
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        return parseElement(appElement, depth: 0, maxDepth: maxDepth)
    }

    /// Parse an AXUIElement into a Sendable AXElementInfo struct.
    private func parseElement(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXElementInfo? {
        guard depth <= maxDepth else { return nil }

        // Role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleResult == .success ? roleValue as? String : nil) ?? "Unknown"

        // Title
        var titleValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String

        // Value
        var valValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valValue)
        let value = valValue as? String

        // Description
        var descValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
        let elementDescription = descValue as? String

        // Actions
        var actionsArray: CFArray?
        let actionResult = AXUIElementCopyActionNames(element, &actionsArray)
        let actions = (actionResult == .success ? (actionsArray as? [String]) : nil) ?? []

        // Children
        var childInfos: [AXElementInfo] = []
        if depth < maxDepth {
            var childrenValue: AnyObject?
            let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            if childResult == .success, let children = childrenValue as? [AXUIElement] {
                for child in children.prefix(20) { // Limit breadth per node
                    if let parsedChild = parseElement(child, depth: depth + 1, maxDepth: maxDepth) {
                        childInfos.append(parsedChild)
                    }
                }
            }
        }

        return AXElementInfo(
            role: role,
            title: title,
            value: value,
            elementDescription: elementDescription,
            frame: nil,
            actions: actions,
            children: childInfos
        )
    }
}
