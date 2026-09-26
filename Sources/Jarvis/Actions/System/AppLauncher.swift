import AppKit

/// Manages macOS application launching, quitting, and state verification.
@MainActor
final class AppLauncher {
    static let shared = AppLauncher()

    private let appAliases: [String: String] = [
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "code": "Visual Studio Code",
        "terminal": "Terminal",
        "safari": "Safari",
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "finder": "Finder",
        "notes": "Notes",
        "calendar": "Calendar",
        "music": "Music",
        "messages": "Messages",
        "mail": "Mail",
        "system settings": "System Settings",
        "settings": "System Settings"
    ]

    private init() {}

    // MARK: - Public API

    /// Launch or activate an application by name with post-action verification.
    func open(_ appName: String) async throws -> String {
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw JarvisError.actionFailed(action: "openApp", reason: "Application name cannot be empty")
        }
        let targetName = appAliases[cleaned.lowercased()] ?? cleaned

        // 1. Check if application is already running: exact match on localizedName or bundleIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
        if let running = runningApps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(targetName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveCompare(targetName) == .orderedSame
        }) {
            running.activate(options: [.activateIgnoringOtherApps])
            let resolvedName = running.localizedName ?? targetName
            JarvisLogger.actions.info("Activated already running application: \(resolvedName)")

            let verified = await verifyFrontmost(resolvedName)
            if verified {
                return "Switched to \(resolvedName) (frontmost verified)."
            } else {
                return "Switched to \(resolvedName)."
            }
        }

        // 2. Locate app bundle URL via NSWorkspace
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetName) ??
              findAppURL(named: targetName) else {
            JarvisLogger.actions.warning("Could not find application: \(targetName)")
            throw JarvisError.actionFailed(action: "openApp", reason: "Application '\(targetName)' was not found")
        }

        // 3. Open application
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            let resolvedName = app.localizedName ?? targetName
            JarvisLogger.actions.info("Launched application: \(resolvedName)")

            let verified = await verifyFrontmost(resolvedName)
            if verified {
                return "Opened \(resolvedName) (frontmost verified)."
            } else {
                return "Opened \(resolvedName)."
            }
        } catch {
            JarvisLogger.actions.error("Failed to launch \(targetName): \(error.localizedDescription)")
            throw JarvisError.actionFailed(action: "openApp", reason: error.localizedDescription)
        }
    }

    /// Switch to / activate an application.
    func switchTo(_ appName: String) async throws -> String {
        return try await open(appName)
    }

    /// Terminate a running application by name with post-action verification.
    func quit(_ appName: String) async throws -> String {
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw JarvisError.actionFailed(action: "quitApp", reason: "Application name cannot be empty")
        }
        let targetName = appAliases[cleaned.lowercased()] ?? cleaned

        let runningApps = NSWorkspace.shared.runningApplications
        guard let running = runningApps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(targetName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveCompare(targetName) == .orderedSame
        }) else {
            return "\(targetName) is not currently running"
        }

        let name = running.localizedName ?? targetName
        running.terminate()

        let terminated = await verifyTerminated(name)
        if terminated {
            JarvisLogger.actions.info("Terminated application: \(name) (verified)")
            return "Closed \(name) (termination verified)."
        } else {
            JarvisLogger.actions.info("Terminated application: \(name)")
            return "Closed \(name)."
        }
    }

    /// Check if an application is currently running.
    func isRunning(_ appName: String) -> Bool {
        let targetName = appAliases[appName.lowercased()] ?? appName
        return NSWorkspace.shared.runningApplications.contains(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(targetName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveCompare(targetName) == .orderedSame
        })
    }

    /// Verify whether an app name or alias maps to an existing, concrete application without multi-action/clause contamination.
    func canResolve(_ appName: String) -> Bool {
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if cleaned.contains(" and ") || cleaned.contains(" then ") || cleaned.contains(" & ") || cleaned.contains(";") || cleaned.contains(" also ") {
            return false
        }
        let targetName = appAliases[cleaned.lowercased()] ?? cleaned

        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(targetName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveCompare(targetName) == .orderedSame
        }) {
            return true
        }

        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetName) != nil {
            return true
        }

        return findAppURL(named: targetName) != nil
    }

    // MARK: - Verification Helpers

    private func verifyFrontmost(_ name: String, maxWaitMs: Int = 400) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + (Double(maxWaitMs) / 1000.0)
        while CFAbsoluteTimeGetCurrent() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication,
               let frontName = front.localizedName,
               frontName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(frontName) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func verifyTerminated(_ name: String, maxWaitMs: Int = 400) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + (Double(maxWaitMs) / 1000.0)
        while CFAbsoluteTimeGetCurrent() < deadline {
            if !isRunning(name) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isRunning(name)
    }

    // MARK: - Private Helper

    private func findAppURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            ("~" as NSString).expandingTildeInPath + "/Applications"
        ]

        for path in searchPaths {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let appBaseName = (item as NSString).deletingPathExtension
                if appBaseName.localizedCaseInsensitiveCompare(name) == .orderedSame {
                    return URL(fileURLWithPath: (path as NSString).appendingPathComponent(item))
                }
            }
        }

        return nil
    }
}
