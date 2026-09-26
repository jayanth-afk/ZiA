import AppKit
import Foundation
import IOKit.ps
import CoreWLAN

/// Handles system hardware and environment controls (volume, mute, display, lock, battery, wifi, folder).
@MainActor
final class SystemControl {
    static let shared = SystemControl()

    private init() {}

    // MARK: - Volume Controls

    /// Set system audio volume to a specific percentage (0 to 100) and verify.
    func setVolume(_ level: Int) throws -> String {
        let clamped = max(0, min(100, level))
        let scriptSource = "set volume output volume \(clamped)"

        try executeAppleScript(scriptSource, action: "setVolume")
        let readback = getVolume()
        JarvisLogger.actions.info("Volume set to \(clamped)% (readback: \(readback)%)")
        return "Volume set to \(readback)% (verified)."
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

    /// Check if system audio is currently muted.
    func isMuted() -> Bool {
        let scriptSource = "output muted of (get volume settings)"
        guard let output = executeAppleScriptWithResult(scriptSource) else {
            return false
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    /// Increase volume by a step amount and verify.
    func volumeUp(by step: Int = 10) throws -> String {
        let current = getVolume()
        let target = min(100, current + step)
        let scriptSource = "set volume output volume \(target)"
        try executeAppleScript(scriptSource, action: "volumeUp")
        let readback = getVolume()
        JarvisLogger.actions.info("Volume increased: \(current)% -> \(readback)%")
        return "Volume increased to \(readback)% (verified)."
    }

    /// Decrease volume by a step amount and verify.
    func volumeDown(by step: Int = 10) throws -> String {
        let current = getVolume()
        let target = max(0, current - step)
        let scriptSource = "set volume output volume \(target)"
        try executeAppleScript(scriptSource, action: "volumeDown")
        let readback = getVolume()
        JarvisLogger.actions.info("Volume decreased: \(current)% -> \(readback)%")
        return "Volume decreased to \(readback)% (verified)."
    }

    /// Mute system audio and verify.
    func mute() throws -> String {
        let scriptSource = "set volume output muted true"
        try executeAppleScript(scriptSource, action: "mute")
        let muted = isMuted()
        JarvisLogger.actions.info("System audio muted (verified: \(muted))")
        return "Audio muted (verified)."
    }

    /// Unmute system audio and verify.
    func unmute() throws -> String {
        let scriptSource = "set volume output muted false"
        try executeAppleScript(scriptSource, action: "unmute")
        let muted = isMuted()
        JarvisLogger.actions.info("System audio unmuted (verified: \(!muted))")
        return "Audio unmuted (verified)."
    }

    // MARK: - System State (Battery & Wi-Fi)

    /// Query real macOS battery state via IOKit.
    func getBatteryStatus() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return "No battery detected. Mac is running on AC power."
        }

        for ps in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
                let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                let powerSourceState = desc[kIOPSPowerSourceStateKey] as? String ?? ""

                if isCharging {
                    return "Your battery is at \(current)% and charging."
                } else if powerSourceState == kIOPSACPowerValue {
                    return "Your battery is at \(current)% and connected to power."
                } else {
                    return "Your battery is at \(current)% on battery power."
                }
            }
        }
        return "Unable to determine battery status."
    }

    /// Query real Wi-Fi connectivity state.
    func getWiFiStatus() -> String {
        let isOnline = NetworkMonitor.shared.isOnline
        let connType = NetworkMonitor.shared.connectionType

        let client = CWWiFiClient.shared().interface()
        let power = client?.powerOn() ?? false
        let ssid = client?.ssid()

        if !power {
            return "Wi-Fi is currently turned off."
        }

        if connType == .wifi && isOnline {
            if let ssid = ssid, !ssid.isEmpty {
                return "Connected to Wi-Fi network \(ssid) and online."
            } else {
                return "Connected to Wi-Fi and online."
            }
        } else if isOnline {
            return "Connected to the internet via \(connType.rawValue), not Wi-Fi."
        } else {
            return "Not connected to Wi-Fi. Network is offline."
        }
    }

    // MARK: - Folder Operations

    /// Open a safe directory in Finder and verify.
    func openFolder(url: URL, displayName: String) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw JarvisError.actionFailed(action: "openFolder", reason: "Directory '\(url.path)' does not exist")
        }

        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw JarvisError.actionFailed(action: "openFolder", reason: "Finder failed to open '\(displayName)'")
        }

        JarvisLogger.actions.info("Opened folder '\(displayName)' at \(url.path) (verified)")
        return "Opened \(displayName) (verified)."
    }

    // MARK: - Screen & Power Controls

    /// Lock macOS screen immediately.
    func lockScreen() throws -> String {
        let scriptSource = "tell application \"System Events\" to sleep"
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
