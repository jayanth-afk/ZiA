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
    let isEnabled: Bool
    let actions: [String]
    let children: [AXElementInfo]

    init(
        id: UUID = UUID(),
        role: String,
        title: String? = nil,
        value: String? = nil,
        elementDescription: String? = nil,
        frame: CGRect? = nil,
        isEnabled: Bool = true,
        actions: [String] = [],
        children: [AXElementInfo] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.elementDescription = elementDescription
        self.frame = frame
        self.isEnabled = isEnabled
        self.actions = actions
        self.children = children
    }
}

/// Bridges macOS Accessibility (AXUIElement) APIs for Fast UI inspection and deterministic UI interaction.
/// Rule: Always try Accessibility API first before falling back to Vision models.
@MainActor
final class AccessibilityBridge {
    static let shared = AccessibilityBridge()

    private init() {}

    // MARK: - Testing Hooks

    var mockTrusted: Bool? = nil
    var mockElementTree: AXElementInfo? = nil
    var mockActionHandler: ((_ label: String, _ action: String) -> (success: Bool, message: String))? = nil
    var mockValueHandler: ((_ label: String?, _ value: String) -> (success: Bool, message: String))? = nil
    /// A read-back hook: nil is an unavailable observation, not an empty value.
    var mockValueReader: ((_ label: String?) -> String?)? = nil

    func resetMocks() {
        mockTrusted = nil
        mockElementTree = nil
        mockActionHandler = nil
        mockValueHandler = nil
        mockValueReader = nil
    }

    // MARK: - Permissions

    /// Check if accessibility trust is granted for the app.
    var isTrusted: Bool {
        if let mock = mockTrusted { return mock }
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
        if let mock = mockElementTree {
            return mock
        }
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

    // MARK: - Deterministic UI observation

    /// Resolves a fresh element at observation time. AX element handles are deliberately
    /// never retained across actions because applications may invalidate them.
    func findElement(matchingLabel label: String, inApp app: NSRunningApplication? = nil) -> AXElementInfo? {
        if let mock = mockElementTree { return findInMockTree(root: mock, matching: label) }
        guard isTrusted, let targetApp = app ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(targetApp.processIdentifier)
        guard let element = findAXUIElement(in: root, matching: label, depth: 0, maxDepth: 4) else { return nil }
        return parseElement(element, depth: 0, maxDepth: 0)
    }

    /// Reads an AX value from a freshly resolved target, returning unavailable rather
    /// than guessing when either the element or its value cannot be observed.
    func readElementValue(matchingLabel label: String?, inApp app: NSRunningApplication? = nil) -> (value: String?, isAvailable: Bool) {
        if let reader = mockValueReader { return (reader(label), true) }
        if let mock = mockElementTree {
            guard let element = findEditableInMockTree(root: mock, matching: label) else { return (nil, false) }
            return (element.value, true)
        }
        guard isTrusted, let targetApp = app ?? NSWorkspace.shared.frontmostApplication else { return (nil, false) }
        let root = AXUIElementCreateApplication(targetApp.processIdentifier)
        let element: AXUIElement?
        if let label, !label.isEmpty {
            element = findAXUIElement(in: root, matching: label, depth: 0, maxDepth: 4)
        } else {
            var focused: AnyObject?
            element = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success ? focused as! AXUIElement? : nil
        }
        guard let element else { return (nil, false) }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return (nil, false) }
        return (value as? String, true)
    }

    func elementExists(matchingLabel label: String, inApp app: NSRunningApplication? = nil) -> (exists: Bool, isAvailable: Bool) {
        guard isTrusted || mockElementTree != nil else { return (false, false) }
        return (findElement(matchingLabel: label, inApp: app) != nil, true)
    }

    func isElementFocused(matchingLabel label: String, inApp app: NSRunningApplication? = nil) -> (focused: Bool, isAvailable: Bool) {
        if mockElementTree != nil { return (false, false) } // mocks must explicitly model focus, never infer it.
        guard isTrusted, let targetApp = app ?? NSWorkspace.shared.frontmostApplication else { return (false, false) }
        var focused: AnyObject?
        let root = AXUIElementCreateApplication(targetApp.processIdentifier)
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return (false, false) }
        let element = focused as! AXUIElement
        var title: AnyObject?
        var description: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        _ = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
        let needle = label.lowercased()
        return ((title as? String)?.lowercased().contains(needle) == true || (description as? String)?.lowercased().contains(needle) == true, true)
    }

    // MARK: - Deterministic UI Actions

    /// Perform an action on an element matching a given label/text in the frontmost app.
    func performAction(matchingLabel: String, action: String = "AXPress") throws -> String {
        guard isTrusted else {
            throw JarvisError.actionFailed(action: "click_element", reason: "Accessibility permission not granted. Grant permission in macOS System Settings -> Privacy & Security -> Accessibility.")
        }

        if let handler = mockActionHandler {
            let res = handler(matchingLabel, action)
            if res.success {
                return res.message
            } else {
                throw JarvisError.actionFailed(action: "click_element", reason: res.message)
            }
        }

        if let mock = mockElementTree {
            guard let elem = findInMockTree(root: mock, matching: matchingLabel) else {
                throw JarvisError.actionFailed(action: "click_element", reason: "Element matching '\(matchingLabel)' not found in UI tree")
            }
            guard elem.isEnabled else {
                throw JarvisError.actionFailed(action: "click_element", reason: "Element '\(matchingLabel)' is disabled")
            }
            let label = elem.title ?? elem.elementDescription ?? matchingLabel
            return "Successfully clicked UI element '\(label)' (role: \(elem.role))"
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw JarvisError.actionFailed(action: "click_element", reason: "No frontmost application")
        }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        guard let targetElement = findAXUIElement(in: appElement, matching: matchingLabel, depth: 0, maxDepth: 4) else {
            throw JarvisError.actionFailed(action: "click_element", reason: "Element matching '\(matchingLabel)' not found in \(frontApp.localizedName ?? "frontmost app")")
        }

        let result = AXUIElementPerformAction(targetElement, action as CFString)
        guard result == .success else {
            throw JarvisError.actionFailed(action: "click_element", reason: "AX action '\(action)' failed with error code \(result.rawValue)")
        }

        return "Successfully performed '\(action)' on element '\(matchingLabel)' in \(frontApp.localizedName ?? "app")"
    }

    /// Set text into an editable UI field in the frontmost app.
    func setValue(matchingLabel: String?, value: String) throws -> String {
        guard isTrusted else {
            throw JarvisError.actionFailed(action: "set_text", reason: "Accessibility permission not granted. Grant permission in macOS System Settings -> Privacy & Security -> Accessibility.")
        }

        if let handler = mockValueHandler {
            let res = handler(matchingLabel, value)
            if res.success {
                return res.message
            } else {
                throw JarvisError.actionFailed(action: "set_text", reason: res.message)
            }
        }

        if let mock = mockElementTree {
            guard let elem = findEditableInMockTree(root: mock, matching: matchingLabel) else {
                let targetDesc = matchingLabel ?? "editable field"
                throw JarvisError.actionFailed(action: "set_text", reason: "Could not find \(targetDesc) in UI tree")
            }
            guard elem.isEnabled else {
                throw JarvisError.actionFailed(action: "set_text", reason: "Element '\(matchingLabel ?? elem.role)' is disabled")
            }
            let label = elem.title ?? elem.elementDescription ?? (matchingLabel ?? "text field")
            return "Successfully set text to '\(value)' on '\(label)' (role: \(elem.role))"
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw JarvisError.actionFailed(action: "set_text", reason: "No frontmost application")
        }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var targetElement: AXUIElement? = nil
        if let label = matchingLabel, !label.isEmpty {
            targetElement = findAXUIElement(in: appElement, matching: label, depth: 0, maxDepth: 4)
        } else {
            var focusedVal: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedVal) == .success,
               let focused = focusedVal {
                targetElement = (focused as! AXUIElement)
            }
        }

        guard let element = targetElement else {
            let targetDesc = matchingLabel ?? "focused element"
            throw JarvisError.actionFailed(action: "set_text", reason: "Could not find \(targetDesc) in \(frontApp.localizedName ?? "app")")
        }

        let axErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard axErr == .success else {
            throw JarvisError.actionFailed(action: "set_text", reason: "AX set value failed with error code \(axErr.rawValue)")
        }

        return "Successfully set text to '\(value)' in \(frontApp.localizedName ?? "app")"
    }

    // MARK: - Private Helpers

    private func findInMockTree(root: AXElementInfo, matching label: String) -> AXElementInfo? {
        let clean = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = root.title?.lowercased(), title == clean || title.contains(clean) {
            return root
        }
        if let desc = root.elementDescription?.lowercased(), desc == clean || desc.contains(clean) {
            return root
        }
        if let val = root.value?.lowercased(), val == clean || val.contains(clean) {
            return root
        }
        for child in root.children {
            if let found = findInMockTree(root: child, matching: label) {
                return found
            }
        }
        return nil
    }

    private func findEditableInMockTree(root: AXElementInfo, matching label: String?) -> AXElementInfo? {
        if let label = label, !label.isEmpty {
            return findInMockTree(root: root, matching: label)
        }
        if root.role == "AXTextField" || root.role == "AXTextArea" {
            return root
        }
        for child in root.children {
            if let found = findEditableInMockTree(root: child, matching: label) {
                return found
            }
        }
        return nil
    }

    private func findAXUIElement(in element: AXUIElement, matching label: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        let cleanLabel = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        var titleVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleVal) == .success,
           let title = titleVal as? String {
            let cleanTitle = title.lowercased()
            if cleanTitle == cleanLabel || cleanTitle.contains(cleanLabel) {
                return element
            }
        }

        var descVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descVal) == .success,
           let desc = descVal as? String {
            let cleanDesc = desc.lowercased()
            if cleanDesc == cleanLabel || cleanDesc.contains(cleanLabel) {
                return element
            }
        }

        var valVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valVal) == .success,
           let val = valVal as? String {
            let cleanVal = val.lowercased()
            if cleanVal == cleanLabel || cleanVal.contains(cleanLabel) {
                return element
            }
        }

        var childrenVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
           let children = childrenVal as? [AXUIElement] {
            for child in children.prefix(30) {
                if let found = findAXUIElement(in: child, matching: label, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }

        return nil
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

        // Enabled
        var enabledValue: AnyObject?
        let isEnabled: Bool
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue) == .success,
           let boolVal = enabledValue as? Bool {
            isEnabled = boolVal
        } else {
            isEnabled = true
        }

        // Frame
        var frame: CGRect? = nil
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let posVal = posValue, let sizeVal = sizeValue {
            var point = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
               AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: point, size: size)
            }
        }

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
            frame: frame,
            isEnabled: isEnabled,
            actions: actions,
            children: childInfos
        )
    }
}
