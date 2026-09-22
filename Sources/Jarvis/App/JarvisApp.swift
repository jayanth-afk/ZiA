import SwiftUI

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Handle --self-test flag before app launches
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.runAll()
            exit(0)
        }

        // Handle --audit flag for real hardware integration verification
        if CommandLine.arguments.contains("--audit") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await IntegrationAudit.runAll()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
