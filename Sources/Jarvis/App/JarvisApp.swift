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
    }

    var body: some Scene {
        Settings {
            Text("JARVIS Settings — Coming in Phase 12")
                .frame(width: 400, height: 300)
                .padding()
        }
    }
}
