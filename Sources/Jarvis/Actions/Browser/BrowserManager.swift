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

    public init() {}

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
            let output = try await AppleScriptBridge.shared.execute(script)
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

        return try await AppleScriptBridge.shared.execute(appleScript)
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

        let result = try await AppleScriptBridge.shared.execute(script)
        return result.contains("true")
    }
}
