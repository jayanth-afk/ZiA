import Foundation
import AppKit

public enum BrowserType: String, Sendable, CaseIterable {
    case defaultBrowser = "Default"
    case safari = "Safari"
    case chrome = "Google Chrome"
    case arc = "Arc"
    case brave = "Brave Browser"
}

public struct BrowserTabInfo: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let browser: BrowserType

    public init(id: String = UUID().uuidString, title: String, url: String, browser: BrowserType) {
        self.id = id
        self.title = title
        self.url = url
        self.browser = browser
    }
}

/// Browser automation and interaction subsystem.
/// Uses AppleScript and NSWorkspace to inspect and control macOS browsers.
public actor BrowserManager {
    public static let shared = BrowserManager()

    /// Whether an automation sequence (open -> inspect -> act) is currently mid-flight.
    /// Set true around multi-step browser automation; checked by emergency stop.
    public private(set) var isAutomating = false

    /// Actions queued behind the current automation sequence, cancelled by emergency stop.
    private var pendingActions: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Cancel all pending/queued browser automation work immediately
    /// (invoked via EmergencyStopEvent propagation).
    public func cancelAutomation() {
        isAutomating = false
        let pending = pendingActions
        pendingActions.removeAll()
        JarvisLogger.actions.warning("Browser automation cancelled: \(pending.count) pending action(s) dropped")
        // Queued waiters resume; sequence owners observe isAutomating == false and bail.
        for continuation in pending {
            continuation.resume()
        }
    }

    // MARK: - Public API

    /// Opens a URL in the designated browser or default system browser.
    public func open(url: URL, in browser: BrowserType = .defaultBrowser) async throws -> Bool {
        if browser == .defaultBrowser {
            return await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }

        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                activate
                open location "\(url.absoluteString)"
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                activate
                open location "\(url.absoluteString)"
            end tell
            """
        default:
            script = """
            tell application "\(browser.rawValue)"
                activate
                open location "\(url.absoluteString)"
            end tell
            """
        }

        _ = try await AppleScriptBridge.shared.execute(script)
        return true
    }

    /// Retrieves information about the frontmost active tab in the specified browser.
    public func getActiveTabInfo(browser: BrowserType = .safari) async throws -> BrowserTabInfo? {
        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    set currentTab to current tab of front window
                    return (URL of currentTab) & "|||" & (name of currentTab)
                else
                    return ""
                end if
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    set currentTab to active tab of front window
                    return (URL of currentTab) & "|||" & (title of currentTab)
                else
                    return ""
                end if
            end tell
            """
        default:
            return nil
        }

        do {
            let output = try await AppleScriptBridge.shared.execute(script, timeoutSeconds: 4.0)
            guard !output.isEmpty else { return nil }

            let parts = output.components(separatedBy: "|||")
            let tabURL = parts.first ?? ""
            let tabTitle = parts.count > 1 ? parts[1] : tabURL

            return BrowserTabInfo(
                title: tabTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                url: tabURL.trimmingCharacters(in: .whitespacesAndNewlines),
                browser: browser
            )
        } catch {
            JarvisLogger.actions.debug("Could not read active tab for \(browser.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    /// Executes JavaScript in the active tab of the designated browser.
    public func executeJavaScript(script: String, browser: BrowserType = .safari) async throws -> String {
        // Escape quotes and backslashes for AppleScript
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript: String
        switch browser {
        case .safari:
            appleScript = """
            tell application "Safari"
                if (count of windows) > 0 then
                    return do JavaScript "\(escaped)" in current tab of front window
                else
                    return ""
                end if
            end tell
            """
        case .chrome:
            appleScript = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    return execute active tab of front window javascript "\(escaped)"
                else
                    return ""
                end if
            end tell
            """
        default:
            throw JarvisError.actionFailed(action: "executeJavaScript", reason: "Browser \(browser.rawValue) not supported for JS execution")
        }

        return try await AppleScriptBridge.shared.execute(appleScript, timeoutSeconds: 4.0)
    }

    /// Observe a bounded, read-only summary of the active page DOM.
    public func inspectActivePage(browser: BrowserType) async throws -> String {
        guard browser == .safari || browser == .chrome else {
            throw JarvisError.actionFailed(action: "inspectBrowser", reason: "DOM observation is supported only for Safari and Chrome")
        }
        let script = """
        (() => JSON.stringify({
          title: document.title || "",
          url: location.href,
          text: (document.body?.innerText || "").slice(0, 12000),
          links: Array.from(document.querySelectorAll("a[href]")).slice(0, 80).map(a => ({text: (a.innerText || a.getAttribute("aria-label") || "").trim().slice(0, 200), href: a.href.slice(0, 2048)}))
        }))()
        """
        return try await executeJavaScript(script: script, browser: browser)
    }

    /// Return text from exactly one CSS-selected element. The selector is JSON-escaped
    /// before entering JavaScript and the returned text is bounded to 8 KB.
    public func extractText(selector: String, browser: BrowserType) async throws -> String {
        guard browser == .safari || browser == .chrome else {
            throw JarvisError.actionFailed(action: "extractBrowserText", reason: "DOM extraction is supported only for Safari and Chrome")
        }
        guard !selector.isEmpty, selector.count <= 512,
              let selectorData = try? JSONSerialization.data(withJSONObject: [selector]),
              let selectorJSON = String(data: selectorData, encoding: .utf8) else {
            throw JarvisError.actionFailed(action: "extractBrowserText", reason: "Invalid or oversized CSS selector")
        }
        let quotedSelector = String(selectorJSON.dropFirst().dropLast())
        let script = """
        (() => {
          const matches = document.querySelectorAll(\(quotedSelector));
          if (matches.length !== 1) return JSON.stringify({error: "selector must match exactly one element", count: matches.length});
          const e = matches[0];
          return JSON.stringify({text: (e.innerText || e.textContent || "").trim().slice(0, 8000)});
        })()
        """
        return try await executeJavaScript(script: script, browser: browser)
    }

    /// Fill one uniquely selected non-sensitive text input or textarea. This does
    /// not submit forms and rejects password/email/other specialized controls.
    public func fillText(selector: String, text: String, browser: BrowserType) async throws {
        guard browser == .safari || browser == .chrome,
              !selector.isEmpty, selector.count <= 512, text.utf8.count <= 8192,
              let selectorData = try? JSONSerialization.data(withJSONObject: [selector]),
              let selectorJSON = String(data: selectorData, encoding: .utf8),
              let textData = try? JSONSerialization.data(withJSONObject: [text]),
              let textJSON = String(data: textData, encoding: .utf8) else {
            throw JarvisError.actionFailed(action: "fillBrowserText", reason: "Unsupported browser or invalid selector/text size")
        }
        let encodedSelector = String(selectorJSON.dropFirst().dropLast())
        let encodedText = String(textJSON.dropFirst().dropLast())
        let script = """
        (() => {
          const matches = document.querySelectorAll(\(encodedSelector));
          if (matches.length !== 1) return JSON.stringify({updated: false, error: "selector must match exactly one element", count: matches.length});
          const e = matches[0];
          if (e instanceof HTMLTextAreaElement) {
            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set.call(e, \(encodedText));
          } else if (e instanceof HTMLInputElement && ["text", "search", "url", "tel"].includes((e.type || "text").toLowerCase())) {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(e, \(encodedText));
          } else {
            return JSON.stringify({updated: false, error: "target is not an allowed text field"});
          }
          e.dispatchEvent(new InputEvent("input", {bubbles: true, inputType: "insertText", data: \(encodedText)}));
          e.dispatchEvent(new Event("change", {bubbles: true}));
          return JSON.stringify({updated: true});
        })()
        """
        let response = try await executeJavaScript(script: script, browser: browser)
        guard let data = response.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["updated"] as? Bool == true else {
            let reason = (try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])?["error"] as? String ?? "Text field was not updated"
            throw JarvisError.actionFailed(action: "fillBrowserText", reason: reason)
        }
    }

    /// Read the current value of one supported text field after mutation.
    public func readTextValue(selector: String, browser: BrowserType) async throws -> String {
        guard browser == .safari || browser == .chrome,
              !selector.isEmpty, selector.count <= 512,
              let data = try? JSONSerialization.data(withJSONObject: [selector]),
              let json = String(data: data, encoding: .utf8) else {
            throw JarvisError.actionFailed(action: "observeBrowserText", reason: "Unsupported browser or invalid selector")
        }
        let encodedSelector = String(json.dropFirst().dropLast())
        let script = """
        (() => {
          const matches = document.querySelectorAll(\(encodedSelector));
          if (matches.length !== 1) return JSON.stringify({available: false, error: "selector must match exactly one element", count: matches.length});
          const e = matches[0];
          if (!(e instanceof HTMLTextAreaElement) && !(e instanceof HTMLInputElement && ["text", "search", "url", "tel"].includes((e.type || "text").toLowerCase()))) return JSON.stringify({available: false, error: "target is not an allowed text field"});
          return JSON.stringify({available: true, value: e.value});
        })()
        """
        return try await executeJavaScript(script: script, browser: browser)
    }

    /// Click a uniquely identified link only; arbitrary buttons and form controls
    /// are intentionally outside this bounded navigation primitive.
    public func clickLink(selector: String, browser: BrowserType, expectedDestinationContains: String) async throws -> String {
        guard browser == .safari || browser == .chrome else {
            throw JarvisError.actionFailed(action: "clickBrowserLink", reason: "DOM interaction is supported only for Safari and Chrome")
        }
        guard !selector.isEmpty, selector.count <= 512,
              !expectedDestinationContains.isEmpty, expectedDestinationContains.count <= 2048,
              let data = try? JSONSerialization.data(withJSONObject: [selector]),
              let encoded = String(data: data, encoding: .utf8),
              let expectedData = try? JSONSerialization.data(withJSONObject: [expectedDestinationContains]),
              let expectedEncoded = String(data: expectedData, encoding: .utf8) else {
            throw JarvisError.actionFailed(action: "clickBrowserLink", reason: "Invalid or oversized CSS selector or URL expectation")
        }
        let quotedSelector = String(encoded.dropFirst().dropLast())
        let quotedExpectation = String(expectedEncoded.dropFirst().dropLast())
        let script = """
        (() => {
          const matches = document.querySelectorAll(\(quotedSelector));
          if (matches.length !== 1) return JSON.stringify({clicked: false, error: "selector must match exactly one element", count: matches.length});
          const e = matches[0];
          if (!(e instanceof HTMLAnchorElement) || !e.href) return JSON.stringify({clicked: false, error: "target is not a navigable link"});
          const destination = e.href;
          if (!destination.includes(\(quotedExpectation))) return JSON.stringify({clicked: false, error: "link destination does not match expectation", destination});
          e.click();
          return JSON.stringify({clicked: true, destination});
        })()
        """
        let result = try await executeJavaScript(script: script, browser: browser)
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["clicked"] as? Bool == true,
              let destination = object["destination"] as? String else {
            let reason = (try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["error"] as? String ?? "Link click was not accepted"
            throw JarvisError.actionFailed(action: "clickBrowserLink", reason: reason)
        }
        return destination
    }

    /// Wait briefly for an already-requested navigation, observing real tab state.
    public func waitForNavigation(browser: BrowserType, from initialURL: String, to destination: String, timeout: TimeInterval = 4) async throws -> BrowserTabInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let tab = try await getActiveTabInfo(browser: browser), tab.url != initialURL,
               Self.urlsEquivalent(tab.url, destination) {
                return tab
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return try await getActiveTabInfo(browser: browser)
    }

    private nonisolated static func urlsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            guard value.hasSuffix("/") else { return value }
            return String(value.dropLast())
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// Closes the active tab in the designated browser.
    public func closeActiveTab(browser: BrowserType = .safari) async throws -> Bool {
        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    close current tab of front window
                    return "true"
                end if
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    close active tab of front window
                    return "true"
                end if
            end tell
            """
        default:
            return false
        }

        let result = try await AppleScriptBridge.shared.execute(script, timeoutSeconds: 4.0)
        return result.contains("true")
    }
}
