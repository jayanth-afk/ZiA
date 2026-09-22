import AppKit

/// Manages macOS application launching, quitting, and state verification.
@MainActor
final class AppLauncher {
    static let shared = AppLauncher()

    private init() {}

    // MARK: - Public API

    /// Launch or activate an application by name.
    func open(_ appName: String) async throws -> String {
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw JarvisError.actionFailed(action: "openApp", reason: "Application name cannot be empty")
        }

        // 1. Check if application is already running
        let runningApps = NSWorkspace.shared.runningApplications
        if let running = runningApps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(cleaned) == true
        }) {
            running.activate()
            JarvisLogger.actions.info("Activated already running application: \(running.localizedName ?? cleaned)")
            return "Switched to \(running.localizedName ?? cleaned)"
        }

        // 2. Locate app bundle URL via NSWorkspace
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleaned) ??
              findAppURL(named: cleaned) else {
            JarvisLogger.actions.warning("Could not find application: \(cleaned)")
            throw JarvisError.actionFailed(action: "openApp", reason: "Application '\(cleaned)' was not found")
        }

        // 3. Open application
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            JarvisLogger.actions.info("Launched application: \(app.localizedName ?? cleaned)")
            return "Opening \(app.localizedName ?? cleaned)"
        } catch {
            JarvisLogger.actions.error("Failed to launch \(cleaned): \(error.localizedDescription)")
            throw JarvisError.actionFailed(action: "openApp", reason: error.localizedDescription)
        }
    }

    /// Terminate a running application by name.
    func quit(_ appName: String) async throws -> String {
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw JarvisError.actionFailed(action: "quitApp", reason: "Application name cannot be empty")
        }

        let runningApps = NSWorkspace.shared.runningApplications
        guard let running = runningApps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(cleaned) == true
        }) else {
            return "\(cleaned) is not currently running"
        }

        let name = running.localizedName ?? cleaned
        running.terminate()
        JarvisLogger.actions.info("Terminated application: \(name)")
        return "Closed \(name)"
    }

    /// Check if an application is currently running.
    func isRunning(_ appName: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
        })
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
                if appBaseName.localizedCaseInsensitiveContains(name) ||
                   name.localizedCaseInsensitiveContains(appBaseName) {
                    return URL(fileURLWithPath: (path as NSString).appendingPathComponent(item))
                }
            }
        }

        return nil
    }
}
