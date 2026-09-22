import AppKit

/// Handles system hardware and environment controls (volume, mute, display, lock).
@MainActor
final class SystemControl {
    static let shared = SystemControl()

    private init() {}

    // MARK: - Volume Controls

    /// Set system audio volume to a specific percentage (0 to 100).
    func setVolume(_ level: Int) throws -> String {
        let clamped = max(0, min(100, level))
        let scriptSource = "set volume output volume \(clamped)"

        try executeAppleScript(scriptSource, action: "setVolume")
        JarvisLogger.actions.info("Volume set to \(clamped)%")
        return "Volume set to \(clamped)%"
    }

    /// Read current system volume percentage (0 to 100).
    func getVolume() -> Int {
        let scriptSource = "output volume of (get volume settings)"
        guard let output = executeAppleScriptWithResult(scriptSource),
              let volume = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 50 // default fallback
        }
        return volume
    }

    /// Increase volume by a step amount.
    func volumeUp(by step: Int = 10) throws -> String {
        let current = getVolume()
        return try setVolume(current + step)
    }

    /// Decrease volume by a step amount.
    func volumeDown(by step: Int = 10) throws -> String {
        let current = getVolume()
        return try setVolume(current - step)
    }

    /// Mute system audio.
    func mute() throws -> String {
        let scriptSource = "set volume output muted true"
        try executeAppleScript(scriptSource, action: "mute")
        JarvisLogger.actions.info("System audio muted")
        return "Audio muted"
    }

    /// Unmute system audio.
    func unmute() throws -> String {
        let scriptSource = "set volume output muted false"
        try executeAppleScript(scriptSource, action: "unmute")
        JarvisLogger.actions.info("System audio unmuted")
        return "Audio unmuted"
    }

    // MARK: - Screen & Power Controls

    /// Lock macOS screen immediately.
    func lockScreen() throws -> String {
        let scriptSource = "tell application \"System Events\" to sleep"
        // Also support SACLockScreenImmediate or CGSession if available, or AppleScript
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
            JarvisLogger.actions.info("Locked display screen")
            return "Screen locked"
        } catch {
            try executeAppleScript(scriptSource, action: "lockScreen")
            return "Display put to sleep"
        }
    }

    /// Empty the macOS Trash.
    func emptyTrash() throws -> String {
        let scriptSource = "tell application \"Finder\" to empty trash"
        try executeAppleScript(scriptSource, action: "emptyTrash")
        JarvisLogger.actions.info("Emptied trash")
        return "Trash emptied"
    }

    // MARK: - Private Helpers

    private func executeAppleScript(_ source: String, action: String) throws {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw JarvisError.actionFailed(action: action, reason: "Failed to compile AppleScript")
        }

        script.executeAndReturnError(&errorDict)
        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            JarvisLogger.actions.error("AppleScript failed for \(action): \(message)")
            throw JarvisError.actionFailed(action: action, reason: message)
        }
    }

    private func executeAppleScriptWithResult(_ source: String) -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return nil }
        return result.stringValue
    }
}
